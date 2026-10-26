import Foundation

@MainActor @main enum RemindersHistoryCompatibilityTests {
    enum Failure: Error { case assertion(String) }
    static var checks = 0
    static let runID = "00000000-0000-4000-8000-000000000001"
    static let policy = RemindersUpgradeReview.targetPolicy
    static let subject = RemindersUpgradeReview.oldIdentity.designated_requirement_sha256
    static let previous = RemindersFirstIdentity(helper_bundle_id: "local.arl.remindersbridge", executable_sha256: String(repeating: "a", count: 64), designated_requirement_sha256: subject)
    static let current = RemindersFirstIdentity(helper_bundle_id: "local.arl.remindersbridge", executable_sha256: String(repeating: "b", count: 64), designated_requirement_sha256: subject)
    static let source = RemindersSelectedSource(id: "synthetic-source", title: "Synthetic source", type: 1, default_list_id: "synthetic-list", default_list_title: "Synthetic list")
    static func expect(_ value: Bool, _ label: String) throws {
        guard value else { throw Failure.assertion(label) }; checks += 1
    }
    static func rejected(_ label: String, code: String? = nil, _ body: () throws -> Void) throws {
        do { try body() } catch let error as RemindersTransportFault {
            try expect(code == nil || error.code == code, label); return
        }
        throw Failure.assertion(label)
    }
    static func bytes<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(value)
    }
    static func inventory(_ directory: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        for case let url as URL in FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey])! {
            if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                result[String(url.path.dropFirst(directory.path.count))] = try Data(contentsOf: url)
            }
        }
        return result
    }
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else { throw Failure.assertion("new isolated fixture directory required") }
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        guard root.path == root.resolvingSymlinksInPath().path else { throw Failure.assertion("canonical fixture path required") }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try expect(previous != current, "global identity equality still pins the current executable")
        try expect(RemindersUpgradeReview.storedSubjectMatches(previous, current: current), "history permits code-only upgrade under the same stable subject")
        for identity in [
            RemindersFirstIdentity(helper_bundle_id: "other.helper", executable_sha256: previous.executable_sha256, designated_requirement_sha256: subject),
            RemindersFirstIdentity(helper_bundle_id: previous.helper_bundle_id, executable_sha256: previous.executable_sha256, designated_requirement_sha256: String(repeating: "c", count: 64)),
            RemindersFirstIdentity(helper_bundle_id: previous.helper_bundle_id, executable_sha256: "invalid", designated_requirement_sha256: subject),
            RemindersFirstIdentity(helper_bundle_id: previous.helper_bundle_id, executable_sha256: previous.executable_sha256 + "\n", designated_requirement_sha256: subject)
        ] { try expect(!RemindersUpgradeReview.storedSubjectMatches(identity, current: current), "changed subject or malformed code identity remains rejected") }
        var confirmations = 0
        for disposition in [RemindersUpgradeDisposition.unknown, .completed, .sourceOnly] {
            let directory = root.appendingPathComponent(disposition.rawValue)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let metadata = try bytes(RemindersFrozenSourceMetadata(source: source, identity: RemindersUpgradeReview.oldIdentity, policy_sha256: RemindersUpgradeReview.oldPolicy))
            let binding = try bytes(RemindersSourceBinding(source: source, identity: RemindersUpgradeReview.oldIdentity, policy_sha256: RemindersUpgradeReview.oldPolicy, expires_at_ms: 1))
            let smoke = disposition == .completed ? try bytes(RemindersSmokeRecord(run_id: runID, policy_sha256: RemindersUpgradeReview.oldPolicy, source_sha256: RemindersNativeIO.hash(binding), state: "saved_local", list_id: "synthetic-saved-list", reminder_id: "synthetic-saved-item")) : nil
            let evidence = RemindersUpgradeReview.evidence(metadata: metadata, binding: binding, smoke: smoke)
            let receipt = RemindersUpgradeReceipt(schema: 1, identity: previous, policySHA256: policy, runID: runID, disposition: disposition, source: disposition == .sourceOnly ? source : nil, evidence: evidence)
            try RemindersNativeIO.writeNew(metadata, to: directory.path + "/source-metadata.json")
            try RemindersNativeIO.writeNew(binding, to: directory.path + "/source.json")
            if let smoke { try RemindersNativeIO.writeNew(smoke, to: directory.path + "/smoke.json") }
            try RemindersNativeIO.writeNew(try bytes(receipt), to: directory.path + "/upgrade-review-v1.json")
            let journal = directory.appendingPathComponent("operation-journal")
            try FileManager.default.createDirectory(at: journal, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try RemindersNativeIO.writeNew(Data("synthetic existing save budget; never reset".utf8), to: journal.path + "/retained-budget")
            let before = try inventory(directory)
            let store = RemindersUpgradeStore(home: directory.path, identity: current, policy: policy, runID: runID)
            let read = try store.receipt()
            try expect(read?.disposition == disposition && read?.source == receipt.source && read?.identity == previous,
                       "historical result scope and executable provenance survive unchanged")
            try expect(!(try store.needsReview()), "code-only upgrade does not require a new legacy review")
            let reviewed = try await store.review(confirm: { _ in confirmations += 1; return true }, stopped: { false })
            try expect(reviewed.disposition == disposition && reviewed.identity == previous, "existing receipt is read instead of reissued")
            try expect(try inventory(directory) == before, "receipt source expiry and saved budget bytes remain immutable with no new files")
            try rejected("different run still blocked", code: "upgrade_review_changed") {
                try RemindersUpgradeReview.validate(receipt, identity: current, policy: policy, runID: "different-run", evidence: evidence)
            }
            try rejected("different policy still blocked", code: "upgrade_review_changed") {
                try RemindersUpgradeReview.validate(receipt, identity: current, policy: String(repeating: "d", count: 64), runID: runID, evidence: evidence)
            }
            try rejected("changed original evidence still blocked", code: "upgrade_review_changed") {
                try RemindersUpgradeReview.validate(receipt, identity: current, policy: policy, runID: runID, evidence: .init(metadataSHA256: nil, bindingSHA256: evidence.bindingSHA256, smokeSHA256: evidence.smokeSHA256))
            }
        }
        try expect(confirmations == 0, "compatibility does not generate a new user authorization")
        let existingBinding = RemindersSourceBinding(source: source, identity: previous, policy_sha256: policy, expires_at_ms: 2000)
        let original = try bytes(existingBinding)
        try RemindersUpgradeReview.validateBinding(existingBinding, identity: current, policy: policy, nowMS: 1000)
        try expect(try bytes(existingBinding) == original && existingBinding.expires_at_ms == 2000, "accepted source keeps its exact original expiry and scope")
        try rejected("expired source remains expired", code: "source_expired") {
            try RemindersUpgradeReview.validateBinding(existingBinding, identity: current, policy: policy, nowMS: 2000)
        }
        try rejected("different source policy remains blocked", code: "target_changed") {
            try RemindersUpgradeReview.validateBinding(existingBinding, identity: current, policy: "different-policy", nowMS: 1000)
        }
        let directory = root.appendingPathComponent("current-policy-records")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try RemindersNativeIO.writeNew(try bytes(RemindersFrozenSourceMetadata(source: source, identity: previous, policy_sha256: policy)), to: directory.path + "/source-metadata.json")
        try RemindersNativeIO.writeNew(original, to: directory.path + "/source.json")
        let before = try inventory(directory)
        let store = RemindersUpgradeStore(home: directory.path, identity: current, policy: policy, runID: runID)
        try expect(!(try store.needsReview()), "same-policy frozen source metadata can be read after code-only upgrade")
        try expect(try inventory(directory) == before, "ordinary stored source records are never rewritten during compatibility reads")
        print("{\"status\":\"PASS\",\"checks\":\(checks),\"historical_records_and_budgets_unchanged\":true,\"unknown_or_completed_promoted\":false,\"new_authorizations\":0,\"EventKit_calls\":0,\"saves\":0}")
    }
}
