import Foundation
import CryptoKit

struct NotesCallerGrant {
    let targets: Set<String>
    let nativeReview: Bool
    let workflowIssuers: Set<String>
    let maxAttempts: Int
}
struct NotesPolicy {
    let epoch: Int64
    let callers: [String: NotesCallerGrant]
    let targets: [String: NotesFolderBinding]
    let issuerPublicKeys: [String: Data]
}
struct NotesWorkflowPermit { let issuer: String; let payload: Data; let signature: Data }
// Live, host-owned review signals; neither Codable nor supplied by an RPC.
// A concrete modal reviewer MUST poll these in its modal run-loop mode and
// dismiss on expiry/cancel. A synchronous arbitrary callback is not preemptible.
struct NotesReviewContext {
    let deadline: Double // absolute monotonic deadline, not a fresh 20s timer
    let expiresAtMS: Int64
    let clock: NotesClock
    let cancellationRequested: () -> Bool
    var remainingSeconds: Double {
        max(0, min(deadline - clock.monotonic(), Double(expiresAtMS - clock.nowMS()) / 1000))
    }
    var shouldDismiss: Bool { cancellationRequested() || remainingSeconds <= 0 }
}
protocol NotesEffects {
    func permission() -> String
    func lockState() -> String
    func resolve(_ binding: NotesFolderBinding, deadline: Double) throws -> NotesTargetMetadata
    func create(_ proposal: NotesCreateProposal, binding: NotesFolderBinding, deadline: Double) throws -> String
}
@MainActor protocol NotesReviewer {
    // Full exact title/text and registered target are displayed. Returning true
    // is only a trusted in-process UI callback, never an RPC approved flag.
    // Check context before display, during the modal loop (including modal
    // panel mode) and immediately before returning confirmation. Never block
    // indefinitely or restart the timeout after metadata/display preparation.
    func confirm(_ proposal: NotesCreateProposal, target: NotesTargetMetadata, context: NotesReviewContext) -> Bool
}

// Trusted host serializes admission/policy handling on the main actor. No
// public stdin/RPC executable or caller-supplied policy/issuer exists here.
@MainActor final class NotesApprovalEngine {
    private let journal: ConsumptionJournal
    private let policy: () -> NotesPolicy?
    private let clock: NotesClock
    init(journal: ConsumptionJournal, policy: @escaping () -> NotesPolicy? = { nil }, clock: NotesClock = .system) {
        self.journal = journal; self.policy = policy; self.clock = clock
    }
    private func authorized(_ p: NotesCreateProposal, caller: AuthenticatedCaller, epoch: Int64? = nil) throws -> (NotesPolicy, NotesCallerGrant, NotesFolderBinding) {
        guard caller.isCurrent(), caller.subject == p.callerID else { throw ReviewFault("caller_unverified") }
        guard let policy = policy(), policy.epoch > 0, epoch == nil || epoch == policy.epoch,
              let grant = policy.callers[caller.subject], grant.targets.contains(p.targetAlias),
              (1...16).contains(grant.maxAttempts), let binding = policy.targets[p.targetAlias], binding.alias == p.targetAlias else { throw ReviewFault("capability_not_granted") }
        try binding.validate()
        return (policy, grant, binding)
    }
    private func ready(_ effects: NotesEffects) throws {
        guard effects.permission() == "authorized" else { throw ReviewFault("needs_permission") }
        let lock = effects.lockState()
        guard lock == "unlocked" else { throw ReviewFault(lock == "locked" ? "needs_unlock" : "lock_state_unknown") }
    }
    private func current(_ p: NotesCreateProposal, expiry: Int64, deadline: Double, cancelled: () -> Bool) throws {
        guard !cancelled() else { throw ReviewFault("cancelled_before_effect") }
        guard p.issuedAtMS <= clock.nowMS() + 5000, clock.nowMS() < expiry, clock.nowMS() < p.expiresAtMS,
              clock.monotonic() < deadline else { throw ReviewFault("approval_expired") }
    }
    private func resolve(_ b: NotesFolderBinding, effects: NotesEffects, deadline: Double) throws -> NotesTargetMetadata {
        let m = try effects.resolve(b, deadline: deadline)
        guard m.accountID == b.accountID, m.folderID == b.folderID, m.name == b.expectedName, !m.shared else { throw ReviewFault("target_changed") }
        return m
    }
    func performNative(_ raw: Data, caller: AuthenticatedCaller, reviewer: NotesReviewer, effects: NotesEffects, cancelled: @escaping () -> Bool = { false }) throws -> [String: Any] {
        let p = try NotesCreateProposal(raw)
        let (initial, grant, binding) = try authorized(p, caller: caller)
        guard grant.nativeReview else { throw ReviewFault("native_review_not_granted") }
        let deadline = clock.monotonic() + min(20, max(0, Double(p.expiresAtMS - clock.nowMS()) / 1000))
        try current(p, expiry: p.expiresAtMS, deadline: deadline, cancelled: cancelled)
        try ready(effects)
        try journal.consume(operationID: p.operationID, permitID: UUID().uuidString.lowercased(), subject: caller.subject, epoch: initial.epoch, budget: grant.maxAttempts)
        let target = try resolve(binding, effects: effects, deadline: deadline)
        // Metadata may have canceled/expired the request. Do not show a dialog
        // for a request which is already invalid, even if the reviewer is slow.
        try current(p, expiry: p.expiresAtMS, deadline: deadline, cancelled: cancelled)
        let context = NotesReviewContext(deadline: deadline, expiresAtMS: p.expiresAtMS, clock: clock, cancellationRequested: cancelled)
        let confirmed = reviewer.confirm(p, target: target, context: context)
        // Preserve cancel/expiry classification rather than treating an
        // automatically dismissed review as a manual decline.
        try current(p, expiry: p.expiresAtMS, deadline: deadline, cancelled: cancelled)
        guard confirmed else { throw ReviewFault("user_cancelled") }
        return try commit(p, caller: caller, binding: binding, epoch: initial.epoch, maxAttempts: grant.maxAttempts, expiry: p.expiresAtMS, deadline: deadline, issuer: nil, effects: effects, cancelled: cancelled)
    }
    // Reserved for a separately configured, genuinely trusted workflow issuer.
    // No issuer/key is shipped and no claim of platform chat receipts is made.
    func performWorkflow(_ raw: Data, permit: NotesWorkflowPermit, caller: AuthenticatedCaller, effects: NotesEffects, cancelled: () -> Bool = { false }) throws -> [String: Any] {
        let p = try NotesCreateProposal(raw)
        let (initial, grant, binding) = try authorized(p, caller: caller)
        guard grant.workflowIssuers.contains(permit.issuer), let keyBytes = initial.issuerPublicKeys[permit.issuer],
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyBytes), permit.signature.count == 64,
              permit.payload.count <= 4096, key.isValidSignature(permit.signature, for: permit.payload) else { throw ReviewFault("permit_unverified") }
        let v = try flatObject(permit.payload, limit: 4096)
        guard Set(v.keys) == Set(["schema_version", "issuer_id", "permit_id", "caller_id", "operation_id", "tool", "request_sha256", "target_binding_sha256", "policy_epoch", "issued_at_ms", "expires_at_ms", "max_effects"]),
              integer(v["schema_version"]) == 1, v["issuer_id"] as? String == permit.issuer,
              let permitID = v["permit_id"] as? String, uuid(permitID), v["caller_id"] as? String == p.callerID,
              v["operation_id"] as? String == p.operationID, v["tool"] as? String == NotesCreateProposal.tool,
              v["request_sha256"] as? String == p.rawHash, v["target_binding_sha256"] as? String == binding.hash,
              integer(v["policy_epoch"]) == initial.epoch, integer(v["max_effects"]) == 1,
              integer(v["issued_at_ms"]) == p.issuedAtMS, let expiry = integer(v["expires_at_ms"]), expiry == p.expiresAtMS else { throw ReviewFault("permit_binding_mismatch") }
        let deadline = clock.monotonic() + min(20, max(0, Double(expiry - clock.nowMS()) / 1000))
        try current(p, expiry: expiry, deadline: deadline, cancelled: cancelled)
        try ready(effects)
        try journal.consume(operationID: p.operationID, permitID: permitID, subject: caller.subject, epoch: initial.epoch, budget: grant.maxAttempts)
        return try commit(p, caller: caller, binding: binding, epoch: initial.epoch, maxAttempts: grant.maxAttempts, expiry: expiry, deadline: deadline, issuer: (permit.issuer, keyBytes), effects: effects, cancelled: cancelled)
    }
    private func commit(_ p: NotesCreateProposal, caller: AuthenticatedCaller, binding: NotesFolderBinding, epoch: Int64, maxAttempts: Int, expiry: Int64, deadline: Double, issuer: (String, Data)?, effects: NotesEffects, cancelled: () -> Bool) throws -> [String: Any] {
        _ = try resolve(binding, effects: effects, deadline: deadline)
        try ready(effects)
        // All potentially external metadata/readiness callbacks precede the
        // final caller/policy/target/deadline check. No UI/read callback follows.
        let (admitted, grant, lastBinding) = try authorized(p, caller: caller, epoch: epoch)
        guard lastBinding.hash == binding.hash else { throw ReviewFault("target_changed") }
        guard grant.maxAttempts == maxAttempts else { throw ReviewFault("capability_not_granted") }
        if let (id, key) = issuer {
            guard grant.workflowIssuers.contains(id), admitted.issuerPublicKeys[id] == key else { throw ReviewFault("permit_unverified") }
        } else { guard grant.nativeReview else { throw ReviewFault("native_review_not_granted") } }
        try current(p, expiry: expiry, deadline: deadline, cancelled: cancelled)
        // One synchronous, non-preemptible make event. Late cancellation is
        // not a guarantee of stop/undo. Failed/lost replies stay consumed.
        let result: String
        do { result = try effects.create(p, binding: binding, deadline: deadline) }
        catch { throw ReviewFault("outcome_unknown") }
        guard result == "created_local" else { throw ReviewFault("outcome_unknown") }
        return ["schema_version": 1, "operation_id": p.operationID, "request_sha256": p.rawHash,
                "target_binding_sha256": binding.hash, "persistence": "created_local", "cloud_sync": "not_checked"]
    }
}
