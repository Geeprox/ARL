import Foundation
import ARLRemindersCore

@main struct RemindersCatalogJournalTests {
    static func main() throws {
        let home = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let repository = FixtureRepository()
        repository.sourceItems = [.init(id: "source", title: "Synthetic account", type: 2)]
        repository.listItems = [.init(id: "list", title: "Synthetic list", sourceID: "source", writable: true)]
        let identity = RemindersFirstIdentity(helper_bundle_id: "local.arl.remindersbridge", executable_sha256: String(repeating: "a", count: 64), designated_requirement_sha256: String(repeating: "b", count: 64))
        let handler = RemindersProductHandler(home: home.path, identity: identity, policy: String(repeating: "c", count: 64), repository: repository, catalog: {
            .init(sources: [.init(id: "source", title: "Synthetic account", type: 2)], lists: [.init(id: "list", title: "Synthetic list", source_id: "source", writable: true)])
        }, permission: { "full_access" })
        func call(_ frame: RemindersProductFrame) -> RemindersProductReply { handler.handle(frame, check: {}) }
        var checks = 0
        func expect(_ value: Bool, _ label: String) { precondition(value, label); checks += 1 }
        expect(call(.init(.select, sourceID: "source", listID: "list")).code == "target_selected", "prepare an intact synthetic journal")
        let anchor = home.appendingPathComponent("product-v1.anchor")
        let originalAnchor = try Data(contentsOf: anchor)
        let tasks = home.appendingPathComponent("product-v1/tasks")
        try FileManager.default.moveItem(at: tasks, to: home.appendingPathComponent("preserved-tasks"))
        try FileManager.default.createDirectory(at: tasks, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let metadata = call(.init(.catalog))
        expect(metadata.code == "ok" && metadata.outcome == "refreshed", "catalog survives independent default journal damage")
        expect(metadata.catalog?.lists.map(\.id) == ["list"], "catalog comes from the existing repository")
        expect(metadata.default_target == nil && metadata.target == nil && metadata.default_status == "product_journal_missing_or_replaced", "damaged default remains explicitly unavailable")
        expect(call(.init(.selection)).code == "product_journal_missing_or_replaced", "selection still rejects damage")
        expect(call(.init(.select, sourceID: "source", listID: "list")).code == "product_journal_missing_or_replaced", "cannot select around damaged history")
        expect(call(.init(.status, taskID: UUID().uuidString.lowercased())).code == "product_journal_missing_or_replaced", "status still rejects damage")
        let read = try JSONSerialization.data(withJSONObject: ["tool": "apple.reminders.query.v3", "args": ["list_id": "list"]])
        let readReply = call(.init(.read, requestJSON: String(decoding: read, as: UTF8.self)))
        expect(readReply.code == "product_journal_missing_or_replaced" && readReply.result == nil, "business read cannot bypass damaged journal")
        let task = UUID().uuidString.lowercased()
        let write = try JSONSerialization.data(withJSONObject: ["tool": "apple.reminders.create.v3", "args": ["list_id": "list", "title": "Synthetic", "operation_id": try RemindersProductRequest.operationID(task)]])
        expect(call(.init(.submit, taskID: task, requestJSON: String(decoding: write, as: UTF8.self))).code == "product_journal_missing_or_replaced", "mutation cannot bypass damaged journal")
        expect(repository.saveAttempts == 0, "no attempted native save")
        expect(try Data(contentsOf: anchor) == originalAnchor, "anchor bytes preserved")
        expect(FileManager.default.fileExists(atPath: home.appendingPathComponent("preserved-tasks").path), "old task directory preserved")
        print("PASS \(checks) catalog/journal checks; real Apple reads=0 writes=0")
    }
}
