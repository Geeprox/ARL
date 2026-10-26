import Foundation
import Darwin

/// One reviewed local-policy transition. No EventKit, permission, save or cleanup API.
enum RemindersUpgradeDisposition: String, Codable, Sendable {
    case sourceOnly, completed, unknown
}
struct RemindersUpgradeEvidence: Equatable, Codable, Sendable {
    let metadataSHA256: String?
    let bindingSHA256: String?
    let smokeSHA256: String?
}
struct RemindersUpgradeAssessment: Sendable {
    let disposition: RemindersUpgradeDisposition
    let source: RemindersSelectedSource?
    let evidence: RemindersUpgradeEvidence
}
struct RemindersUpgradeReceipt: Codable, Sendable {
    let schema: Int
    let identity: RemindersFirstIdentity
    let policySHA256: String
    let runID: String
    let disposition: RemindersUpgradeDisposition
    let source: RemindersSelectedSource?
    let evidence: RemindersUpgradeEvidence
}
enum RemindersUpgradeReview {
    static let oldPolicy = "72fde451a6362f5448a8d7942c71d1e3f23c9624bcbd72ea85d1c988e3610393"
    static let targetPolicy = "e84c6dfb1eab7893087e6451f53933d9380a40779eca5f06376bb3a98227bb71"
    static let oldIdentity = RemindersFirstIdentity(helper_bundle_id: "local.arl.remindersbridge",
        executable_sha256: "17f55bad17d7159cafdcae27c1c69943ac8179cffd9dcdc0fac38eb3de22fb26",
        designated_requirement_sha256: "4ca3deb93ea7c9c4efb251a999bff590d8afada6c3fb967253bbb4fb6db6c0e9")
    static func evidence(metadata: Data?, binding: Data?, smoke: Data?) -> RemindersUpgradeEvidence {
        .init(metadataSHA256: metadata.map(RemindersNativeIO.hash), bindingSHA256: binding.map(RemindersNativeIO.hash), smokeSHA256: smoke.map(RemindersNativeIO.hash))
    }
    static func assess(metadata: Data?, binding: Data?, smoke: Data?, saveAttemptSeen: Bool,
                       runID: String, currentPolicy: String) throws -> RemindersUpgradeAssessment {
        guard currentPolicy == targetPolicy else { throw RemindersTransportFault("upgrade_policy_unreviewed") }
        let proof = evidence(metadata: metadata, binding: binding, smoke: smoke)
        let unknown = RemindersUpgradeAssessment(disposition: .unknown, source: nil, evidence: proof)
        if let smoke {
            guard let old = try? JSONDecoder().decode(RemindersSmokeRecord.self, from: smoke),
                  old.run_id == runID, old.policy_sha256 == oldPolicy,
                  old.state == "saved_local", old.list_id?.isEmpty == false, old.reminder_id?.isEmpty == false,
                  old.source_sha256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { return unknown }
            // Historical completion evidence consumes the full two-save ceiling.
            // It does not assert current EventKit contents or cloud synchronization.
            return .init(disposition: .completed, source: nil, evidence: proof)
        }
        guard !saveAttemptSeen, let metadata,
              let old = try? JSONDecoder().decode(RemindersFrozenSourceMetadata.self, from: metadata),
              old.identity == oldIdentity, old.policy_sha256 == oldPolicy,
              [0, 1, 2, 3].contains(old.source.type) else { return unknown }
        if let binding {
            guard let prior = try? JSONDecoder().decode(RemindersSourceBinding.self, from: binding),
                  prior.identity == oldIdentity, prior.policy_sha256 == oldPolicy, prior.source == old.source else { return unknown }
        }
        return .init(disposition: .sourceOnly, source: old.source, evidence: proof)
    }
    // Only immutable local records use this comparison. Live peer, helper and
    // executable/closure verification must keep their exact current code pins.
    static func storedSubjectMatches(_ stored: RemindersFirstIdentity, current: RemindersFirstIdentity) -> Bool {
        let hashes = [stored.executable_sha256, current.executable_sha256,
                      stored.designated_requirement_sha256, current.designated_requirement_sha256]
        return stored.helper_bundle_id == "local.arl.remindersbridge" &&
            stored.helper_bundle_id == current.helper_bundle_id &&
            stored.designated_requirement_sha256 == current.designated_requirement_sha256 &&
            hashes.allSatisfy { $0.utf8.count == 64 && $0.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil }
    }
    static func validateBinding(_ binding: RemindersSourceBinding, identity: RemindersFirstIdentity,
                                policy: String, nowMS: Int64) throws {
        guard storedSubjectMatches(binding.identity, current: identity), binding.policy_sha256 == policy else {
            throw RemindersTransportFault("target_changed")
        }
        guard binding.expires_at_ms > nowMS else { throw RemindersTransportFault("source_expired") }
    }
    static func validate(_ receipt: RemindersUpgradeReceipt, identity: RemindersFirstIdentity,
                         policy: String, runID: String, evidence: RemindersUpgradeEvidence) throws {
        guard receipt.schema == 1, storedSubjectMatches(receipt.identity, current: identity), receipt.policySHA256 == policy,
              policy == targetPolicy, receipt.runID == runID, receipt.evidence == evidence,
              (receipt.disposition == .sourceOnly) == (receipt.source != nil)
        else { throw RemindersTransportFault("upgrade_review_changed") }
    }
}

/// Local evidence only. This review never opens EventKit; selecting the
/// reviewed source remains a separate foreground action with its own check.
struct RemindersUpgradeStore {
    let home: String
    let identity: RemindersFirstIdentity
    let policy: String
    let runID: String
    var receiptPath: String { home + "/upgrade-review-v1.json" }
    var sourcePath: String { home + "/upgrade-source-v1.json" }
    var smokePath: String { home + "/upgrade-smoke-v1.json" }
    func optional(_ name: String) throws -> Data? {
        let path = home + "/" + name
        var info = stat()
        if lstat(path, &info) != 0 {
            guard errno == ENOENT else { throw RemindersTransportFault("upgrade_evidence_unreadable") }
            return nil
        }
        return try RemindersNativeIO.privateFile(path)
    }
    func evidence() throws -> (metadata: Data?, binding: Data?, smoke: Data?) {
        (try optional("source-metadata.json"), try optional("source.json"), try optional("smoke.json"))
    }
    func proof() throws -> RemindersUpgradeEvidence {
        let raw = try evidence()
        return RemindersUpgradeReview.evidence(metadata: raw.metadata, binding: raw.binding, smoke: raw.smoke)
    }
    func receipt() throws -> RemindersUpgradeReceipt? {
        guard let raw = try optional("upgrade-review-v1.json") else { return nil }
        guard let value = try? JSONDecoder().decode(RemindersUpgradeReceipt.self, from: raw) else {
            throw RemindersTransportFault("upgrade_review_changed")
        }
        try RemindersUpgradeReview.validate(value, identity: identity, policy: policy, runID: runID, evidence: proof())
        if value.disposition != .unknown {
            let raw = try evidence()
            let derived = try RemindersUpgradeReview.assess(metadata: raw.metadata, binding: raw.binding, smoke: raw.smoke,
                saveAttemptSeen: false, runID: runID, currentPolicy: policy)
            guard derived.disposition == value.disposition, derived.source == value.source else {
                throw RemindersTransportFault("upgrade_review_changed")
            }
        }
        return value
    }
    func priorSaveAttempt() throws -> Bool {
        let journal = home + "/operation-journal"
        var info = stat()
        if lstat(journal, &info) == 0 {
            try RemindersNativeIO.privateDirectory(journal)
            if !(try FileManager.default.contentsOfDirectory(atPath: journal)).isEmpty { return true }
        } else if errno != ENOENT { throw RemindersTransportFault("upgrade_evidence_unreadable") }
        let admissions = home + "/admissions"
        if lstat(admissions, &info) != 0 {
            guard errno == ENOENT else { throw RemindersTransportFault("upgrade_evidence_unreadable") }
            return false
        }
        try RemindersNativeIO.privateDirectory(admissions)
        let names = try FileManager.default.contentsOfDirectory(atPath: admissions)
        guard names.count <= 512 else { throw RemindersTransportFault("admission_capacity") }
        for name in names {
            guard name.hasSuffix(".json"), UUID(uuidString: String(name.dropLast(5))) != nil,
                  let data = try optional("admissions/" + name),
                  let record = try? JSONDecoder().decode(RemindersNativeAdmissionRecord.self, from: data) else { return true }
            if record.action == RemindersFirstAction.run_smoke.rawValue { return true }
        }
        return false
    }
    func needsReview() throws -> Bool {
        if try receipt() != nil { return false }
        let raw = try evidence()
        if let bytes = raw.metadata {
            guard let value = try? JSONDecoder().decode(RemindersFrozenSourceMetadata.self, from: bytes),
                  RemindersUpgradeReview.storedSubjectMatches(value.identity, current: identity), value.policy_sha256 == policy else { return true }
        }
        if let bytes = raw.binding {
            guard let value = try? JSONDecoder().decode(RemindersSourceBinding.self, from: bytes),
                  RemindersUpgradeReview.storedSubjectMatches(value.identity, current: identity), value.policy_sha256 == policy else { return true }
        }
        if let bytes = raw.smoke {
            guard let value = try? JSONDecoder().decode(RemindersSmokeRecord.self, from: bytes),
                  value.run_id == runID, value.policy_sha256 == policy else { return true }
        }
        if raw.metadata == nil, try optional("source-metadata-admitted") != nil { return true }
        return try raw.metadata == nil && raw.smoke == nil && priorSaveAttempt()
    }
    func assessment() throws -> RemindersUpgradeAssessment {
        let raw = try evidence()
        return try RemindersUpgradeReview.assess(metadata: raw.metadata, binding: raw.binding, smoke: raw.smoke,
            saveAttemptSeen: priorSaveAttempt(), runID: runID, currentPolicy: policy)
    }
    @MainActor func review(confirm: (RemindersUpgradeAssessment) async -> Bool,
                           stopped: () -> Bool) async throws -> RemindersUpgradeReceipt {
        if let existing = try receipt() { return existing }
        guard try needsReview() else { throw RemindersTransportFault("upgrade_not_required") }
        let candidate = try assessment()
        guard !stopped(), await confirm(candidate), !stopped() else { throw RemindersTransportFault("cancelled") }
        // Recheck the exact old evidence and admission ceiling after user input.
        let checked = try assessment()
        guard checked.evidence == candidate.evidence, checked.disposition == candidate.disposition,
              checked.source == candidate.source else { throw RemindersTransportFault("upgrade_review_changed") }
        guard !stopped(), try proof() == candidate.evidence else { throw RemindersTransportFault("upgrade_review_changed") }
        let value = RemindersUpgradeReceipt(schema: 1, identity: identity, policySHA256: policy, runID: runID,
            disposition: candidate.disposition, source: candidate.source, evidence: candidate.evidence)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try RemindersNativeIO.writeNew(try encoder.encode(value), to: receiptPath)
        return value
    }
}
