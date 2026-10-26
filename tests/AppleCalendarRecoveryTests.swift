import Foundation

/// Real handler, owner envelope and durable task store; all provider effects are synthetic.
@MainActor final class CalendarRecoveryFixture: CalendarBusinessBackend {
    let mode: String
    let home: URL
    let store: CalendarBusinessTaskStore
    var access: CalendarBusinessAccess { mode == "permission" ? .denied : .full_access }
    var preparations = 0, approvals = 0, claims = 0, effects = 0, finishes = 0
    var changed = false
    let calendar = CalendarBusinessCalendar(id: "fixture-calendar", title: "Synthetic", source: "Fixture", writable: true, is_default: true)
    let id = UUID().uuidString.lowercased()
    let draft = CalendarBusinessDraft(calendar_id: "fixture-calendar", title: "Synthetic recovery", start: "2099-01-01T10:00:00Z",
        end: "2099-01-01T10:05:00Z", time_zone: "UTC", all_day: false, alarm_seconds: [], recurrence: nil)
    init(mode: String, root: URL) throws {
        self.mode = mode; home = root.appendingPathComponent(UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        store = CalendarBusinessTaskStore(home: home)
    }
    func calendars() throws -> [CalendarBusinessCalendar] { [calendar] }
    func query(_ value: CalendarBusinessQuery) throws -> (events: [CalendarBusinessEvent], truncated: Bool) { ([], false) }
    func get(_ target: CalendarBusinessTarget) throws -> CalendarBusinessEvent { preconditionFailure("no provider read") }
    func prepare(_ request: CalendarBusinessRequest) throws -> CalendarBusinessClaim {
        preparations += 1
        if mode == "revision" { throw CalendarBusinessFault("revision_changed") }
        if !access.canCreate { throw CalendarBusinessFault("needs_permission") }
        let selected = changed ? CalendarBusinessCalendar(id: "changed-calendar", title: "Changed", source: "Fixture", writable: true, is_default: true) : calendar
        return .init(request: request, calendar: selected)
    }
    func commit(_ claim: CalendarBusinessClaim) throws -> CalendarBusinessOperation {
        effects += 1
        // The same code as a safe permission rejection must stay unknown after claim.
        if mode == "effect" { throw CalendarBusinessFault("needs_permission") }
        let target = CalendarBusinessTarget(calendar_id: calendar.id, event_id: "synthetic-event", occurrence_start: draft.start, revision: String(repeating: "a", count: 64))
        let event = CalendarBusinessEvent(target: target, draft: draft, editable: true, recurrence_supported: true, alarms_supported: true, repeating: false)
        return .init(task_id: id, digest: claim.request.digest, action: .create, state: .saved_local, code: "saved_and_read_back", event: event)
    }
    lazy var handler = makeHandler()
    func makeHandler() -> CalendarBusinessHandler {
        .init(backend: self, port: .init(verify: {}, lookup: { id in
        if self.mode == "lookup" { throw CalendarBusinessFault("needs_permission") }
        return try self.store.lookup(id)
    }, approve: { _ in
        self.approvals += 1
        if self.mode == "changed" { self.changed = true }
        if self.mode == "cancel" { withUnsafeCurrentTask { $0?.cancel() } }
        return self.mode != "decline"
    }, claim: { claim in
        self.claims += 1
        try self.store.claim(claim)
        if self.mode == "claim" { throw CalendarBusinessFault("journal_uncertain") }
    }, finish: { operation in
        self.finishes += 1
        if self.mode == "finish" { throw CalendarBusinessFault("journal_uncertain") }
        try self.store.finish(operation)
    }, record: { _, _ in }))
    }
    lazy var owner: AppleProductOwnerExecutor = {
        let reminders = RemindersProductController(port: .init(begin: { _ in preconditionFailure("no reminders begin") }, end: { _ in },
            ensureService: { preconditionFailure("no helper start") }, send: { _ in preconditionFailure("no helper call") }, record: { _, _, _, _ in preconditionFailure("no reminder record") }))
        return .init(home: home, events: AppleDirectExecutor(), reminders: reminders, calendar: handler,
            port: .init(begin: { _ in true }, end: { _ in }, verify: {}, notesFolder: { nil }, messagesAccount: { nil }),
            confirmation: { _, _ in preconditionFailure("no native UI") })
    }()
    func request(_ action: CalendarBusinessAction = .create, taskID: String? = nil) -> CalendarBusinessRequest {
        .init(taskID: taskID ?? id, action: action, draft: action == .create ? draft : nil)
    }
    func call(_ action: CalendarBusinessAction = .create, taskID: String? = nil) async throws -> [String: Any] {
        let request = request(action, taskID: taskID)
        // Cancellation is contained to each synthetic call, never to the test runner.
        let bytes = try await Task { @MainActor in
            try await self.owner.execute(tool: action.tool, argumentsJSON: request.argumentsJSON(), callID: UUID())
        }.value
        return try OwnerReadJSON.object(bytes, limit: 262144)
    }
}

@main enum AppleCalendarRecoveryTests {
    @MainActor static func main() async throws {
        precondition(CommandLine.arguments.count >= 2)
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        precondition(!FileManager.default.fileExists(atPath: root.path))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let expectBug = CommandLine.arguments.contains("--expect-bug")
        var checks = 0
        func trace(_ value: String) { FileHandle.standardOutput.write(Data((value + "\n").utf8)) }
        func expect(_ value: Bool, _ label: String) {
            guard value else { fatalError(label) }; checks += 1
        }
        for (mode, code) in [("decline", "user_cancelled"), ("revision", "revision_changed"), ("permission", "needs_permission"), ("changed", "target_changed"), ("cancel", "cancelled")] {
            let fixture = try CalendarRecoveryFixture(mode: mode, root: root)
            let reply = try await fixture.call()
            trace("PRECLAIM mode=\(mode) state=\(reply["state"] ?? "missing") code=\(reply["code"] ?? "missing") claims=\(fixture.claims) effects=\(fixture.effects)")
            expect(reply["state"] as? String == (expectBug ? "outcome_unknown" : "unavailable"), "preclaim \(mode) state")
            expect(reply["code"] as? String == (expectBug && mode == "cancel" ? "outcome_unknown" : code), "original preclaim code preserved: \(reply)")
            expect(reply["automatic_replay"] as? Bool == false && reply["task_id"] as? String == fixture.id, "task/no-replay contract preserved")
            expect(fixture.claims == 0 && fixture.effects == 0 && fixture.finishes == 0, "preclaim rejection has zero mutation")
            expect(try fixture.store.lookup(fixture.id) == nil, "no durable intent exists")
            if !expectBug {
                let status = try await fixture.call(.operation_status)
                expect(status["code"] as? String == "task_not_found" && status["state"] as? String == "unavailable", "original rejected task has no consumed record")
                if mode == "permission" {
                    expect((reply["recovery"] as? [String: Any])?["required_action"] as? String == "review_calendar_permission", "safe permission rejection keeps recovery")
                }
            }
        }
        if expectBug {
            trace("REPRODUCED \(checks) checks: five zero-claim rejections incorrectly marked outcome_unknown; real_Apple=0 UI=0 permissions=0")
            return
        }
        let malformed = try CalendarRecoveryFixture(mode: "success", root: root)
        var extra = try JSONSerialization.jsonObject(with: malformed.request().argumentsJSON()) as! [String: Any]
        extra["approved"] = true
        for object in [extra, ["task_id": malformed.id]] {
            let bytes = try await malformed.owner.execute(tool: "mio_calendar_create",
                argumentsJSON: JSONSerialization.data(withJSONObject: object), callID: UUID())
            let reply = try OwnerReadJSON.object(bytes, limit: 262144)
            expect(reply["state"] as? String == "unavailable" && reply["code"] as? String == "invalid_arguments", "malformed wire input never reports consumed")
            expect(reply["automatic_replay"] as? Bool == false && malformed.preparations == 0 && malformed.claims == 0 && malformed.effects == 0, "malformed request stops before backend/claim")
        }
        for mode in ["claim", "effect", "finish"] {
            let fixture = try CalendarRecoveryFixture(mode: mode, root: root)
            let first = try await fixture.call()
            expect(first["state"] as? String == "outcome_unknown", "\(mode) uncertainty preserved")
            expect(first["automatic_replay"] as? Bool == false && first["recovery"] == nil, "uncertainty has no retry guidance")
            expect(try fixture.store.lookup(fixture.id)?.state == (mode == "effect" ? .outcome_unknown : .attempting), "original intent retained")
            for _ in 0..<2 { _ = try await fixture.call() }
            let status = try await fixture.call(.operation_status)
            expect(status["task_id"] as? String == fixture.id, "status uses original operation ID")
            expect(status["state"] as? String == (mode == "effect" ? "outcome_unknown" : "attempting"), "status reports original unresolved record")
            expect(fixture.claims == 1 && fixture.effects == (mode == "claim" ? 0 : 1), "\(mode) repeated submission never claims/effects twice")
            expect(fixture.approvals == 1 && fixture.preparations == 2, "original unresolved operation never reconfirms/prepares")
            trace("UNCERTAIN mode=\(mode) claims=\(fixture.claims) effects=\(fixture.effects) status=\(status["state"] ?? "missing")")
        }
        let lookup = try CalendarRecoveryFixture(mode: "lookup", root: root)
        let blocked = try await lookup.call()
        expect(blocked["state"] as? String == "outcome_unknown" && blocked["code"] as? String == "needs_permission", "failed original lookup cannot prove absence, even for familiar error code")
        expect(blocked["recovery"] == nil && lookup.claims == 0 && lookup.effects == 0 && lookup.approvals == 0, "uncertain original lookup has no resubmit guidance or effect")
        let saved = try CalendarRecoveryFixture(mode: "success", root: root)
        let receipt = try await saved.call()
        let args = try JSONSerialization.jsonObject(with: saved.request().argumentsJSON()) as! [String: Any]
        expect(try AppleProductCapability.admit(receipt, tool: "mio_calendar_create", arguments: args), "successful real owner receipt remains publicly admissible")
        _ = try await saved.call()
        let status = try await saved.call(.operation_status)
        expect(status["state"] as? String == "saved_local" && saved.claims == 1 && saved.effects == 1 && saved.approvals == 1, "saved task and status never re-execute")
        let missing = try await saved.call(.operation_status, taskID: UUID().uuidString.lowercased())
        expect(missing["code"] as? String == "task_not_found", "new status ID does not inspect original task")
        trace("PASS \(checks) Calendar public owner/durable recovery checks; real_Apple=0 UI=0 permissions=0 business_writes=0")
    }
}
