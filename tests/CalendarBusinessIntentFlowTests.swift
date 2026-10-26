import Foundation

// In-memory UI preferences and synthetic business ports only. No EventKit store,
// real permission API, user calendar body or durable production task is touched.
final class CalendarIntentPreferences: UserDefaults, @unchecked Sendable {
    private var values: [String: Any] = [:]
    override func string(forKey key: String) -> String? { values[key] as? String }
    override func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
    override func removeObject(forKey key: String) { values.removeValue(forKey: key) }
}
@MainActor final class CalendarIntentFlowFixture: CalendarBusinessBackend {
    var permissionState: CalendarPermissionState = .fullAccess
    var access: CalendarBusinessAccess { permissionState == .writeOnly ? .write_only : .full_access }
    let defaultCalendar = CalendarBusinessCalendar(id: "calendar-a", title: "默认", source: "本机", writable: true, is_default: true)
    let otherCalendar = CalendarBusinessCalendar(id: "calendar-b", title: "其他", source: "本机", writable: true, is_default: false)
    var unknownTask: String?
    var logFailuresRemaining = 0
    var failAllLogs = false
    var failRead = false
    var approvals = 0
    var effects: [String: Int] = [:]
    var operations: [String: CalendarBusinessOperation] = [:]
    var committed: [CalendarBusinessClaim] = []
    func calendars() throws -> [CalendarBusinessCalendar] {
        if failRead { throw CalendarBusinessFault("synthetic_calendar_unavailable") }
        return [defaultCalendar, otherCalendar]
    }
    func query(_ value: CalendarBusinessQuery) throws -> (events: [CalendarBusinessEvent], truncated: Bool) { ([], false) }
    func get(_ target: CalendarBusinessTarget) throws -> CalendarBusinessEvent { throw CalendarBusinessFault("fixture_not_needed") }
    func prepare(_ request: CalendarBusinessRequest) throws -> CalendarBusinessClaim {
        try request.validate()
        if access == .write_only {
            guard request.action == .create, request.draft?.calendar_id == nil else { throw CalendarBusinessFault("needs_full_access") }
        }
        let id = request.draft?.calendar_id ?? request.target?.calendar_id ?? defaultCalendar.id
        guard let calendar = [defaultCalendar, otherCalendar].first(where: { $0.id == id }) else { throw CalendarBusinessFault("calendar_missing") }
        return .init(request: request, calendar: calendar)
    }
    func commit(_ claim: CalendarBusinessClaim) throws -> CalendarBusinessOperation {
        effects[claim.request.task_id, default: 0] += 1; committed.append(claim)
        if unknownTask == claim.request.task_id { throw CalendarBusinessFault("synthetic_receipt_lost") }
        return .init(task_id: claim.request.task_id, digest: claim.request.digest, action: claim.request.action,
                     state: access.canRead ? .saved_local : .saved_unreadable, code: "fixture_only", event: nil)
    }
    func handler() -> CalendarBusinessHandler {
        .init(backend: self, port: .init(verify: {}, lookup: { self.operations[$0] }, approve: { _ in self.approvals += 1; return true }, claim: { claim in
            guard self.operations[claim.request.task_id] == nil else { throw CalendarBusinessFault("operation_consumed") }
            self.operations[claim.request.task_id] = .init(task_id: claim.request.task_id, digest: claim.request.digest,
                action: claim.request.action, state: .attempting, code: "attempting", event: nil)
        }, finish: { self.operations[$0.task_id] = $0 }, record: { _, _ in
            if self.failAllLogs || self.logFailuresRemaining > 0 {
                self.logFailuresRemaining = max(0, self.logFailuresRemaining - 1)
                throw CalendarBusinessFault("synthetic_optional_log_unavailable")
            }
        }))
    }
    func permission(_ preferences: UserDefaults) -> CalendarPermissionController {
        .init(enabled: true, readStatus: { self.permissionState }, requestAccess: { preconditionFailure("no real permission requests") },
              verifyOwner: {}, foreground: { true }, preferences: preferences, startAutomatically: false,
              requestReadWrite: { preconditionFailure("no real permission requests") }, verifyReadWriteUsage: {})
    }
}
@main enum CalendarBusinessIntentFlowTests {
    static let oldID = "4e516a24-1674-4f37-a8fc-1d9eeac04f93"
    static func draft(_ title: String, calendar: String?) -> CalendarBusinessDraft {
        .init(calendar_id: calendar, title: title, start: "2026-10-20T18:00:00+08:00", end: "2026-10-20T18:10:00+08:00",
              time_zone: "Asia/Shanghai", all_day: false, alarm_seconds: [300], recurrence: nil)
    }
    @MainActor static func main() async throws {
        let f = CalendarIntentFlowFixture(), preferences = CalendarIntentPreferences()
        let permission = f.permission(preferences), handler = f.handler()
        let controller = CalendarBusinessController(permission: permission, handler: handler, preferences: preferences)
        await controller.loadCalendars(); f.unknownTask = oldID
        let oldDraft = draft("旧日程", calendar: "calendar-a")
        await controller.save(oldDraft, taskID: oldID)
        let original = f.operations[oldID]
        precondition(controller.unresolved && original?.state == .outcome_unknown && f.effects[oldID] == 1)

        // C15456-1: explicit new intent archives only the UI selection; the old
        // durable outcome stays unchanged and its original ID never replays.
        controller.startNewIntent()
        precondition(!controller.unresolved && controller.archivedTaskIDs.contains(oldID))
        controller.selectCalendar("calendar-b")
        let freshID = UUID().uuidString.lowercased()
        await controller.save(draft("独立日程", calendar: "calendar-b"), taskID: freshID)
        precondition(f.effects[freshID] == 1 && f.committed.last?.calendar.id == "calendar-b")
        _ = try await handler.execute(.init(taskID: oldID, action: .create, draft: oldDraft))
        precondition(f.effects[oldID] == 1 && f.operations[oldID] == original)

        // Restore with the original unknown task selected, then start a new
        // intent after reconstruction. Archive and durable old status survive.
        await controller.status(taskID: oldID)
        let restored = CalendarBusinessController(permission: permission, handler: handler, preferences: preferences)
        await restored.prepareForDisplay()
        precondition(restored.unresolved && restored.currentTaskID == oldID)
        restored.startNewIntent(); restored.selectCalendar("calendar-a")
        let laterID = UUID().uuidString.lowercased()
        await restored.save(draft("重开后日程", calendar: "calendar-a"), taskID: laterID)
        precondition(f.effects[laterID] == 1 && f.effects[oldID] == 1 && f.operations[oldID] == original)
        precondition(restored.archivedTaskIDs.contains(oldID))

        // C15456-2: select an existing event with no operation card, downgrade
        // the injected permission, then use the same policy the visible default
        // create button consumes. It must submit CREATE with nil calendar_id.
        restored.startNewIntent(); restored.selectCalendar("calendar-b")
        let existingDraft = draft("既有日程", calendar: "calendar-b")
        let target = CalendarBusinessTarget(calendar_id: "calendar-b", event_id: "existing-event",
            occurrence_start: existingDraft.start, revision: String(repeating: "a", count: 64))
        restored.selectEvent(.init(target: target, draft: existingDraft, editable: true,
            recurrence_supported: true, alarms_supported: true, repeating: false))
        precondition(restored.selectedEvent != nil && restored.operation == nil)
        f.permissionState = .writeOnly; permission.refresh()
        precondition(restored.offersDefaultCreate && restored.canAct)
        restored.startNewIntent()
        precondition(restored.selectedEvent == nil)
        let defaultID = UUID().uuidString.lowercased()
        await restored.save(draft("默认新日程", calendar: nil), taskID: defaultID)
        let submitted = f.committed.last!
        precondition(submitted.request.action == .create && submitted.request.target == nil && submitted.request.draft?.calendar_id == nil)
        precondition(submitted.calendar.id == "calendar-a" && restored.operation?.state == .saved_unreadable)
        precondition(f.effects[oldID] == 1 && f.operations[oldID] == original)
        // Coordinator duplicate-key delta: raw and escaped-equivalent keys are
        // rejected before approval, durable claim or effect.
        let strict = CalendarIntentFlowFixture(), strictHandler = strict.handler()
        let valid = CalendarBusinessRequest(taskID: UUID().uuidString.lowercased(), action: .create, draft: draft("校验", calendar: nil))
        let json = String(decoding: try valid.argumentsJSON(), as: UTF8.self)
        let duplicates = [
            json.replacingOccurrences(of: "\"task_id\":", with: "\"task_id\":\"" + valid.task_id + "\",\"task_id\":"),
            json.replacingOccurrences(of: "\"title\":", with: "\"title\":\"重复\",\"title\":"),
            json.replacingOccurrences(of: "\"title\":", with: "\"ti\\u0074le\":\"重复\",\"title\":")
        ]
        for duplicate in duplicates {
            do { _ = try await strictHandler.execute(tool: valid.action.tool, argumentsJSON: Data(duplicate.utf8)); preconditionFailure("duplicate accepted") }
            catch let fault as CalendarBusinessFault { precondition(fault.code == "duplicate_product_key") }
        }
        precondition(strict.approvals == 0 && strict.operations.isEmpty && strict.effects.isEmpty)

        // Best-effort logs cannot block a valid operation/status, mask a backend
        // fault, or lose their warning when a missing-status reply is rebuilt.
        let log = CalendarIntentFlowFixture(), logHandler = log.handler()
        log.failAllLogs = true
        let logRequest = CalendarBusinessRequest(taskID: UUID().uuidString.lowercased(), action: .create, draft: draft("日志降级", calendar: nil))
        let logReply = try await logHandler.execute(logRequest)
        precondition(logReply.operation?.state == .saved_local && !logReply.businessLogAvailable)
        _ = try await logHandler.execute(logRequest)
        precondition(log.effects[logRequest.task_id] == 1)
        let loggedStatus = try await logHandler.execute(.init(taskID: logRequest.task_id, action: .operation_status))
        precondition(loggedStatus.operation?.state == .saved_local && !loggedStatus.businessLogAvailable)
        log.failAllLogs = false; log.logFailuresRemaining = 1
        let missingStatus = try await logHandler.execute(.init(taskID: UUID().uuidString.lowercased(), action: .operation_status))
        precondition(missingStatus.code == "task_not_found" && !missingStatus.businessLogAvailable)
        log.failAllLogs = true; log.failRead = true
        let logPreferences = CalendarIntentPreferences()
        let logController = CalendarBusinessController(permission: log.permission(logPreferences), handler: logHandler, preferences: logPreferences)
        await logController.loadCalendars()
        precondition(!logController.businessLogAvailable && logController.canAct)
        do {
            _ = try await logHandler.execute(.init(taskID: UUID().uuidString.lowercased(), action: .calendars))
            preconditionFailure("backend failure was lost")
        } catch let fault as CalendarBusinessFault { precondition(fault.code == "synthetic_calendar_unavailable") }
        precondition(!logHandler.businessLogAvailable)
        log.failRead = false
        let independentID = UUID().uuidString.lowercased()
        await logController.save(draft("另一个请求", calendar: nil), taskID: independentID)
        precondition(log.effects[independentID] == 1 && !logController.businessLogAvailable)
        print("PASS added coordinator deltas: root/nested/escaped duplicate keys rejected; optional-log failures preserve results, missing-status warning and original backend fault.")
        print("PASS C15456-1: explicit fresh intents before/after controller restore; old ID remains consumed and unknown, effects=1.")
        print("PASS C15456-2: full-access selection then write-only downgrade exposes default create; fresh CREATE, nil calendar_id, saved_unreadable.")
        print("Synthetic ports and memory preferences only; no EventKit, system authorization, real calendar write, app launch or service operation.")
    }
}
