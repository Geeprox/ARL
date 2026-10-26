import Foundation

@MainActor final class V2FixtureClock { var value: Double = 1000 }
@MainActor final class V2FixtureWriteFailure { var enabled = false }

@MainActor final class V2FixtureClient: MessagesProductClientV2 {
    enum Response { case reply(Data), pause(Data), failure(String) }
    let journal: MessagesRunJournalV2
    var connected = true
    var candidateRun: String
    var responses: [Response] = []
    var requests: [OnboardingRequest] = []
    var inspections = 0
    var inspectionFailure: String?
    var permissionPending = false
    var overrideAuthority: [String: Any]?
    var cleanupOperation: MessagesCleanupOperationV2?
    private var pending: (CheckedContinuation<Data, any Error>, Data, OnboardingRequest)?
    init(_ journal: MessagesRunJournalV2) { self.journal = journal; candidateRun = journal.record.run_id }
    func inspectCandidate() async throws -> MessagesV2CandidateStatus {
        inspections += 1
        if let inspectionFailure { throw MessagesTransportFault(inspectionFailure) }
        return .verified(runID: candidateRun, policyHash: journal.record.policy_sha256)
    }
    func exchange(_ request: OnboardingRequest) async throws -> Data {
        requests.append(request)
        if !connected { throw MessagesTransportFault("host_not_connected") }
        guard !responses.isEmpty else { throw MessagesTransportFault("host_unavailable") }
        if ["cancel", "disable"].contains(request.command) {
            let core = try MessagesJSON.decode({ if case .reply(let data) = responses[0] { return data }; return Data("{}".utf8) }()).value["snapshot"] as? [String: Any]
            let admission = try journal.beginCleanup(requestID: request.requestID.uuidString.lowercased(), command: request.command,
                                                     session: core?["session_id"] as? String, generation: MessagesNativeIO.integer(core?["generation"]))
            if !admission.replay { cleanupOperation = admission.operation }
        }
        switch responses.removeFirst() {
        case .reply(let data): return try envelope(data, request)
        case .failure(let code): throw MessagesTransportFault(code)
        case .pause(let data):
            permissionPending = true
            return try await withCheckedThrowingContinuation { pending = ($0, data, request) }
        }
    }
    var isPaused: Bool { pending != nil }
    func release() throws {
        guard let (continuation, data, request) = pending else { return }
        pending = nil; permissionPending = false; continuation.resume(returning: try envelope(data, request))
    }
    func envelope(_ data: Data, _ request: OnboardingRequest) throws -> Data {
        var raw = try MessagesJSON.decode(data).value
        // Fixture supplies explicit operation-correlated actual-stop evidence, separately from core status.
        // Permission fixtures retain it until the synthetic occupied native call has exited.
        if !permissionPending, let op = cleanupOperation {
            _ = try journal.completeCleanup(op, proof: syntheticCleanupProofV2(op), permissionPending: false)
            cleanupOperation = nil
        }
        raw["schema_version"] = 2; raw["request_id"] = request.requestID.uuidString.lowercased(); raw["command"] = request.command
        raw["authority"] = try overrideAuthority ?? journal.evidence(backendReady: true).wireValue
        return try MessagesJSON(raw).data
    }
}

func syntheticCleanupProofV2(_ op: MessagesCleanupOperationV2) -> [String: Any] {
    ["session_id": op.session_id ?? (NSNull() as Any), "generation": op.generation,
     "local_grant_revoked": true, "receiver_stopped": true, "publisher_stopped": true,
     "children_stopped": true, "private_content_cleanup": "completed"]
}

@main struct ContractTestsV2 {
    @MainActor static func main() async throws {
        let source = try MessagesJSON.decode(Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])), limit: 200000).value
        precondition(source["fixture_only"] as? Bool == true)
        let fixtures = try source.filter { $0.value is [String: Any] }.mapValues { try JSONSerialization.data(withJSONObject: $0) }
        let clock = V2FixtureClock()
        let runID = "00000000-0000-0000-0000-000000000001", hash = String(repeating: "a", count: 64)
        let area = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/host-contract-v2/fixtures-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: area, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: area) }
        var checks: [String] = []
        func check(_ passed: Bool, _ name: String) { precondition(passed, name); checks.append(name) }
        func directory(_ name: String) throws -> String {
            let path = area.appendingPathComponent(name).path
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]); return path
        }
        func journal(_ name: String) throws -> MessagesRunJournalV2 { try MessagesRunJournalV2(root: directory(name), runID: runID, policyHash: hash, notAfter: 1900, now: { clock.value }) }
        func store(_ client: V2FixtureClient, held: Bool = false) -> MessagesProductStoreV2 {
            MessagesProductStoreV2(client: client, held: held, synthetic: true, trialCeiling: 1900, expectedRunID: runID, expectedPolicyHash: hash, now: { clock.value })
        }
        func queue(_ client: V2FixtureClient, _ names: [String]) { client.responses.append(contentsOf: names.map { .reply(fixtures[$0]!) }) }
        func expect(_ code: String, _ name: String, _ block: () throws -> Void) {
            do { try block(); preconditionFailure(name) }
            catch { check((error as? MessagesTransportFault)?.code == code, name) }
        }
        let localCore = source["local"] as! [String: Any], local = localCore["snapshot"] as! [String: Any]
        let plan = (source["review"] as! [String: Any])["plan"] as! [String: Any]
        let session = local["session_id"] as! String
        func scope(_ lease: String = "lease_" + String(repeating: "b", count: 64)) -> MessagesNativeScopeV2 {
            .init(lease_id: lease, session_id: session, generation: 1, candidate_pin: plan["group_pin"] as! String,
                owner: "messages:" + runID, group_id: "iMessage;+;synthetic-family", scope_id: plan["scope_id"] as! String,
                plan_hash: String(repeating: "c", count: 64), operation_id: plan["operation_id"] as! String,
                send_text_sha256: MessagesNativeIO.hash(Data((plan["send_text"] as! String).utf8)), expires_at: 1900,
                revoked: false, consumed: false, send_outcome: "not_started")
        }

        let j = try journal("main"), client = V2FixtureClient(j), ui = store(client)
        let first = try j.evidence(backendReady: false)
        check(first.deadline == 1900 && first.send.outcome == "unused" && !first.backend_ready, "native-journal-deadline-and-budget-exist-before-backend-ready")
        let bytes = try MessagesJSON(first.wireValue).data
        try JSONDecoder().decode(MessagesNativeAuthorityV2.self, from: bytes).validate(MessagesJSON.decode(bytes).value)
        check(true, "explicit-null-authority-fields-roundtrip-strict-schema")
        let heldClient = V2FixtureClient(try journal("held")), held = store(heldClient, held: true)
        await held.refreshStatus(); for action in MessagesProductAction.allCases { await held.perform(action) }
        check(heldClient.inspections == 0 && heldClient.requests.isEmpty, "held-store-stops-before-candidate-file-socket-or-launch")
        check(held.holdReason == .admissionMissing && held.diagnostic == nil, "composition-hold-is-not-a-system-permission-denial")
        let isolatedHome = URL(fileURLWithPath: "/unavailable-fixture-home")
        let suppliedAdmission = MessagesProductAdmission(runID: runID, policySHA256: hash, closureSHA256: hash, notAfter: 1900)
        check(MessagesProductFeatureV2(home: isolatedHome, demo: true, admission: suppliedAdmission).store.holdReason == .preview,
              "demo-preserves-hold-and-does-not-create-native-permission-entry")
        check(MessagesProductFeatureV2(home: isolatedHome, demo: false, isolated: true, admission: suppliedAdmission).store.holdReason == .isolated,
              "runtime-home-isolation-preserves-hold-with-explicit-pins")
        check(MessagesProductFeatureV2(home: isolatedHome, demo: false, sourceHeld: true, admission: suppliedAdmission).store.holdReason == .sourceHeld,
              "source-hold-remains-distinct-from-missing-admission")
        let invalidInspection = V2FixtureClient(try journal("inspection-error"))
        invalidInspection.inspectionFailure = "unbounded-backend-text-must-not-display"
        let invalidInspectionUI = store(invalidInspection); await invalidInspectionUI.refreshStatus()
        check(invalidInspectionUI.lastError == "host_unavailable" && invalidInspectionUI.diagnostic?.code == "host_unavailable" && invalidInspection.requests.isEmpty,
              "inspection-error-is-normalized-before-presentation-without-effect-dispatch")
        let nativeHeld = MessagesProductNativeClientV2(home: URL(fileURLWithPath: "/unavailable-fixture-home"), admission: nil)
        if case .held = try await nativeHeld.inspectCandidate() { check(true, "native-inspection-without-admission-is-held") } else { preconditionFailure("native hold") }
        do { _ = try await nativeHeld.exchange(OnboardingRequest(.begin)); preconditionFailure("native held effect") }
        catch { check((error as? MessagesTransportFault)?.code == "activation_not_approved", "native-held-exchange-rejects-before-identity-or-files") }
        let expiredAdmission = MessagesProductAdmission(runID: runID, policySHA256: hash, closureSHA256: hash, notAfter: 1)
        do { _ = try await MessagesProductNativeClientV2(home: URL(fileURLWithPath: "/unavailable-fixture-home"), admission: expiredAdmission).exchange(OnboardingRequest(.begin)); preconditionFailure("expired native begin") }
        catch { check((error as? MessagesTransportFault)?.code == "verification_expired", "expired-root-admission-rejects-before-any-bootstrap-launch") }

        client.connected = false; await ui.refreshStatus()
        check(ui.candidateVerified && ui.authority == nil && ui.textState == .unknown && ui.can(.begin), "verified-candidate-without-first-snapshot-enables-only-explicit-begin-not-ready")
        let initialCalls = client.requests.count
        check(client.requests.allSatisfy({ $0.command == "snapshot" }), "passive-first-probe-never-begins-or-launches")
        client.connected = true; queue(client, ["account"]); await ui.perform(.begin)
        check(client.requests.count == initialCalls + 1 && client.requests.last?.command == "begin" && ui.snapshot?.phase == .account, "explicit-first-begin-reaches-owned-route-without-snapshot-deadlock")
        check(!ui.can(.begin) && ui.textState == .setupRequired, "bootstrap-completion-does-not-claim-account-permission-or-text-readiness")
        let badCandidate = V2FixtureClient(try journal("bad-candidate")); badCandidate.candidateRun = "00000000-0000-0000-0000-000000000002"
        let wrong = store(badCandidate); await wrong.refreshStatus()
        check(!wrong.can(.begin) && badCandidate.requests.isEmpty, "unmatched-candidate-pin-cannot-enter-bootstrap")

        queue(client, ["group", "groups", "group", "selected", "review", "selected"])
        await ui.refreshStatus(); await ui.perform(.discoverGroups)
        await ui.selectGroup(ui.candidates[0].id); await ui.perform(.prepareTest)
        check(ui.review != nil && ui.authority?.send.outcome == "unused" && !ui.can(.startTest), "typed-native-unused-budget-still-requires-private-group-plan-and-scope-review")
        ui.approveReview(true); check(ui.can(.startTest), "exact-current-plan-can-start-with-unused-native-tombstone")
        var erroredSelected = try MessagesJSON.decode(fixtures["selected"]!).value
        var erroredSnapshot = erroredSelected["snapshot"] as! [String: Any]
        erroredSnapshot["last_error"] = "group_changed"; erroredSelected["snapshot"] = erroredSnapshot
        client.responses.append(.reply(try MessagesJSON(erroredSelected).data)); await ui.refreshStatus()
        ui.approveReview(true)
        check(ui.diagnostic?.code == "group_changed" && !ui.can(.startTest) && !ui.can(.prepareTest),
              "snapshot-group-error-is-visible-and-cannot-be-overridden-by-UI-approval")
        queue(client, ["selected"]); await ui.refreshStatus(); ui.approveReview(true)
        check(ui.can(.startTest) && ui.diagnostic == nil, "fresh-success-clears-stale-diagnostic-without-renewing-budget")
        let nativeScope = scope(); try j.setScope(nativeScope)
        expect("attempt_consumed", "text-hash-mismatch-never-consumes-or-dispatches", { try j.consume(operationID: nativeScope.operation_id, textHash: String(repeating: "d", count: 64)) })
        try j.consume(operationID: nativeScope.operation_id, textHash: nativeScope.send_text_sha256)
        queue(client, ["verifying"]); await ui.perform(.startTest)
        check(ui.sendAttemptObserved && ui.authority?.send.outcome == "consumed_unknown" && !ui.can(.startTest), "durable-native-consumption-precedes-effect-and-disables-repeat")
        let afterStart = client.requests.count; await ui.perform(.startTest)
        check(client.requests.count == afterStart, "duplicate-UI-start-does-not-call-native-again")
        expect("attempt_consumed", "same-operation-replay-cannot-consume-twice", { try j.consume(operationID: nativeScope.operation_id, textHash: nativeScope.send_text_sha256) })
        try j.outcome(operationID: nativeScope.operation_id, state: "accepted")
        queue(client, ["local"]); await ui.refreshStatus()
        check(ui.textState == .syntheticTrial && ui.authority?.send.limit == 1, "actual-native-envelope-required-for-bounded-synthetic-text-proof")
        check(ui.imageState == "not_admitted_or_verified" && ui.videoState == "not_admitted_or_verified" && ui.mioState == "external_event_unproven", "v2-contract-adds-no-media-model-or-Mio-authority")

        var forged = try j.evidence(backendReady: true).wireValue
        forged["revision"] = 0; client.overrideAuthority = forged; queue(client, ["local"]); await ui.refreshStatus()
        check(ui.textState != .syntheticTrial && ui.authority == nil, "invalid-native-revision-removes-success")
        client.overrideAuthority = nil; queue(client, ["local"]); await ui.refreshStatus()
        var falseSend = try j.evidence(backendReady: true).wireValue
        falseSend["send"] = ["limit": 1, "consumed": false, "outcome": "unused", "operation_id": NSNull()]
        client.overrideAuthority = falseSend; queue(client, ["local"]); await ui.refreshStatus()
        check(ui.authority == nil && ui.sendAttemptObserved, "replayed-unused-counter-cannot-clear-native-consumption-highwater")
        client.overrideAuthority = nil

        let path = j.record.deadline
        let restarted = try MessagesRunJournalV2(root: area.appendingPathComponent("main").path, runID: runID, policyHash: hash, notAfter: 1900, now: { clock.value })
        let restartedEvidence = try restarted.evidence(backendReady: true)
        check(restartedEvidence.deadline == path && restartedEvidence.host_generation == 2 && restartedEvidence.send.consumed, "host-restart-preserves-original-deadline-and-consumed-native-send")
        check(restartedEvidence.cleanup.state == "unknown" && restartedEvidence.lease.state == "revoked", "abrupt-host-restart-revokes-lease-and-advances-unknown-cleanup-epoch")
        let restartClient = V2FixtureClient(restarted), restartUI = store(restartClient)
        queue(restartClient, ["restart"]); await restartUI.refreshStatus()
        check(restartUI.textState == .cleanupUncertain && !restartUI.can(.reconnect) && restartClient.requests.map(\.command) == ["snapshot"], "new-Control-only-snapshots-authoritative-restart-uncertainty-no-auto-resume")
        queue(restartClient, ["disabled"]); await restartUI.perform(.cancel)
        check(restartUI.authority?.cleanup.state == "completed" && !restartUI.cleanupUncertain, "real-source-cleanup-proof-and-native-occupancy-release-matching-epoch")
        let cleanupEpoch = restarted.record.cleanup_epoch
        let cancelReplay = restartClient.requests.last!
        queue(restartClient, ["disabled"]); _ = try await restartClient.exchange(cancelReplay)
        check(restarted.record.cleanup_epoch == cleanupEpoch, "same-cancel-request-replay-does-not-create-another-cleanup-epoch")
        queue(restartClient, ["account"]); await restartUI.perform(.reconnect)
        check(restartUI.sendAttemptObserved && !restartUI.can(.startTest) && restarted.record.deadline == 1900, "reconnect-cannot-renew-native-send-or-original-deadline")
        expect("attempt_consumed", "new-lease-after-consumed-send-cannot-replenish-budget", { try restarted.setScope(scope("lease_" + String(repeating: "e", count: 64))) })
        try restarted.revoke(session: "00000000-0000-0000-0000-000000000003", generation: 2)
        check(restarted.record.cleanup_generation == 2 && restarted.record.scope?.consumed == true, "cancel-after-reconnect-can-clean-new-controller-session-without-reviving-old-scope")

        let unused = try journal("unused-revocation")
        try unused.setScope(scope()); try unused.revoke(session: session, generation: 1)
        let unusedOperation = unused.record.cleanup_operation!
        _ = try unused.completeCleanup(unusedOperation, proof: syntheticCleanupProofV2(unusedOperation), permissionPending: false)
        expect("activation_not_approved", "revoked-lease-cannot-be-restored-by-replaying-old-grant", { try unused.setScope(scope()) })
        var changedGroup = scope("lease_" + String(repeating: "f", count: 64))
        changedGroup = .init(lease_id: changedGroup.lease_id, session_id: changedGroup.session_id, generation: changedGroup.generation,
            candidate_pin: String(repeating: "f", count: 64), owner: changedGroup.owner, group_id: "iMessage;+;other-fixture", scope_id: changedGroup.scope_id,
            plan_hash: changedGroup.plan_hash, operation_id: changedGroup.operation_id, send_text_sha256: changedGroup.send_text_sha256,
            expires_at: changedGroup.expires_at, revoked: false, consumed: false, send_outcome: "not_started")
        expect("group_changed", "first-native-group-and-participant-pin-cannot-change-on-reconnect", { try unused.setScope(changedGroup) })
        let shorter = try MessagesRunJournalV2(root: directory("shorter-window"), runID: runID, policyHash: hash, notAfter: 1100, now: { clock.value })
        check(shorter.record.deadline == 1100 && shorter.record.started_at == 1000, "sealed-root-ceiling-shortens-native-deadline-without-renewal")

        let permissionJournal = try journal("permission"), permissionClient = V2FixtureClient(permissionJournal), permissionUI = store(permissionClient)
        queue(permissionClient, ["permissions"]); await permissionUI.refreshStatus()
        permissionClient.responses.append(.pause(fixtures["group"]!))
        let pendingPermission = Task { await permissionUI.perform(.requestSend) }
        for _ in 0..<1000 { if permissionClient.isPaused { break }; await Task.yield() }
        precondition(permissionClient.isPaused)
        queue(permissionClient, ["disabled"]); await permissionUI.perform(.cancel)
        check(permissionUI.cleanupUncertain && permissionUI.authority?.cleanup.state == "in_progress", "pending-native-permission-prevents-premature-completed-cleanup")
        try permissionClient.release(); await pendingPermission.value
        check(permissionUI.cleanupUncertain && permissionUI.snapshot?.phase == .disabled, "late-permission-reply-cannot-restore-or-clear-cancelled-state")
        queue(permissionClient, ["disabled"]); await permissionUI.refreshStatus()
        check(!permissionUI.cleanupUncertain && permissionUI.authority?.cleanup.state == "completed", "fresh-completed-cleanup-after-permission-exit-is-required")
        check(!permissionUI.sendAttemptObserved && permissionUI.authority?.send.outcome == "unused", "generic-controller-counter-cannot-consume-native-unused-budget")

        let failureJournal = try journal("stop-failure"), failureClient = V2FixtureClient(failureJournal), failureUI = store(failureClient)
        queue(failureClient, ["account"]); await failureUI.refreshStatus()
        failureClient.responses.append(.failure("host_unavailable")); await failureUI.perform(.cancel)
        check(failureUI.cleanupUncertain && !failureUI.can(.reconnect), "lost-stop-response-keeps-cleanup-uncertain")

        let expiryClient = V2FixtureClient(restarted), expiryUI = store(expiryClient)
        clock.value = 1900; queue(expiryClient, ["local"]); await expiryUI.refreshStatus()
        check(restarted.record.expired && expiryUI.textState != .syntheticTrial && !expiryUI.can(.begin), "native-sticky-expiry-dominates-still-green-controller-snapshot")
        expect("verification_expired", "native-absolute-deadline-blocks-any-new-lease", { try restarted.requireActive() })
        clock.value = 1899
        expect("clock_rollback", "durable-native-clock-highwater-rejects-rollback", { try restarted.observe() })
        clock.value = 1950
        let expiredRestart = try MessagesRunJournalV2(root: area.appendingPathComponent("main").path, runID: runID, policyHash: hash, notAfter: 1900, now: { clock.value })
        check(expiredRestart.record.expired && expiredRestart.record.deadline == 1900 && expiredRestart.record.scope?.consumed == true, "expired-restart-cannot-recreate-window-or-native-budget")
        clock.value = 1000

        let legacyRoot = try directory("legacy")
        try Data("{}".utf8).write(to: URL(fileURLWithPath: legacyRoot + "/ceiling.json"))
        expect("storage_uncertain", "v2-refuses-v1-state-instead-of-renewing-or-migrating-budget", { _ = try MessagesRunJournalV2(root: legacyRoot, runID: runID, policyHash: hash, notAfter: 1900, now: { clock.value }) })
        let crashRoot = try directory("write-failure")
        let failWrite = V2FixtureWriteFailure()
        let crashJournal = try MessagesRunJournalV2(root: crashRoot, runID: runID, policyHash: hash, notAfter: 1900, now: { clock.value }, persist: { data, path, fresh in
            if fresh { try MessagesNativeIO.writeNew(data, to: path) } else { try MessagesNativeIO.atomicWrite(data, to: path) }
            if failWrite.enabled { throw MessagesTransportFault("outcome_unknown") }
        })
        try crashJournal.setScope(scope()); failWrite.enabled = true
        expect("storage_uncertain", "uncertain-fsync-never-acknowledges-send-dispatch", { try crashJournal.consume(operationID: scope().operation_id, textHash: scope().send_text_sha256) })
        expect("storage_uncertain", "failed-journal-cannot-advertise-unused-send", { _ = try crashJournal.evidence(backendReady: true) })
        let crashRestart = try MessagesRunJournalV2(root: crashRoot, runID: runID, policyHash: hash, notAfter: 1900, now: { clock.value })
        check(crashRestart.record.scope?.consumed == true && crashRestart.record.deadline == 1900, "persisted-uncertain-consumption-survives-restart-without-retry")
        let partialRoot = try directory("partial")
        try Data("partial".utf8).write(to: URL(fileURLWithPath: partialRoot + "/run-v2.json.new-fixture"))
        expect("storage_uncertain", "partial-native-transaction-blocks-fresh-authority-creation", { _ = try MessagesRunJournalV2(root: partialRoot, runID: runID, policyHash: hash, notAfter: 1900, now: { clock.value }) })

        let request = OnboardingRequest(.snapshot)
        expect("protocol_upgrade_required", "v1-reply-has-no-v2-authority-fallback", { _ = try MessagesProductReplyV2.decode(fixtures["local"]!, for: request) })
        let raw = try MessagesControlWireV2.encode(OnboardingRequest(.begin))
        check(try MessagesControlWireV2.decode(raw).command == "begin", "v2-finite-command-decodes-to-existing-owned-backend-v1-frame")
        expect("invalid_request", "v1-command-cannot-enter-version2-host", { _ = try MessagesControlWireV2.decode(JSONEncoder().encode(OnboardingRequest(.begin))) })
        expect("invalid_request", "arbitrary-script-argument-refused-by-fixed-v2-bootstrap", { _ = try MessagesControlWireV2.decode(MessagesControlWireV2.encode(OnboardingRequest(.begin, arguments: ["script": "forbidden"]))) })
        expect("event_unproven", "v2-does-not-add-Mio-publish-route", { _ = try MessagesControlWireV2.decode(MessagesControlWireV2.encode(OnboardingRequest(.verifyMio))) })
        var missing = try first.wireValue; missing.removeValue(forKey: "deadline")
        do { let value = try JSONDecoder().decode(MessagesNativeAuthorityV2.self, from: MessagesJSON(missing).data); try value.validate(missing); preconditionFailure("missing deadline") }
        catch { check(true, "missing-native-deadline-fails-closed") }
        var extra = try first.wireValue; extra["granted_media"] = true
        expect("invalid_response", "unknown-authority-fields-cannot-create-media-capability", { try first.validate(extra) })

        let output: [String: Any] = ["schema_version": 2, "passed": true, "count": checks.count, "checks": checks,
            "fixture_only": true, "actual_identity_or_OS_attribution_proven": false, "host_launches": 0,
            "TCC_or_Automation_calls": 0, "Messages_DB_reads": 0, "real_group_sends": 0,
            "new_OS_grants": 0, "same_Mio_wake_proven": false, "installed_changes": 0]
        print(String(data: try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys, .prettyPrinted]), encoding: .utf8)!)
    }
}
