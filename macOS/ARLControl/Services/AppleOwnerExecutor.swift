import Foundation

/// UI and the authenticated Mio owner compose the SAME native task consumer.
/// This class has no EventKit access, target selection or authority constructor.
@MainActor final class AppleOwnerExecutor {
    struct Port {
        let begin: @MainActor (UUID) -> Bool
        let end: @MainActor (UUID) -> Void
        let ensureService: @MainActor () async throws -> Void
        let send: @MainActor (RemindersFirstFrame) async throws -> RemindersFirstReply
        let observe: @MainActor (RemindersFirstReply) -> Void
        let record: @MainActor (String, UUID, Data, Data?) async throws -> Void
    }
    private let port: Port
    init(port: Port) { self.port = port }
    func execute(tool: String, argumentsJSON: Data, callID: UUID) async throws -> Data {
        let request = try AppleCapability.request(tool:tool, argumentsJSON:argumentsJSON)
        if let title = request.title { try RemindersTaskContract.title(title) }
        return try await boundary(tool:tool,argumentsJSON:argumentsJSON,taskID:request.taskID,callID:callID) {
            await self.perform(request)
        }
    }
    /// Explicit local UI continuation only. It is never a published Mio action:
    /// scope binds the default target without saving; submit uses only the exact displayed digest.
    func executeLocal(_ frame: RemindersFirstFrame, callID: UUID) async throws -> Data {
        guard [.task_prepare,.task_scope,.task_submit,.task_cancel].contains(frame.action),
              let taskID=frame.task_id else { throw RemindersTransportFault("invalid_arguments") }
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys,.withoutEscapingSlashes]
        let bytes=try encoder.encode(frame)
        _=try RemindersFirstFrame.decode(bytes)
        let request=AppleCapability.Request(action:.createReminder,taskID:taskID,title:frame.title)
        return try await boundary(tool:"arl_ui_reminders_"+frame.action.rawValue,argumentsJSON:bytes,taskID:taskID,callID:callID) {
            await self.performLocal(frame,request:request)
        }
    }
    private func boundary(tool:String,argumentsJSON:Data,taskID:String,callID:UUID,
                          operation: @MainActor () async -> AppleOwnerResult) async throws -> Data {
        try await port.record(tool,callID,argumentsJSON,nil)
        guard port.begin(callID) else {
            let result=AppleOwnerResult(taskID:taskID,state:"owner_busy",code:"owner_busy",task:nil)
            let bytes=try result.encoded();try await port.record(tool,callID,argumentsJSON,bytes);return bytes
        }
        defer { port.end(callID) }
        let bytes=try await operation().encoded()
        try await port.record(tool,callID,argumentsJSON,bytes)
        return bytes
    }
    private func performLocal(_ frame:RemindersFirstFrame,request:AppleCapability.Request) async -> AppleOwnerResult {
        var submitStarted=false
        do {
            try Task.checkCancellation()
            if frame.action == .task_scope || frame.action == .task_submit { try await port.ensureService() }
            if frame.action != .task_prepare {
                let current=try await call(.task_status,request)
                guard let task=current.task else { return .reply(current,request:request) }
                if task.state.terminal { return .observed(task,code:current.code) }
                guard task.digest==frame.expected_digest else { throw RemindersTransportFault("task_changed") }
            }
            try Task.checkCancellation()
            submitStarted=frame.action == .task_submit
            let reply=try await call(frame,request)
            if !submitStarted { try Task.checkCancellation() }
            return .reply(reply,request:request)
        } catch {
            let code=error is CancellationError ? "cancelled" : (error as? RemindersTransportFault)?.code ?? "owner_unavailable"
            return .init(taskID:request.taskID,state:submitStarted ? "outcome_unknown":"not_dispatched",code:AppleOwnerResult.finite(code),task:nil)
        }
    }
    private func perform(_ request: AppleCapability.Request) async -> AppleOwnerResult {
        var submitStarted=false
        do {
            try Task.checkCancellation()
            if request.action == .createReminder { try await port.ensureService() }
            try Task.checkCancellation()
            let current = try await call(.task_status,request)
            if let task = current.task { return .observed(task,code:current.code) }
            guard current.code == "task_not_found" else { return .reply(current,request:request) }
            guard request.action == .createReminder else {
                return .init(taskID:request.taskID,state:"operation_missing",code:"task_not_found",task:nil)
            }
            let prepared = try await call(.task_prepare,request)
            guard let draft = prepared.task else { return .reply(prepared,request:request) }
            guard draft.state == .draft else { return .observed(draft,code:prepared.code) }
            let selected = try await call(.task_scope,request,expected:draft.digest)
            guard selected.code == "task_scope_selected", let scoped = selected.task else { return .reply(selected,request:request) }
            guard scoped.state == .scoped, scoped.scope != nil else { throw RemindersTransportFault("task_changed") }
            try Task.checkCancellation() // A late scope response cannot start a cancelled save.
            submitStarted=true
            return .reply(try await call(.task_submit,request,expected:scoped.digest),request:request)
        } catch {
            let code=error is CancellationError ? "cancelled" : (error as? RemindersTransportFault)?.code ?? "owner_unavailable"
            // A preflight or read failure never claims a save may have occurred.
            // Once submit begins, only the original durable task can resolve it.
            return .init(taskID:request.taskID,state:submitStarted ? "outcome_unknown" : request.action == .reminderStatus ? "status_unavailable" : "not_dispatched",code:AppleOwnerResult.finite(code),task:nil)
        }
    }
    private func call(_ action: RemindersFirstAction, _ request: AppleCapability.Request, expected: String? = nil) async throws -> RemindersFirstReply {
        try Task.checkCancellation()
        let frame = RemindersFirstFrame(task:action,requestID:UUID(),taskID:request.taskID,
            title:action == .task_prepare ? request.title : nil,expected:expected)
        return try await call(frame,request)
    }
    private func call(_ frame:RemindersFirstFrame,_ request:AppleCapability.Request) async throws -> RemindersFirstReply {
        try Task.checkCancellation()
        _ = try RemindersFirstFrame.decode(JSONEncoder().encode(frame))
        let reply = try await port.send(frame)
        guard reply.request_id == frame.request_id, reply.action == frame.action else { throw RemindersTransportFault("invalid_response") }
        if let task = reply.task {
            guard task.task_id == request.taskID, task.operation_id == RemindersTaskContract.operationID(request.taskID),
                  request.title == nil || task.title == request.title else { throw RemindersTransportFault("task_changed") }
        }
        port.observe(reply)
        return reply
    }
}
struct AppleOwnerResult: Codable, Sendable {
    let schema: Int
    let task_id: String
    let state: String
    let code: String
    let task: RemindersTaskRecord?
    let automatic_replay: Bool
    let new_submission_allowed: Bool
    let cloud_sync: String
    init(taskID: String, state: String, code: String, task: RemindersTaskRecord?) {
        schema=1;task_id=taskID;self.state=state;self.code=code;self.task=task
        automatic_replay=false;new_submission_allowed=false;cloud_sync="not_checked"
    }
    func encoded() throws -> Data {
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys,.withoutEscapingSlashes];return try encoder.encode(self)
    }
    static func finite(_ code: String) -> String {
        code.range(of:"^[a-z][a-z0-9_]{0,79}$",options:.regularExpression) == nil ? "owner_unavailable" : code
    }
    static func observed(_ task: RemindersTaskRecord, code: String) -> Self {
        let state: String = switch task.state {
        case .saved: "saved_local"
        case .attempting,.unknown: "outcome_unknown"
        case .draft,.scoped: "awaiting_local_action"
        case .cancelled: "cancelled"
        }
        return .init(taskID:task.task_id,state:state,code:finite(code),task:task)
    }
    static func reply(_ reply: RemindersFirstReply, request: AppleCapability.Request) -> Self {
        if reply.outcome == "user_cancelled" { return .init(taskID:request.taskID,state:"cancelled",code:finite(reply.code),task:reply.task) }
        if let task=reply.task { return .observed(task,code:reply.code) }
        return .init(taskID:request.taskID,state:"unavailable",code:finite(reply.code),task:nil)
    }
}
