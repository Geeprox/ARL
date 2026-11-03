import Foundation
import ARLRemindersCore

@MainActor private final class StatusUnusedCalendar: CalendarBusinessBackend {
    var access: CalendarBusinessAccess { .full_access }
    func calendars() throws -> [CalendarBusinessCalendar] { preconditionFailure("no calendar read") }
    func query(_ value: CalendarBusinessQuery) throws -> (events: [CalendarBusinessEvent], truncated: Bool) { preconditionFailure("no calendar query") }
    func get(_ target: CalendarBusinessTarget) throws -> CalendarBusinessEvent { preconditionFailure("no calendar item") }
    func prepare(_ request: CalendarBusinessRequest) throws -> CalendarBusinessClaim { preconditionFailure("no calendar prepare") }
    func commit(_ claim: CalendarBusinessClaim) throws -> CalendarBusinessOperation { preconditionFailure("no calendar effect") }
}

@main enum AppleOwnerStatusFlowTests {
    @MainActor static func main() async throws {
        let home = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let repository = FixtureRepository()
        repository.sourceItems = [.init(id: "synthetic-source", title: "Synthetic", type: 2)]
        repository.listItems = [.init(id: "synthetic-list", title: "Synthetic", sourceID: "synthetic-source", writable: true)]
        let identity = RemindersFirstIdentity(helper_bundle_id: "local.arl.remindersbridge",
            executable_sha256: String(repeating: "a", count: 64), designated_requirement_sha256: String(repeating: "b", count: 64))
        let helper = RemindersProductHandler(home: home.path, identity: identity, policy: String(repeating: "c", count: 64),
            repository: repository, catalog: {
                .init(sources: [.init(id: "synthetic-source", title: "Synthetic", type: 2)],
                    lists: [.init(id: "synthetic-list", title: "Synthetic", source_id: "synthetic-source", writable: true)])
            }, permission: { "full_access" })
        var ensures = 0, sends: [RemindersProductAction] = [], confirmations = 0, checks = 0
        func expect(_ value: Bool, _ label: String) { precondition(value, label); checks += 1 }
        let controller = RemindersProductController(port: .init(begin: { _ in true }, end: { _ in },
            ensureService: { ensures += 1 }, send: { frame in sends.append(frame.action); return helper.handle(frame, check: {}) },
            record: { _, _, _, _ in }))
        let calendar = CalendarBusinessHandler(backend: StatusUnusedCalendar(), port: .init(verify: {}, lookup: { _ in nil },
            claim: { _ in preconditionFailure("no calendar claim") }, finish: { _ in preconditionFailure("no calendar finish") },
            record: { _, _ in preconditionFailure("no calendar journal") }))
        let owner = AppleProductOwnerExecutor(home: home, events: AppleDirectExecutor(), reminders: controller, calendar: calendar,
            port: .init(begin: { _ in true }, end: { _ in }, verify: {}, notesFolder: { nil }, messagesAccount: { nil }),
            confirmation: { _, _ in confirmations += 1; return false })
        let tool = "mio_reminders_product_operation_status"
        let missingID = "11111111-1111-4111-8111-111111111111"
        let taskID = "22222222-2222-4222-8222-222222222222"
        func call(_ name: String, _ args: [String: Any]) async throws -> [String: Any] {
            let raw = try OwnerReadWire.encode(args, limit: 65536)
            return try OwnerReadJSON.object(await owner.execute(tool: name, argumentsJSON: raw, callID: UUID()), limit: 262144)
        }
        func adapter(_ value: [String: Any], task: String = taskID) throws -> [String: Any] {
            var calls = 0
            let result = try MioReadOwnerAdapter.respond(["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                "params": ["name": tool, "arguments": ["task_id": task]]], ownerCall: { name, bytes in
                    calls += 1
                    let forwarded = try OwnerReadJSON.object(bytes, limit: 65536)
                    expect(name == tool && forwarded["task_id"] as? String == task,
                        "adapter forwards exact original status intent")
                    return try OwnerReadWire.encode(value, limit: OwnerReadWire.responseLimit)
                })["result"] as! [String: Any]
            expect(calls == 1, "status never retries")
            return result
        }
        func retained(_ value: [String: Any], task: String = taskID, success: Bool = false) throws {
            let result = try adapter(value, task: task)
            expect(result["isError"] as? Bool == !success, "only saved receipt is success")
            expect((result["structuredContent"] as! NSDictionary).isEqual(to: value), "real adapter retains original record observation")
        }
        let missing = try await call(tool, ["task_id": missingID])
        expect(missing["state"] as? String == "operation_missing" && missing["code"] as? String == "operation_missing",
            "owner projects missing status explicitly")
        expect(sends == [.status] && ensures == 0 && repository.saveAttempts == 0, "missing status has no service startup or effect")
        expect(!FileManager.default.fileExists(atPath: home.path + "/product-v1"), "missing status does not create journal")
        try retained(missing, task: missingID)
        let created = try await call("mio_reminders_create_item", ["task_id": taskID, "list_id": "synthetic-list", "title": "Synthetic status fixture"])
        expect(created["state"] as? String == "saved_local" && repository.saveAttempts == 1, "one synthetic repository effect")
        let path = home.path + "/product-v1/tasks/" + taskID + ".json"
        let original = try RemindersNativeIO.privateFile(path, limit: 180000)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let saved = try await call(tool, ["task_id": taskID])
        try retained(saved, success: true)
        expect(try RemindersNativeIO.privateFile(path, limit: 180000) == original, "saved status never changes record")
        var unknown = [String: Any]()
        for state in ["pending", "unknown", "rejected"] {
            var record = try JSONDecoder().decode(RemindersProductRecord.self, from: original)
            record.state = state; record.code = state == "rejected" ? "revision_conflict" : "outcome_unknown"; record.result_json = nil
            let bytes = try encoder.encode(record)
            try RemindersNativeIO.atomicWrite(bytes, to: path)
            let before = sends.count, beforeEnsures = ensures
            let value = try await call(tool, ["task_id": taskID])
            expect(value["state"] as? String == state && value["code"] as? String == record.code, "actual v3 state and code preserved")
            try retained(value)
            expect(sends.count == before + 1 && sends.last == .status && ensures == beforeEnsures && repository.saveAttempts == 1,
                "negative status only observes original record")
            expect(try RemindersNativeIO.privateFile(path, limit: 180000) == bytes, "negative status leaves frozen record intact")
            if state == "unknown" { unknown = value }
        }
        func changed(_ value: [String: Any], _ transform: (inout [String: Any], inout [String: Any], inout [String: Any]) -> Void) -> [String: Any] {
            var value = value, result = value["result"] as! [String: Any], task = (value["result"] as? [String: Any])?["task"] as? [String: Any] ?? [:]
            transform(&value, &result, &task)
            if !task.isEmpty { result["task"] = task }; value["result"] = result; return value
        }
        var malformed: [[String: Any]] = []
        malformed.append(changed(unknown) { value, _, _ in value["task_id"] = missingID })
        malformed.append(changed(unknown) { _, _, task in task["task_id"] = missingID })
        malformed.append(changed(unknown) { _, _, task in task["request_sha256"] = String(repeating: "0", count: 64) })
        malformed.append(changed(unknown) { _, _, task in task["operation_id"] = missingID })
        malformed.append(changed(unknown) { _, result, _ in result["action"] = "submit" })
        malformed.append(changed(unknown) { _, result, _ in result["schema_version"] = 2 })
        malformed.append(changed(unknown) { _, result, _ in result["capability_id"] = "other" })
        malformed.append(changed(unknown) { _, result, _ in result["automatic_replay"] = true })
        malformed.append(changed(unknown) { _, _, task in task["state"] = "pending" })
        malformed.append(changed(unknown) { value, result, task in value["code"] = "saved_local"; result["code"] = "saved_local"; task["code"] = "saved_local" })
        malformed.append(changed(unknown) { _, _, task in task["result_json"] = "{}" })
        malformed.append(changed(unknown) { _, _, task in var target = task["target"] as! [String: Any]; target["policy_sha256"] = String(repeating: "d", count: 64); task["target"] = target })
        for state in ["draft", "attempting"] {
            malformed.append(changed(unknown) { value, _, task in value["state"] = state; task["state"] = state })
        }
        for key in ["business_log_available", "automatic_replay"] {
            malformed.append(changed(missing) { value, _, _ in value[key] = key == "automatic_replay" })
        }
        malformed.append(changed(missing) { _, result, _ in result["business_log_available"] = false })
        malformed.append(changed(missing) { _, result, _ in result["action"] = "read" })
        malformed.append(changed(missing) { _, result, _ in result["outcome"] = "completed" })
        malformed.append(changed(missing) { value, _, _ in value["state"] = "refreshed" })
        malformed.append(changed(missing) { value, _, _ in value["task_id"] = taskID })
        malformed.append(changed(missing) { _, _, task in task["task_id"] = missingID })
        for (index, value) in malformed.enumerated() {
            let result = try adapter(value, task: index < 14 ? taskID : missingID)
            let body = result["structuredContent"] as! [String: Any]
            expect(result["isError"] as? Bool == true && body["code"] as? String == "invalid_arguments", "wrong task/hash/state/receipt rejected")
            expect(body["task_id"] as? String == (index < 14 ? taskID : missingID), "rejection retains caller's original task ID")
        }
        // Real helper journal corruption remains a finite read rejection rather
        // than being rewritten as operation_missing or triggering a submission.
        var corrupt = try OwnerReadJSON.object(original, limit: 180000)
        corrupt["request_sha256"] = String(repeating: "0", count: 64)
        try RemindersNativeIO.atomicWrite(try OwnerReadWire.encode(corrupt, limit: 180000), to: path)
        let rejected = try await call(tool, ["task_id": taskID])
        expect(rejected["code"] as? String == "product_record_changed", "actual helper rejects corrupt frozen hash")
        try retained(rejected)
        expect(repository.saveAttempts == 1 && confirmations == 0, "all status and malformed adapter paths have no effect or prompt")
        print("PASS \(checks) real Owner/Controller/Helper/Mio status checks; installed=0 real_writes=0")
    }
}
