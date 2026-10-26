import Foundation

@MainActor final class CleanupProbeGateV2 {
    var started = false
    var continuation: CheckedContinuation<Void, Never>?
    func pause() async { started = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
@MainActor final class CleanupProbeFailureV2 { var enabled = false }

@main struct CleanupTestsV2 {
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/host-contract-v2/cleanup-probes-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        // Keep private synthetic journals for independent inspection; never reset a journal to cure a failure.
        let runID = "00000000-0000-4000-8000-000000000001", policy = String(repeating: "a", count: 64)
        func uuid(_ number: Int) -> String { "00000000-0000-4000-8000-" + String(format: "%012d", number) }
        var checks: [String] = []
        func check(_ result: Bool, _ name: String) { precondition(result, name); checks.append(name) }
        func directory(_ name: String) throws -> String {
            let path = root.appendingPathComponent(name).path
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]); return path
        }
        func open(_ path: String) throws -> MessagesRunJournalV2 { try .init(root: path, runID: runID, policyHash: policy, notAfter: 1900, now: { 1000 }) }
        func scope(_ generation: Int) -> MessagesNativeScopeV2 {
            .init(lease_id: "lease_" + String(repeating: String(generation), count: 64), session_id: uuid(10 + generation), generation: generation,
                  candidate_pin: String(repeating: "b", count: 64), owner: "messages:" + runID, group_id: "iMessage;+;synthetic-cleanup-probe",
                  scope_id: "ims_" + String(repeating: "c", count: 32), plan_hash: String(repeating: "d", count: 64),
                  operation_id: uuid(30 + generation), send_text_sha256: String(repeating: "e", count: 64), expires_at: 1900,
                  revoked: false, consumed: false, send_outcome: "not_started")
        }
        func proof(_ op: MessagesCleanupOperationV2) -> [String: Any] {
            ["session_id": op.session_id ?? (NSNull() as Any), "generation": op.generation, "local_grant_revoked": true,
             "receiver_stopped": true, "publisher_stopped": true, "children_stopped": true, "private_content_cleanup": "completed"]
        }
        func expect(_ code: String, _ name: String, _ block: () throws -> Void) {
            do { try block(); preconditionFailure(name) } catch { check((error as? MessagesTransportFault)?.code == code, name) }
        }
        let stale = try open(directory("stale-session"))
        try stale.setScope(scope(1))
        expect("cleanup_unknown", "wrong-session-cancel-cannot-revoke-or-rebind-active-lease", {
            _ = try stale.beginCleanup(requestID: uuid(24), session: uuid(12), generation: 2)
        })
        check(stale.record.scope?.revoked == false && stale.record.cleanup_requests.isEmpty, "rejected-scope-mismatch-persists-no-cancel-identity-or-revocation")
        let a = try stale.beginCleanup(requestID: uuid(21)).operation
        let oldSnapshot: [String: Any] = ["cleanup": "completed", "session_id": uuid(11), "generation": 1]
        try stale.reconcile(oldSnapshot, permissionPending: false)
        check(stale.record.cleanup_state == "in_progress", "even-current-completed-snapshot-is-not-actual-stop-proof")
        check(try stale.completeCleanup(a, proof: proof(a), permissionPending: false), "exact-first-stop-proof-completes-captured-operation")
        try stale.setScope(scope(2))
        let b = try stale.beginCleanup(requestID: uuid(22)).operation
        let beforeStale = stale.record.revision
        try stale.reconcile(oldSnapshot, permissionPending: false)
        check(stale.record.cleanup_state == "in_progress" && stale.record.cleanup_session == uuid(12) && stale.record.revision == beforeStale,
              "old-S1-completed-snapshot-cannot-finish-or-rebind-S2-cleanup")
        check(try !stale.completeCleanup(a, proof: proof(a), permissionPending: false), "old-S1-operation-proof-cannot-complete-S2-epoch")
        expect("cleanup_unknown", "new-unused-S3-lease-blocked-after-old-S1-proof", { try stale.setScope(scope(3)) })
        var wrongProof = proof(b); wrongProof["session_id"] = uuid(11)
        check(try !stale.completeCleanup(b, proof: wrongProof, permissionPending: false), "current-operation-with-wrong-scoped-proof-is-rejected")
        let wrongID = MessagesCleanupOperationV2(operation_id: uuid(88), epoch: b.epoch, host_generation: b.host_generation,
                                                 session_id: b.session_id, generation: b.generation, lease_id: b.lease_id)
        check(try !stale.completeCleanup(wrongID, proof: proof(b), permissionPending: false), "same-epoch-wrong-operation-ID-is-rejected")
        let wrongEpoch = MessagesCleanupOperationV2(operation_id: b.operation_id, epoch: b.epoch - 1, host_generation: b.host_generation,
                                                    session_id: b.session_id, generation: b.generation, lease_id: b.lease_id)
        check(try !stale.completeCleanup(wrongEpoch, proof: proof(b), permissionPending: false), "same-operation-ID-wrong-epoch-is-rejected")
        check(try !stale.completeCleanup(b, proof: proof(b), permissionPending: true), "occupied-native-permission-call-blocks-exact-stop-proof")
        for field in ["local_grant_revoked", "receiver_stopped", "publisher_stopped", "children_stopped"] {
            var incomplete = proof(b); incomplete[field] = false
            check(try !stale.completeCleanup(b, proof: incomplete, permissionPending: false), "incomplete-actual-stop-proof-" + field + "-is-rejected")
        }
        var numeric = proof(b); numeric["children_stopped"] = 1
        check(try !stale.completeCleanup(b, proof: numeric, permissionPending: false), "numeric-one-cannot-substitute-for-stop-proof-boolean")
        var dirty = proof(b); dirty["private_content_cleanup"] = "failed"
        check(try !stale.completeCleanup(b, proof: dirty, permissionPending: false), "failed-private-content-cleanup-retains-uncertainty")
        var extra = proof(b); extra["extra"] = true
        check(try !stale.completeCleanup(b, proof: extra, permissionPending: false), "unknown-stop-proof-field-is-rejected")
        check(try !stale.completeCleanup(b, proof: oldSnapshot, permissionPending: false), "presentation-snapshot-cannot-substitute-for-typed-stop-proof")
        try stale.failCleanup(b)
        check(stale.record.cleanup_state == "unknown", "failed-current-stop-remains-unknown")
        check(try stale.completeCleanup(b, proof: proof(b), permissionPending: false), "fresh-exact-proof-can-resolve-current-unknown-stop")
        check(try !stale.completeCleanup(b, proof: proof(b), permissionPending: false), "duplicate-completion-is-a-no-op")
        try stale.setScope(scope(3))
        check(stale.record.scope?.lease_id == scope(3).lease_id && stale.record.cleanup_state == "pending", "new-unused-lease-requires-actual-current-cleanup")

        let same = try open(directory("same-session-new-epoch")); try same.setScope(scope(1))
        let sameA = try same.beginCleanup(requestID: uuid(21)).operation
        _ = try same.completeCleanup(sameA, proof: proof(sameA), permissionPending: false)
        let sameB = try same.beginCleanup(requestID: uuid(22)).operation
        try same.reconcile(oldSnapshot, permissionPending: false)
        check(try !same.completeCleanup(sameA, proof: proof(sameA), permissionPending: false), "same-session-generation-old-proof-cannot-finish-new-epoch")
        check(same.record.cleanup_state == "in_progress" && same.record.cleanup_operation == sameB, "same-session-epoch-remains-bound-to-new-operation")

        let replayPath = try directory("historical-replay"), replay = try open(replayPath)
        let replayA = try replay.beginCleanup(requestID: uuid(21)).operation
        let replayB = try replay.beginCleanup(requestID: uuid(22), command: "disable").operation
        let replayBefore = replay.record.cleanup_epoch, replayRevision = replay.record.revision
        let recalled = try replay.beginCleanup(requestID: uuid(21))
        check(recalled.replay && recalled.operation == replayA && replay.record.cleanup_epoch == replayBefore && replay.record.revision == replayRevision,
              "A-B-replay-A-preserves-exact-original-token-with-zero-authority-mutation")
        check(replay.record.cleanup_operation == replayB, "historical-A-replay-cannot-rebind-current-B")
        expect("invalid_request", "UUID-command-fingerprint-conflict-is-rejected", { _ = try replay.beginCleanup(requestID: uuid(21), command: "disable") })
        check(replay.record.cleanup_epoch == replayBefore, "rejected-fingerprint-conflict-cannot-advance-epoch")
        let restarted = try open(replayPath), restartEpoch = restarted.record.cleanup_epoch, restartRevision = restarted.record.revision
        let restartedReplay = try restarted.beginCleanup(requestID: uuid(21))
        check(restartedReplay.replay && restartedReplay.operation == replayA && restarted.record.cleanup_epoch == restartEpoch && restarted.record.revision == restartRevision,
              "A-B-restart-replay-A-retains-durable-historical-idempotency")
        check(restarted.record.cleanup_state == "unknown" && restarted.record.cleanup_requests.count == 2, "restart-keeps-entire-history-and-fails-closed")
        check(try !restarted.completeCleanup(replayB, proof: proof(replayB), permissionPending: false), "old-host-generation-completion-cannot-resolve-restart-epoch")
        expect("cleanup_unknown", "restart-unknown-cannot-grant-new-lease", { try restarted.setScope(scope(1)) })

        let concurrent = try open(directory("concurrent-replay"))
        let concurrentA = try concurrent.beginCleanup(requestID: uuid(21)).operation
        _ = try concurrent.beginCleanup(requestID: uuid(22))
        let concurrentEpoch = concurrent.record.cleanup_epoch
        let replays = (0..<12).map { _ in Task { @MainActor in try concurrent.beginCleanup(requestID: uuid(21)) } }
        for task in replays { let result = try await task.value; precondition(result.replay && result.operation == concurrentA) }
        check(concurrent.record.cleanup_epoch == concurrentEpoch && concurrent.record.cleanup_requests.count == 2, "concurrent-historical-replays-create-no-epochs-or-dispatches")
        let newDuplicates = (0..<12).map { _ in Task { @MainActor in try concurrent.beginCleanup(requestID: uuid(23)) } }
        var firstAdmissions = 0, tokens = Set<String>()
        for task in newDuplicates {
            let result = try await task.value; if !result.replay { firstAdmissions += 1 }; tokens.insert(result.operation.operation_id)
        }
        check(firstAdmissions == 1 && tokens.count == 1 && concurrent.record.cleanup_epoch == concurrentEpoch + 1 && concurrent.record.cleanup_requests.count == 3,
              "concurrent-first-admission-of-same-UUID-persists-one-token-and-one-dispatch-admission")

        let queued = try open(directory("serialized-reordered-stop")); try queued.setScope(scope(1))
        let queue = MessagesCleanupQueueV2(), gate = CleanupProbeGateV2()
        let queuedA = try queued.beginCleanup(requestID: uuid(21)).operation
        var activeStops = 0, maximumStops = 0, bStarted = false, oldAccepted = true
        let taskA = queue.enqueue {
            activeStops += 1; maximumStops = max(maximumStops, activeStops)
            await gate.pause()
            try queued.revoke(session: queuedA.session_id, generation: queuedA.generation)
            oldAccepted = try queued.completeCleanup(queuedA, proof: proof(queuedA), permissionPending: false)
            activeStops -= 1; return MessagesJSON(["done": true])
        }
        while !gate.started { await Task.yield() }
        let queuedB = try queued.beginCleanup(requestID: uuid(22)).operation
        let taskB = queue.enqueue {
            bStarted = true; activeStops += 1; maximumStops = max(maximumStops, activeStops)
            try queued.revoke(session: queuedB.session_id, generation: queuedB.generation)
            let complete = try queued.completeCleanup(queuedB, proof: proof(queuedB), permissionPending: false)
            activeStops -= 1; return MessagesJSON(["complete": complete])
        }
        for _ in 0..<30 { await Task.yield() }
        check(!bStarted && queued.record.cleanup_state == "in_progress", "new-stop-waits-for-old-stop-exit-before-actual-cleanup-dispatch")
        gate.release(); _ = try await taskA.value
        check(!oldAccepted, "delayed-old-actual-stop-completion-cannot-complete-new-native-operation")
        let bResult = try await taskB.value
        check(bResult.value["complete"] as? Bool == true && maximumStops == 1 && queued.record.cleanup_operation == queuedB,
              "serialized-new-exact-stop-alone-completes-current-operation")
        try queued.setScope(scope(2))
        let c = try queued.beginCleanup(requestID: uuid(23)).operation
        check(try !queued.completeCleanup(queuedB, proof: proof(queuedB), permissionPending: false), "reordered-prior-completion-after-new-lease-stays-rejected")
        check(queued.record.cleanup_operation == c && queued.record.cleanup_state == "in_progress", "reordered-stop-cannot-rebind-or-release-new-lease")
        expect("cleanup_unknown", "reordered-stop-cannot-permit-third-lease", { try queued.setScope(scope(3)) })

        let failPath = try directory("uncertain-history-write"), failure = CleanupProbeFailureV2()
        let failed = try MessagesRunJournalV2(root: failPath, runID: runID, policyHash: policy, notAfter: 1900, now: { 1000 }, persist: { bytes, path, fresh in
            if fresh { try MessagesNativeIO.writeNew(bytes, to: path) } else { try MessagesNativeIO.atomicWrite(bytes, to: path) }
            if failure.enabled { throw MessagesTransportFault("outcome_unknown") }
        })
        failure.enabled = true
        expect("storage_uncertain", "uncertain-history-fsync-does-not-acknowledge-stop-dispatch", { _ = try failed.beginCleanup(requestID: uuid(21)) })
        expect("storage_uncertain", "failed-history-journal-cannot-advertise-authority", { _ = try failed.evidence(backendReady: true) })
        let failedRestart = try open(failPath), failedEpoch = failedRestart.record.cleanup_epoch
        let durableReplay = try failedRestart.beginCleanup(requestID: uuid(21))
        check(durableReplay.replay && failedRestart.record.cleanup_epoch == failedEpoch, "persisted-uncertain-history-survives-restart-without-redispatch")

        let capacityPath = try directory("bounded-history"), bounded = try open(capacityPath)
        for i in 0..<MessagesRunJournalV2.cleanupRequestLimit { _ = try bounded.beginCleanup(requestID: uuid(100 + i)) }
        let fullEpoch = bounded.record.cleanup_epoch
        expect("storage_uncertain", "full-history-fails-closed-instead-of-evicting-old-UUIDs", { _ = try bounded.beginCleanup(requestID: uuid(999)) })
        let boundedRestart = try open(capacityPath), fullRestartEpoch = boundedRestart.record.cleanup_epoch
        check(try boundedRestart.beginCleanup(requestID: uuid(100)).replay, "oldest-UUID-is-still-idempotent-after-full-history-and-restart")
        check(boundedRestart.record.cleanup_requests.count == 64 && boundedRestart.record.cleanup_epoch == fullRestartEpoch && fullRestartEpoch > fullEpoch,
              "bounded-history-keeps-all-64-identities-and-only-native-boot-advances-epoch")
        expect("storage_uncertain", "durable-full-history-prevents-effect-authority-after-restart", { try boundedRestart.requireActive() })
        expect("storage_uncertain", "restart-does-not-create-space-by-dropping-history", { _ = try boundedRestart.beginCleanup(requestID: uuid(999)) })

        let oldPath = try directory("old-format-preserved")
        var oldRecord = try MessagesJSON.decode(MessagesNativeIO.privateFile(replayPath + "/run-v2.json")).value
        oldRecord["schema_version"] = 2; oldRecord.removeValue(forKey: "cleanup_requests"); oldRecord.removeValue(forKey: "cleanup_operation")
        oldRecord["last_cleanup_request"] = uuid(21)
        let oldBytes = try MessagesJSON(oldRecord).data
        try MessagesNativeIO.writeNew(oldBytes, to: oldPath + "/run-v2.json")
        expect("storage_uncertain", "unsafe-old-record-format-is-refused-without-migration-or-reset", { _ = try open(oldPath) })
        check(try MessagesNativeIO.privateFile(oldPath + "/run-v2.json") == oldBytes, "refused-old-journal-bytes-remain-exactly-intact")

        let clean = try open(directory("clean-shutdown-restart"))
        let cleanOp = try clean.beginSystemCleanup(session: uuid(11), generation: 1)
        _ = try clean.completeCleanup(cleanOp, proof: proof(cleanOp), permissionPending: false)
        try clean.shutdown()
        let cleanRestart = try open(URL(fileURLWithPath: root.path).appendingPathComponent("clean-shutdown-restart").path)
        check(cleanRestart.record.cleanup_state == "completed" && cleanRestart.record.cleanup_epoch == cleanOp.epoch && cleanRestart.record.deadline == 1900,
              "proved-clean-shutdown-retains-clean-state-with-original-deadline")
        let unknown = try open(directory("unproved-shutdown")); try unknown.setScope(scope(1)); try unknown.shutdown()
        check(unknown.record.cleanup_state == "unknown" && unknown.record.scope?.revoked == true, "unproved-shutdown-cannot-upgrade-pending-cleanup")
        let noBinding = try open(directory("shutdown-no-session-after-prior-completion"))
        let prior = try noBinding.beginSystemCleanup(session: uuid(11), generation: 1)
        _ = try noBinding.completeCleanup(prior, proof: proof(prior), permissionPending: false)
        let unavailableBinding = try noBinding.beginSystemCleanup(session: nil, generation: 0)
        check(noBinding.record.cleanup_state == "in_progress" && unavailableBinding.epoch > prior.epoch, "shutdown-admission-invalidates-prior-clean-proof-before-any-backend-await")
        check(try !noBinding.completeCleanup(unavailableBinding, proof: proof(prior), permissionPending: false), "missing-shutdown-binding-cannot-be-filled-from-old-scoped-proof")
        try noBinding.failCleanup(unavailableBinding); try noBinding.shutdown()
        let noBindingRestart = try open(root.appendingPathComponent("shutdown-no-session-after-prior-completion").path)
        check(noBindingRestart.record.cleanup_state == "unknown" && noBindingRestart.record.deadline == 1900,
              "failed-session-resolution-shutdown-remains-unknown-after-restart")
        let missingCancel = try open(directory("cancel-missing-cached-binding")); try missingCancel.setScope(scope(1))
        let knownCancel = try missingCancel.beginCleanup(requestID: uuid(21)).operation
        _ = try missingCancel.completeCleanup(knownCancel, proof: proof(knownCancel), permissionPending: false)
        let missingCancelOp = try missingCancel.beginCleanup(requestID: uuid(22), session: nil, generation: 0).operation
        check(missingCancelOp.session_id == nil && missingCancelOp.generation == 0 && missingCancel.record.cleanup_state == "in_progress",
              "missing-cancel-binding-does-not-inherit-a-prior-revoked-session")
        check(try !missingCancel.completeCleanup(missingCancelOp, proof: proof(knownCancel), permissionPending: false),
              "prior-completion-cannot-fill-missing-cancel-binding")

        print(String(data: try JSONSerialization.data(withJSONObject: ["passed": true, "count": checks.count, "checks": checks,
            "fixture_only": true, "synthetic_journals_retained": root.path, "actual_backend_processes": 0, "helper_launches": 0,
            "Messages_DB_reads": 0, "TCC_or_Automation_calls": 0, "real_sends": 0, "journal_resets": 0], options: [.sortedKeys, .prettyPrinted]), encoding: .utf8)!)
    }
}
