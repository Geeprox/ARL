import Foundation
import ARLRemindersCore

private enum TestFailure: Error { case failed(String) }
private func check(_ condition: Bool, _ name: String) throws { if !condition { throw TestFailure.failed(name) } }
@main enum RemindersProductRequestTests {
    static func main() throws {
        let task = "44444444-4444-4444-8444-444444444444"
        let op = try RemindersProductRequest.operationID(task)
        func wire(_ operation: String, _ fields: [String: Any]) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["tool": "apple.reminders." + operation + ".v3", "args": fields], options: [.sortedKeys])
        }
        func decode(_ operation: String, _ fields: [String: Any]) throws -> RemindersProductRequest {
            try RemindersProductRequest.decode(taskID: task, requestJSON: wire(operation, fields))
        }
        func rejects(_ name: String, _ body: () throws -> Void) throws {
            do { try body() } catch is AdapterFault { return }
            throw TestFailure.failed(name)
        }
        let revision = String(repeating: "a", count: 64)
        let full: [String: Any] = ["due": ["action": "set", "value": ["kind": "date_time", "value": "2026-10-20T09:00:00+08:00", "time_zone": "Asia/Shanghai"]],
            "start": ["action": "set", "value": ["kind": "date_time", "value": "2026-10-20T08:00:00+08:00", "time_zone": "Asia/Shanghai"]],
            "priority": ["action": "set", "value": 9], "recurrence": ["action": "set", "value": ["frequency": "weekly", "interval": 2, "count": 3]],
            "alert": ["action": "set", "value": ["kind": "relative", "offset_seconds": -900]]]
        let created = try decode("create", ["operation_id": op, "list_id": "fixture-list", "title": "fixture task", "patch": full])
        try check(created.request.args.patch?.due?.value?.time_zone == "Asia/Shanghai" && created.request.args.patch?.priority?.value == 9 && created.request.args.patch?.alert?.value?.offset_seconds == -900, "full_fields_preserved")
        let list = try decode("list.create", ["operation_id": op, "source_id": "fixture-source", "title": "fixture list"])
        try check(list.request.args.source_id == "fixture-source", "explicit_source")
        let edit = try decode("update", ["operation_id": op, "list_id": "fixture-list", "reminder_id": "fixture-item", "expected_revision": revision, "patch": ["due": ["action": "clear"]]])
        try check(edit.request.args.expected_revision == revision && edit.request.args.patch?.due?.action == .clear, "revision_and_explicit_clear")
        for operation in ["complete", "uncomplete"] {
            _ = try decode(operation, ["operation_id": op, "list_id": "fixture-list", "reminder_id": "fixture-item", "expected_revision": revision])
        }
        try rejects("edit_without_revision") { _ = try decode("update", ["operation_id": op, "list_id": "fixture-list", "reminder_id": "fixture-item", "patch": full]) }
        try rejects("different_operation_key") { _ = try decode("create", ["operation_id": task, "list_id": "fixture-list", "title": "fixture"]) }
        try rejects("read_cannot_be_mutation_grant") { _ = try decode("query", ["list_id": "fixture-list"]) }
        try rejects("unknown_field") { _ = try decode("create", ["operation_id": op, "list_id": "fixture-list", "title": "fixture", "execute": true]) }
        try rejects("bad_priority") { _ = try decode("create", ["operation_id": op, "list_id": "fixture-list", "title": "fixture", "patch": ["priority": ["action": "set", "value": 10]]]) }
        let raw = String(decoding: try wire("create", ["operation_id": op, "list_id": "fixture-list", "title": "fixture"]), as: UTF8.self)
        let duplicate = raw.replacingOccurrences(of: "\"title\":\"fixture\"", with: "\"title\":\"fixture\",\"ti\\u0074le\":\"changed\"")
        try check(duplicate != raw, "duplicate_fixture_changed")
        try rejects("escaped_duplicate_key") { _ = try RemindersProductRequest.decode(taskID: task, requestJSON: Data(duplicate.utf8)) }
        print("PASS product request: list/create/full fields/edit/complete, revision/key/schema/duplicate boundaries; no EventKit or real writes")
    }
}
