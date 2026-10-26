import Foundation
import Observation
import CryptoKit
import ARLCredentialOnboarding

struct CodexLocalTask: Codable {
    let schema: Int
    let operationID: UUID
    let model: String
    var selection: CodexExecutionSelection? = nil
    let scopeGeneration: String
    let input: String
    let intentDigest: String
    let createdAt: Date
    var jobID: UUID?
    var replyData: Data?
    var phase: String
    var outputLogged: Bool
    static func digest(input: String, scope: String, selection: CodexExecutionSelection? = nil) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let settings = selection.flatMap { try? encoder.encode($0) }.map { String(decoding: $0, as: UTF8.self) } ?? CodexScopeOwner.model
        return SHA256.hash(data: Data((settings + "\u{0}" + scope + "\u{0}" + input).utf8)).map { String(format: "%02x", $0) }.joined()
    }
    var reply: CodexTaskReply? {
        guard let replyData, let value = try? JSONDecoder().decode(ARLJSON.self, from: replyData) else { return nil }
        return try? CodexTaskReply.decode(value, model: model)
    }
    var permitsNewIntent: Bool { outputLogged && ["succeeded", "failed", "cancelled"].contains(phase) }
}

private struct CodexDeferredReceipt: Codable {
    let operationID: UUID
    let action: String
    let arguments: Data
    let response: Data
    var name: String {
        let bytes = Data(operationID.uuidString.utf8) + Data(action.utf8) + arguments + response
        return "pending-receipt-" + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() + ".json"
    }
}

@MainActor private final class CodexLocalTaskStore {
    let directory: URL
    var path: String { directory.appendingPathComponent("current-task-v1.json").path }
    init(_ directory: URL) { self.directory = directory }
    func load() throws -> CodexLocalTask? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let data = try RemindersNativeIO.privateFile(path, limit: 131072)
        let raw = try OwnerReadJSON.object(data, limit: 131072, maximumDepth: 32)
        let keys: Set<String> = ["schema", "operationID", "model", "scopeGeneration", "input", "intentDigest", "createdAt", "phase", "outputLogged"]
        guard Set(raw.keys).isSuperset(of: keys), Set(raw.keys).isSubset(of: keys.union(["jobID", "replyData", "selection"])) else { throw ARLError(code: "codex_task_record_invalid") }
        let record = try JSONDecoder().decode(CodexLocalTask.self, from: data)
        guard record.schema == 1, record.selection == nil ? record.model == CodexScopeOwner.model : record.selection?.model == record.model && record.selection?.isWellFormed == true, UUID(uuidString: record.scopeGeneration) != nil,
              !record.input.isEmpty, record.input.utf8.count <= 8192,
              record.intentDigest == CodexLocalTask.digest(input: record.input, scope: record.scopeGeneration, selection: record.selection),
              ["prepared", "queued", "running", "succeeded", "failed", "cancelled", "needs_review"].contains(record.phase),
              record.replyData == nil
                ? record.jobID == nil && record.phase == "prepared" && !record.outputLogged
                : record.reply?.state == record.phase && record.reply.flatMap({ UUID(uuidString: $0.id) }) == record.jobID else { throw ARLError(code: "codex_task_record_invalid") }
        return record
    }
    func deferredPaths() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        try RemindersNativeIO.privateDirectory(directory.path)
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("pending-receipt-") && $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    func deferReceipt(_ receipt: CodexDeferredReceipt) throws -> URL {
        try RemindersNativeIO.privateDirectory(directory.path)
        let path = directory.appendingPathComponent(receipt.name)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(receipt)
        guard bytes.count <= 131072 else { throw ARLError(code: "codex_receipt_record_invalid") }
        if FileManager.default.fileExists(atPath: path.path) {
            guard try RemindersNativeIO.privateFile(path.path, limit: 131072) == bytes else { throw ARLError(code: "codex_receipt_record_invalid") }
        } else { try RemindersNativeIO.atomicWrite(bytes, to: path.path) }
        return path
    }
    func deferredReceipt(at path: URL) throws -> CodexDeferredReceipt {
        let bytes = try RemindersNativeIO.privateFile(path.path, limit: 131072)
        let raw = try OwnerReadJSON.object(bytes, limit: 131072, maximumDepth: 32)
        guard Set(raw.keys) == ["operationID", "action", "arguments", "response"] else { throw ARLError(code: "codex_receipt_record_invalid") }
        let receipt = try JSONDecoder().decode(CodexDeferredReceipt.self, from: bytes)
        let args = try OwnerReadJSON.object(receipt.arguments, limit: 16384)
        let response = try JSONDecoder().decode(ARLJSON.self, from: receipt.response)
        guard receipt.name == path.lastPathComponent, ["submit", "get", "cancel"].contains(receipt.action),
              (args["operation_id"] as? String).flatMap(UUID.init(uuidString:)) == receipt.operationID,
              receipt.response.count <= 65536,
              let job = args["job_id"] as? String, let jobID = UUID(uuidString: job),
              UUID(uuidString: try CodexTaskReply.decode(response, model: args["model"] as? String ?? CodexScopeOwner.model).id) == jobID
        else { throw ARLError(code: "codex_receipt_record_invalid") }
        return receipt
    }
    func removeDeferred(at path: URL) throws { try FileManager.default.removeItem(at: path) }
    func loadSelection() throws -> CodexExecutionSelection? {
        let url = directory.appendingPathComponent("selection-v1.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let value = try JSONDecoder().decode(CodexExecutionSelection.self, from: RemindersNativeIO.privateFile(url.path, limit: 2048))
        guard value.isWellFormed else { throw ARLError(code: "codex_selection_invalid") }; return value
    }
    func saveSelection(_ value: CodexExecutionSelection) throws {
        if !FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        try RemindersNativeIO.privateDirectory(directory.path)
        try RemindersNativeIO.atomicWrite(try JSONEncoder().encode(value), to: directory.appendingPathComponent("selection-v1.json").path)
    }
    func save(_ record: CodexLocalTask) throws {
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        try RemindersNativeIO.privateDirectory(directory.path)
        if FileManager.default.fileExists(atPath: path) { _ = try RemindersNativeIO.privateFile(path, limit: 131072) }
        let data = try JSONEncoder().encode(record)
        guard data.count <= 131072 else { throw ARLError(code: "codex_task_record_invalid") }
        try RemindersNativeIO.atomicWrite(data, to: path)
    }
}

/// One client and one durable operation follow the existing native-owned core.
/// Startup only restores/queries a record; it never submits a new model task.
@MainActor @Observable final class CodexNativeController {
    struct Port {
        let status: @MainActor () async throws -> CodexServiceStatus
        let submit: @MainActor (String, UUID) async throws -> CodexTaskReply
        let get: @MainActor (UUID) async throws -> CodexTaskReply
        let cancel: @MainActor (UUID) async throws -> CodexTaskReply
        var submitSelection: (@MainActor (String, UUID, CodexExecutionSelection) async throws -> CodexTaskReply)? = nil
    }
    let enabled: Bool
    private(set) var status: CodexServiceStatus?
    private(set) var executionSelection: CodexExecutionSelection?
    var executionCatalog: CodexExecutionCatalog? { status?.execution_catalog }
    var selectionAvailable: Bool {
        guard let executionSelection else { return executionCatalog == nil }
        return executionCatalog?.permits(executionSelection) == true
    }
    func selectExecution(_ value: CodexExecutionSelection) {
        guard !busy, executionCatalog?.permits(value) == true else { return }
        do {
            try records.saveSelection(value); executionSelection = value
            if ["codex_selection_unavailable", "codex_selection_invalid"].contains(errorCode ?? "") { errorCode = nil }
            message = nil
        }
        catch { errorCode = "codex_selection_unavailable"; message = "选择尚未保存，请重试。" }
    }
    private(set) var taskRecord: CodexLocalTask?
    private(set) var message: String?
    private(set) var errorCode: String?
    private(set) var statusReading = false
    private(set) var pendingReceiptCount = 0
    @ObservationIgnored private let port: Port
    @ObservationIgnored private let records: CodexLocalTaskStore
    @ObservationIgnored private let journal: CodexBusinessJournal
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var cancelWork: Task<Void, Never>?
    @ObservationIgnored private var held = false
    var busy: Bool { work != nil || cancelWork != nil }
    var canSubmit: Bool {
        enabled && !held && !busy && selectionAvailable && errorCode != "codex_task_record_invalid" && status?.route_enabled == true
            && status?.execution_preferences_verified == true && (taskRecord == nil || taskRecord?.permitsNewIntent == true)
    }
    var canInspect: Bool { enabled && !held && !busy && taskRecord != nil }
    init(home: URL, enabled: Bool, port: Port? = nil) {
        self.enabled = enabled
        records = CodexLocalTaskStore(home.appendingPathComponent("codex-tasks-v1.noindex"))
        journal = CodexBusinessJournal(directory: home.appendingPathComponent("codex-business-v1.noindex"))
        if let port { self.port = port }
        else {
            let client = CodexTextClient(home: home, model: CodexScopeOwner.model)
            self.port = Port(status: { try await client.status() }, submit: { try await client.submit(input: $0, operationID: $1) },
                get: { try await client.get(id: $0) }, cancel: { try await client.cancel(id: $0) },
                submitSelection: { try await client.submit(input: $0, operationID: $1, selection: $2) })
        }
        if enabled {
            do {
                taskRecord = try records.load()
                do { executionSelection = try records.loadSelection() }
                catch { errorCode = "codex_selection_invalid"; message = "保存的设置需要重新选择，原任务仍保留。" }
                pendingReceiptCount = try records.deferredPaths().count
                if pendingReceiptCount > 0 { showDeferredReceiptError() }
            }
            catch { errorCode = "codex_task_record_invalid"; message = "原任务记录需要核对，暂不提交新任务。" }
        }
    }
    deinit { work?.cancel(); cancelWork?.cancel() }
    func refreshStatus() async {
        guard enabled, !statusReading else { return }
        statusReading = true; defer { statusReading = false }
        do {
            status = try await port.status()
            if executionSelection == nil, let current = status?.execution_catalog?.current { executionSelection = current }
            if ["unknown_method", "disconnected", "invalid_response"].contains(errorCode ?? "") { errorCode = nil }
        }
        catch { errorCode = (error as? ARLError)?.code ?? "disconnected" }
    }
    func submit(_ input: String) {
        guard canSubmit, let scope = status?.scope_generation, !input.isEmpty, input.utf8.count <= 8192 else { return }
        let record = CodexLocalTask(schema: 1, operationID: UUID(), model: executionSelection?.model ?? CodexScopeOwner.model, selection: executionSelection, scopeGeneration: scope, input: input,
            intentDigest: CodexLocalTask.digest(input: input, scope: scope, selection: executionSelection), createdAt: Date(), phase: "prepared", outputLogged: false)
        start(record, submitting: true)
    }
    func inspectOriginal() {
        guard canInspect, let record = taskRecord else { return }
        if record.jobID == nil {
            // Only this explicit action may repeat the SAME key/body after a
            // lost submit acknowledgement. Never silently create another key.
            guard status?.route_enabled == true, status?.scope_generation == record.scopeGeneration else {
                message = "原请求尚未确认，当前范围已变化；保留原编号，不自动提交。"; return
            }
        }
        if pendingReceiptCount > 0 && record.permitsNewIntent {
            work = Task { @MainActor [self] in
                defer { work = nil }
                do { try flushDeferredReceipts(); message = "已补存原回执；原任务终态保持不变。" }
                catch { showDeferredReceiptError() }
            }
            return
        }
        start(record, submitting: record.jobID == nil)
    }
    private func start(_ record: CodexLocalTask, submitting: Bool) {
        guard work == nil, cancelWork == nil, enabled, !held else { return }
        work = Task { @MainActor [self] in
            defer { work = nil }
            do {
                // A genuine new intent may also repair prior audit gaps. Failure
                // does not reclassify an already confirmed old terminal result.
                do { try flushDeferredReceipts() } catch { showDeferredReceiptError() }
                try records.save(record); taskRecord = record
                let args = try arguments(record, action: submitting ? "submit" : "get")
                try log(action: submitting ? "submit" : "get", record: record, args: args, response: nil)
                let reply: CodexTaskReply
                if submitting {
                    if let selection = record.selection {
                        guard let submitSelection = port.submitSelection else { throw ARLError(code: "codex_selection_unsupported") }
                        reply = try await submitSelection(record.input, record.operationID, selection)
                    } else { reply = try await port.submit(record.input, record.operationID) }
                }
                else if let id = record.jobID { reply = try await port.get(id) }
                else { throw ARLError(code: "codex_task_record_invalid") }
                try accept(reply, record: record, action: submitting ? "submit" : "get", args: args)
                if held { requestCancel() }
                try await pollOriginal()
            } catch {
                errorCode = (error as? ARLError)?.code ?? "codex_request_unconfirmed"
                if pendingReceiptCount > 0 && taskRecord?.permitsNewIntent == true { showDeferredReceiptError() }
                else { message = "本次状态未确认；原请求编号和内容已保留，只能核对此请求。" }
            }
            await refreshStatus()
        }
    }
    func requestCancel() {
        guard enabled, cancelWork == nil, let record = taskRecord, let id = record.jobID,
              !["succeeded", "failed", "cancelled", "needs_review"].contains(record.phase) else { return }
        cancelWork = Task { @MainActor [self] in
            defer { cancelWork = nil }
            do {
                let args = try arguments(record, action: "cancel")
                try log(action: "cancel", record: record, args: args, response: nil)
                let reply = try await port.cancel(id)
                try accept(reply, record: record, action: "cancel", args: args)
                message = reply.state == "cancelled" ? "任务已取消；原生停止状态见任务回执。" : "已请求取消，等待原任务终态。"
                if work == nil { try await pollOriginal() }
            } catch {
                errorCode = (error as? ARLError)?.code ?? "codex_cancel_unconfirmed"
                if pendingReceiptCount > 0 && taskRecord?.permitsNewIntent == true { showDeferredReceiptError() }
                else { message = "取消尚未确认，保留原任务查询。" }
            }
        }
    }
    private func pollOriginal() async throws {
        for _ in 0..<90 {
            guard let record = taskRecord, let id = record.jobID else { return }
            if ["succeeded", "failed", "cancelled", "needs_review"].contains(record.phase) { return }
            try await Task.sleep(for: .milliseconds(500))
            let args = try arguments(record, action: "get")
            try log(action: "get", record: record, args: args, response: nil)
            try accept(await port.get(id), record: record, action: "get", args: args)
        }
        message = "本次查询已结束，稍后可核对原任务；不会重新提交。"
    }
    private func arguments(_ record: CodexLocalTask, action: String) throws -> Data {
        var value: [String: Any] = ["operation_id": record.operationID.uuidString.lowercased(), "scope_generation": record.scopeGeneration, "model": record.model]
        if action == "submit" { value["model"] = record.model; value["input"] = record.input; value["max_output_bytes"] = 4096 }
        if action == "submit", let selection = record.selection { value["reasoning_effort"] = selection.reasoning_effort; value["service_tier"] = selection.service_tier }
        if action != "submit" { guard let id = record.jobID else { throw ARLError(code: "codex_task_record_invalid") }; value["job_id"] = id.uuidString.lowercased() }
        return try OwnerReadWire.encode(value, limit: 16384)
    }
    private func log(action: String, record: CodexLocalTask, args: Data, response: Data?) throws {
        do { try journal.record(action: action, operationID: record.operationID, argumentsJSON: args, responseJSON: response) }
        catch { throw ARLError(code: "business_log_unavailable") }
    }
    private func showDeferredReceiptError() {
        errorCode = "business_log_unavailable"
        message = "另有迟到回执待补存；已确认的原任务终态有效。核对原任务可补存，也可提交新的任务。"
    }
    private func flushDeferredReceipts() throws {
        let paths = try records.deferredPaths()
        pendingReceiptCount = paths.count
        for path in paths {
            let receipt = try records.deferredReceipt(at: path)
            do { try journal.record(action: receipt.action, operationID: receipt.operationID,
                argumentsJSON: receipt.arguments, responseJSON: receipt.response) }
            catch { throw ARLError(code: "business_log_unavailable") }
            try records.removeDeferred(at: path)
            pendingReceiptCount -= 1
        }
        if errorCode == "business_log_unavailable" { errorCode = nil }
    }
    private func accept(_ reply: CodexTaskReply, record: CodexLocalTask, action: String, args: Data) throws {
        guard taskRecord?.operationID == record.operationID, let id = UUID(uuidString: reply.id), record.jobID == nil || record.jobID == id else { throw ARLError(code: "invalid_response") }
        var value: [String: Any] = ["id": reply.id, "tool": reply.tool, "state": reply.state, "attempts": reply.attempts,
            "result": NSNull(), "error": reply.error as Any? ?? NSNull(), "updated": reply.updated]
        if let result = reply.result { value["result"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(result), options: .fragmentsAllowed) }
        if let progress = reply.progress { value["progress"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(progress), options: .fragmentsAllowed) }
        let raw = try OwnerReadWire.encode(value, limit: 65536)
        let decoded = try JSONDecoder().decode(ARLJSON.self, from: raw)
        _ = try CodexTaskReply.decode(decoded, model: record.model)
        if reply.state == "succeeded", let selection = record.selection {
            guard reply.result?["execution_preferences"]?["reasoning_effort"]?.text == selection.reasoning_effort,
                  reply.result?["execution_preferences"]?["service_tier"]?.text == selection.service_tier else { throw ARLError(code: "codex_preferences_unverified") }
        }
        if let current = taskRecord?.reply,
           current.updated > reply.updated || ["succeeded", "failed", "cancelled", "needs_review"].contains(current.state) && current.state != reply.state {
            // Persist the complete late receipt separately before journaling.
            // The primary terminal outputLogged flag still describes the valid
            // current result; this audit gap must not lock genuine new intents.
            _ = try records.deferReceipt(.init(operationID: record.operationID, action: action, arguments: args, response: raw))
            pendingReceiptCount = try records.deferredPaths().count
            try flushDeferredReceipts()
            return
        }
        var next = taskRecord ?? record; next.jobID = id; next.replyData = raw; next.phase = reply.state; next.outputLogged = false
        try records.save(next); taskRecord = next
        try log(action: action, record: next, args: args, response: raw)
        next.outputLogged = true; try records.save(next); taskRecord = next
        errorCode = nil
        if pendingReceiptCount > 0 { showDeferredReceiptError(); return }
        message = reply.state == "succeeded" ? "已完成原任务。" : reply.state == "needs_review" ? "原任务结果待核，不会自动重播。" : nil
    }
    func suspendForExit() { held = true; requestCancel() }
    func resumeAfterCancelledExit() { held = false }
}
