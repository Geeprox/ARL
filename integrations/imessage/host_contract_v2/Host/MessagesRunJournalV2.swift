import Foundation
import Darwin

/// One native authority record replaces v1 ceiling.json + scope.json in a NEW candidate.
/// The source adapter's existing separate journal still owns its controller/cursor/cleanup proof.
@MainActor final class MessagesRunJournalV2 {
    static let cleanupRequestLimit = 64 // Never evict authority history within a run.
    struct CleanupRequest: Codable {
        let fingerprint: String
        let command: String
        let operation: MessagesCleanupOperationV2
    }
    struct CleanupAdmission {
        let operation: MessagesCleanupOperationV2
        let replay: Bool
    }
    struct Record: Codable {
        let schema_version: Int
        let run_id, policy_sha256: String
        let started_at, deadline: Double
        var last_clock: Double
        var host_generation, revision: Int
        var expired, boot_active: Bool
        var scope: MessagesNativeScopeV2?
        var cleanup_epoch: Int
        var cleanup_state: String
        var cleanup_session: String?
        var cleanup_generation: Int
        var cleanup_operation: MessagesCleanupOperationV2?
        var cleanup_requests: [String: CleanupRequest]
    }
    private(set) var record: Record
    private(set) var healthy = true
    private let path: String
    private let now: @MainActor () -> Double
    private let persist: @MainActor (Data, String, Bool) throws -> Void

    init(root: String, runID: String, policyHash: String, notAfter: Double, now: @escaping @MainActor () -> Double = { Date().timeIntervalSince1970 },
         persist: @escaping @MainActor (Data, String, Bool) throws -> Void = { data, path, fresh in
             if fresh { try MessagesNativeIO.writeNew(data, to: path) }
             else { try MessagesNativeIO.atomicWrite(data, to: path) }
         }) throws {
        try MessagesNativeIO.privateDirectory(root)
        guard MessagesV2Fields.canonicalUUID(runID), MessagesV2Fields.matches(policyHash, "^[a-f0-9]{64}$") else { throw MessagesTransportFault("identity_changed") }
        path = root + "/run-v2.json"; self.now = now; self.persist = persist
        let names = try FileManager.default.contentsOfDirectory(atPath: root)
        guard !names.contains(where: { $0.hasPrefix("run-v2.json.new-") }) else { throw MessagesTransportFault("storage_uncertain") }
        let clock = now()
        guard clock.isFinite, clock >= 0, notAfter.isFinite, notAfter > 0 else { throw MessagesTransportFault("clock_rollback") }
        if names.contains("run-v2.json") {
            let bytes = try MessagesNativeIO.privateFile(path)
            let json = try MessagesJSON.decode(bytes).value
            // Format 2 cannot prove historical idempotency. Preserve it and refuse it, never reset/migrate.
            guard Set(json.keys) == ["schema_version", "run_id", "policy_sha256", "started_at", "deadline", "last_clock", "host_generation", "revision", "expired", "boot_active", "scope", "cleanup_epoch", "cleanup_state", "cleanup_session", "cleanup_generation", "cleanup_operation", "cleanup_requests"] else { throw MessagesTransportFault("storage_uncertain") }
            record = try JSONDecoder().decode(Record.self, from: bytes)
            try validate(record)
            guard record.run_id == runID, record.policy_sha256 == policyHash, record.deadline <= notAfter else { throw MessagesTransportFault("identity_changed") }
            guard clock >= record.last_clock else { throw MessagesTransportFault("clock_rollback") }
            record.host_generation += 1
            if record.boot_active || record.scope?.revoked == false || ["pending", "in_progress"].contains(record.cleanup_state) {
                record.scope?.revoked = true; record.cleanup_epoch += 1; record.cleanup_state = "unknown"
                record.cleanup_operation = Self.operation(record, session: record.cleanup_session, generation: record.cleanup_generation)
            }
            record.boot_active = true
            record.last_clock = clock; record.expired = record.expired || clock >= record.deadline
            if record.expired { record.scope?.revoked = true }
            record.revision += 1
            try commit(record)
        } else {
            // Never regenerate a deadline/budget from an existing v1 or partial controller state.
            guard clock < notAfter, Set(names).isSubset(of: ["host.lock", "control.sock"]) else { throw MessagesTransportFault("storage_uncertain") }
            record = Record(schema_version: 3, run_id: runID, policy_sha256: policyHash,
                started_at: clock, deadline: min(clock + 900, notAfter), last_clock: clock, host_generation: 1, revision: 1,
                expired: false, boot_active: true, scope: nil, cleanup_epoch: 0, cleanup_state: "not_required",
                cleanup_session: nil, cleanup_generation: 0, cleanup_operation: nil, cleanup_requests: [:])
            try validate(record)
            do { try persist(Self.bytes(record), path, true) } catch { healthy = false; throw MessagesTransportFault("storage_uncertain") }
        }
    }
    private func validate(_ r: Record) throws {
        guard r.schema_version == 3, MessagesV2Fields.canonicalUUID(r.run_id),
              MessagesV2Fields.matches(r.policy_sha256, "^[a-f0-9]{64}$"),
              r.started_at.isFinite, r.started_at >= 0, r.deadline.isFinite, r.deadline > r.started_at && r.deadline <= r.started_at + 900,
              r.last_clock.isFinite, r.last_clock >= r.started_at, r.host_generation > 0, r.host_generation < 1_000_000,
              r.revision > 0, r.revision < 1_000_000, r.cleanup_epoch >= 0, r.cleanup_epoch < 1_000_000,
              ["not_required", "pending", "in_progress", "completed", "unknown"].contains(r.cleanup_state),
              r.cleanup_session.map(MessagesV2Fields.canonicalUUID) ?? (r.cleanup_generation == 0),
              r.cleanup_session == nil || r.cleanup_generation > 0,
              r.cleanup_requests.count <= Self.cleanupRequestLimit else { throw MessagesTransportFault("storage_uncertain") }
        func valid(_ op: MessagesCleanupOperationV2) -> Bool {
            MessagesV2Fields.canonicalUUID(op.operation_id) && op.epoch > 0 && op.epoch <= r.cleanup_epoch
                && op.host_generation > 0 && op.host_generation <= r.host_generation
                && (op.session_id.map(MessagesV2Fields.canonicalUUID) ?? (op.generation == 0))
                && (op.session_id == nil || op.generation > 0)
                && (op.lease_id.map { $0.hasPrefix("lease_") && $0.utf8.count <= 128 } ?? true)
        }
        if let op = r.cleanup_operation {
            guard valid(op), op.epoch == r.cleanup_epoch, op.session_id == r.cleanup_session,
                  op.generation == r.cleanup_generation else { throw MessagesTransportFault("storage_uncertain") }
        } else if !["not_required", "pending"].contains(r.cleanup_state) { throw MessagesTransportFault("storage_uncertain") }
        guard Set(r.cleanup_requests.values.map { $0.operation.operation_id }).count == r.cleanup_requests.count,
              Set(r.cleanup_requests.values.map { $0.operation.epoch }).count == r.cleanup_requests.count else { throw MessagesTransportFault("storage_uncertain") }
        for (id, item) in r.cleanup_requests {
            guard MessagesV2Fields.canonicalUUID(id), ["cancel", "disable"].contains(item.command),
                  MessagesV2Fields.matches(item.fingerprint, "^[a-f0-9]{64}$"),
                  item.fingerprint == (try Self.fingerprint(requestID: id, command: item.command)), valid(item.operation) else { throw MessagesTransportFault("storage_uncertain") }
        }
        if let s = r.scope {
            guard s.lease_id.hasPrefix("lease_"), MessagesV2Fields.canonicalUUID(s.session_id), s.generation > 0,
                  MessagesV2Fields.canonicalUUID(s.operation_id), MessagesV2Fields.matches(s.scope_id, "^ims_[a-f0-9]{32}$"),
                  [s.candidate_pin, s.plan_hash, s.send_text_sha256].allSatisfy({ MessagesV2Fields.matches($0, "^[a-f0-9]{64}$") }),
                  s.owner == "messages:" + r.run_id, !s.group_id.isEmpty, s.group_id.utf8.count <= 256,
                  s.expires_at.isFinite, s.expires_at <= r.deadline, s.expires_at > r.started_at,
                  ["not_started", "outcome_unknown", "accepted"].contains(s.send_outcome),
                  s.consumed == (s.send_outcome != "not_started") else { throw MessagesTransportFault("storage_uncertain") }
        }
    }
    private static func bytes(_ record: Record) throws -> Data {
        var value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as! [String: Any]
        value["scope"] = value["scope"] ?? NSNull()
        value["cleanup_session"] = record.cleanup_session ?? (NSNull() as Any)
        value["cleanup_operation"] = value["cleanup_operation"] ?? NSNull()
        let data = try MessagesJSON(value).data
        guard data.count <= 65536 else { throw MessagesTransportFault("storage_uncertain") }
        return data
    }
    private func commit(_ next: Record) throws {
        guard healthy else { throw MessagesTransportFault("storage_uncertain") }
        try validate(next)
        do { try persist(Self.bytes(next), path, false); record = next }
        catch { healthy = false; throw MessagesTransportFault("storage_uncertain") }
    }
    /// Native status advances only its own durable clock high-water, never an OS grant/effect.
    /// Sticky expiry and persisted high-water prevent rollback/restart from extending this run.
    func observe() throws {
        guard healthy else { throw MessagesTransportFault("storage_uncertain") }
        let clock = now()
        guard clock.isFinite, clock >= record.last_clock else { throw MessagesTransportFault("clock_rollback") }
        if clock > record.last_clock || (!record.expired && clock >= record.deadline) {
            var next = record; next.last_clock = clock
            next.expired = next.expired || clock >= next.deadline
            if next.expired { next.scope?.revoked = true }
            next.revision += 1; try commit(next)
        }
    }
    func requireActive() throws {
        try observe()
        guard !record.expired else { throw MessagesTransportFault("verification_expired") }
        // Exhaustion is represented by the durable count, so restart cannot restore effect authority.
        guard record.cleanup_requests.count < Self.cleanupRequestLimit else { throw MessagesTransportFault("storage_uncertain") }
    }
    func setScope(_ scope: MessagesNativeScopeV2) throws {
        try requireActive()
        if let old = record.scope {
            guard !(old.revoked && !scope.revoked && old.lease_id == scope.lease_id) else { throw MessagesTransportFault("activation_not_approved") }
            guard old.candidate_pin == scope.candidate_pin, old.group_id == scope.group_id, old.scope_id == scope.scope_id else { throw MessagesTransportFault("group_changed") }
        }
        if record.scope?.consumed == true {
            guard scope.operation_id == record.scope?.operation_id, scope.lease_id == record.scope?.lease_id,
                  scope.session_id == record.scope?.session_id, scope.generation == record.scope?.generation,
                  scope.plan_hash == record.scope?.plan_hash, scope.send_text_sha256 == record.scope?.send_text_sha256,
                  scope.expires_at == record.scope?.expires_at, scope.consumed else { throw MessagesTransportFault("attempt_consumed") }
            guard !(record.scope?.send_outcome == "accepted" && scope.send_outcome != "accepted") else { throw MessagesTransportFault("send_unknown") }
        }
        var next = record
        if scope.lease_id != next.scope?.lease_id {
            guard ["completed", "not_required"].contains(next.cleanup_state),
                  next.scope == nil || next.scope?.revoked == true else { throw MessagesTransportFault("cleanup_unknown") }
            next.cleanup_epoch += 1; next.cleanup_state = "pending"
            next.cleanup_session = scope.session_id; next.cleanup_generation = scope.generation
            next.cleanup_operation = nil
        }
        next.scope = scope; next.revision += 1; try commit(next)
    }
    func consume(operationID: String, textHash: String) throws {
        try requireActive()
        guard var scope = record.scope, !scope.revoked, !scope.consumed, scope.expires_at > now(),
              scope.operation_id == operationID, scope.send_text_sha256 == textHash else { throw MessagesTransportFault("attempt_consumed") }
        scope.consumed = true; scope.send_outcome = "outcome_unknown"
        try setScope(scope) // fsync tombstone before acknowledging permission to dispatch
    }
    func outcome(operationID: String, state: String) throws {
        guard healthy, var scope = record.scope, scope.consumed, scope.operation_id == operationID,
              ["accepted", "outcome_unknown"].contains(state) else { throw MessagesTransportFault("send_unknown") }
        if scope.send_outcome == "accepted" && state == "outcome_unknown" { return } // late uncertainty cannot undo accepted evidence
        scope.send_outcome = state
        var next = record; next.scope = scope; next.revision += 1; try commit(next)
    }
    static func fingerprint(requestID: String, command: String) throws -> String {
        guard MessagesV2Fields.canonicalUUID(requestID), ["cancel", "disable"].contains(command) else { throw MessagesTransportFault("invalid_request") }
        // The finite public decoder guarantees these commands have no arguments.
        return MessagesNativeIO.hash(try MessagesJSON(["schema_version": 2, "request_id": requestID, "command": command, "arguments": [:]]).data)
    }
    func cleanupReplay(requestID: String, command: String) throws -> MessagesCleanupOperationV2? {
        guard healthy else { throw MessagesTransportFault("storage_uncertain") }
        let fingerprint = try Self.fingerprint(requestID: requestID, command: command)
        guard let previous = record.cleanup_requests[requestID] else { return nil }
        guard previous.fingerprint == fingerprint, previous.command == command else { throw MessagesTransportFault("invalid_request") }
        return previous.operation // No clock/epoch/binding mutation and no redispatch.
    }
    private static func operation(_ r: Record, session: String?, generation: Int) -> MessagesCleanupOperationV2 {
        let lease = r.scope.flatMap { $0.session_id == session && $0.generation == generation ? $0.lease_id : nil }
        return .init(operation_id: UUID().uuidString.lowercased(), epoch: r.cleanup_epoch, host_generation: r.host_generation,
                     session_id: session, generation: generation, lease_id: lease)
    }
    @discardableResult func beginCleanup(requestID: String, command: String = "cancel", session: String? = nil, generation: Int? = nil) throws -> CleanupAdmission {
        if let previous = try cleanupReplay(requestID: requestID, command: command) { return .init(operation: previous, replay: true) }
        try observe()
        guard record.cleanup_requests.count < Self.cleanupRequestLimit else { healthy = false; throw MessagesTransportFault("storage_uncertain") }
        if let scope = record.scope, !scope.revoked {
            guard (session ?? scope.session_id) == scope.session_id, (generation ?? scope.generation) == scope.generation else { throw MessagesTransportFault("cleanup_unknown") }
        }
        var next = record; next.cleanup_epoch += 1; next.cleanup_state = "in_progress"
        next.scope?.revoked = true
        next.cleanup_session = generation == nil ? (session ?? next.scope?.session_id) : session
        next.cleanup_generation = generation ?? next.scope?.generation ?? 0
        let op = Self.operation(next, session: next.cleanup_session, generation: next.cleanup_generation)
        next.cleanup_operation = op
        next.cleanup_requests[requestID] = .init(fingerprint: try Self.fingerprint(requestID: requestID, command: command), command: command, operation: op)
        next.revision += 1; try commit(next)
        return .init(operation: op, replay: false)
    }
    func revoke(session: String?, generation: Int) throws {
        guard healthy else { throw MessagesTransportFault("storage_uncertain") }
        if let s = record.scope, !s.revoked {
            guard session == s.session_id, generation == s.generation else { throw MessagesTransportFault("cleanup_unknown") }
        }
        if let op = record.cleanup_operation, ["in_progress", "unknown"].contains(record.cleanup_state) {
            guard op.session_id == session, op.generation == generation else { throw MessagesTransportFault("cleanup_unknown") }
            return // Never rebind an in-flight transaction from a backend callback.
        }
        var next = record; next.scope?.revoked = true; next.cleanup_epoch += 1
        next.cleanup_state = "in_progress"; next.cleanup_session = session; next.cleanup_generation = generation
        next.cleanup_operation = Self.operation(next, session: session, generation: generation)
        next.revision += 1; try commit(next)
    }
    func beginSystemCleanup(session: String?, generation: Int) throws -> MessagesCleanupOperationV2 {
        try observe()
        if let scope = record.scope, !scope.revoked {
            guard scope.session_id == session, scope.generation == generation else { throw MessagesTransportFault("cleanup_unknown") }
        }
        var next = record; next.scope?.revoked = true; next.cleanup_epoch += 1
        next.cleanup_state = "in_progress"; next.cleanup_session = session; next.cleanup_generation = generation
        let op = Self.operation(next, session: session, generation: generation); next.cleanup_operation = op
        next.revision += 1; try commit(next); return op
    }
    /// Core status is presentation data. Neither old nor current snapshots establish stop completion.
    func reconcile(_ core: [String: Any], permissionPending: Bool) throws {
        guard healthy else { throw MessagesTransportFault("storage_uncertain") }
    }
    func isCurrent(_ op: MessagesCleanupOperationV2) -> Bool {
        healthy && record.cleanup_operation == op && record.cleanup_epoch == op.epoch && record.host_generation == op.host_generation
    }
    /// `proof` comes only from the correlated owned-pipe lifecycle_stop reply for the captured op.
    @discardableResult func completeCleanup(_ op: MessagesCleanupOperationV2, proof: [String: Any], permissionPending: Bool) throws -> Bool {
        guard healthy else { throw MessagesTransportFault("storage_uncertain") }
        guard isCurrent(op), ["in_progress", "unknown"].contains(record.cleanup_state), !permissionPending,
              record.scope?.revoked != false,
              op.lease_id == nil || op.lease_id == record.scope?.lease_id,
              Set(proof.keys) == ["session_id", "generation", "local_grant_revoked", "receiver_stopped", "publisher_stopped", "children_stopped", "private_content_cleanup"],
              proof["session_id"] as? String == op.session_id, MessagesNativeIO.integer(proof["generation"]) == op.generation,
              ["local_grant_revoked", "receiver_stopped", "publisher_stopped", "children_stopped"].allSatisfy({ MessagesV2Fields.trueBoolean(proof[$0]) }),
              proof["private_content_cleanup"] as? String == "completed" else { return false }
        var next = record; next.cleanup_state = "completed"; next.revision += 1
        try commit(next)
        return true
    }
    func failCleanup(_ op: MessagesCleanupOperationV2) throws {
        guard healthy else { throw MessagesTransportFault("storage_uncertain") }
        guard isCurrent(op), record.cleanup_state != "completed", record.cleanup_state != "unknown" else { return }
        var next = record; next.cleanup_state = "unknown"; next.revision += 1; try commit(next)
    }
    func shutdown() throws {
        guard healthy else { throw MessagesTransportFault("storage_uncertain") }
        var next = record; next.scope?.revoked = true; next.boot_active = false
        // Shutdown never upgrades cleanup. Its caller must first commit exact operation proof + reap.
        if !["completed", "not_required"].contains(next.cleanup_state) {
            next.cleanup_state = "unknown"
            if next.cleanup_operation == nil {
                next.cleanup_epoch += 1
                next.cleanup_operation = Self.operation(next, session: next.cleanup_session, generation: next.cleanup_generation)
            }
        }
        next.revision += 1; try commit(next)
    }
    func evidence(backendReady: Bool) throws -> MessagesNativeAuthorityV2 {
        try observe()
        let scope = record.scope
        let leaseState = scope == nil ? "inactive" : record.expired || (scope!.expires_at <= now()) ? "expired" : scope!.revoked ? "revoked" : "active"
        return MessagesNativeAuthorityV2(schema_version: 2, run_id: record.run_id, policy_sha256: record.policy_sha256,
            host_generation: record.host_generation, revision: record.revision, started_at: record.started_at,
            deadline: record.deadline, observed_at: record.last_clock, expired: record.expired, backend_ready: backendReady,
            send: .init(limit: 1, consumed: scope?.consumed ?? false,
                outcome: scope?.consumed == true ? scope!.send_outcome == "accepted" ? "accepted" : "consumed_unknown" : "unused", operation_id: scope?.operation_id),
            lease: .init(state: leaseState, session_id: scope?.session_id, generation: scope?.generation ?? 0, scope_id: scope?.scope_id),
            cleanup: .init(epoch: record.cleanup_epoch, state: record.cleanup_state, session_id: record.cleanup_session, generation: record.cleanup_generation, operation_id: record.cleanup_operation?.operation_id))
    }
}
