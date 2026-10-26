import Foundation
import Observation

enum MessagesProductTextState: String, Sendable {
    case held, unknown, setupRequired, reviewRequired, verifying, trialVerified, syntheticTrial, interrupted, cleanupUncertain
}

enum MessagesProductAction: String, CaseIterable, Sendable {
    case begin, openMessages, confirmAccount, retestAccess, receiveSettings, requestSend, retestSend
    case discoverGroups, prepareTest, startTest, refresh, cancel, disable, reconnect
    var hostAction: String {
        switch self {
        case .receiveSettings: "receive_settings"
        case .retestAccess: "receive_retest"
        case .requestSend, .retestSend: "send_permission"
        case .openMessages: "open_messages"
        case .confirmAccount: "confirm_account"
        case .discoverGroups: "discover_groups"
        case .prepareTest: "prepare_test"
        case .startTest: "start_test"
        default: rawValue
        }
    }
}

/// One owned feature per RuntimeStore. Durable send/cleanup authority remains in the native host.
@MainActor @Observable final class MessagesProductStore {
    private let client: any MessagesProductClient
    let held: Bool
    let synthetic: Bool
    let trialCeiling: TimeInterval?
    private(set) var snapshot: MessagesProductSnapshot?
    private(set) var candidates: [GroupChoice] = []
    private(set) var selectedGroup: GroupChoice?
    private(set) var review: MessagesProductReview?
    private(set) var scopeApproved = false
    private(set) var busy = false
    private(set) var lastError: String?
    private(set) var interrupted = false
    private(set) var cleanupUncertain = false
    private(set) var sendAttemptObserved = false
    private var panel: OnboardingPanel?
    private var revision = 0
    private var receivedAt: TimeInterval?
    private var attemptedPlans = Set<String>()
    private let now: @MainActor () -> TimeInterval

    init(client: any MessagesProductClient, held: Bool = true, synthetic: Bool = false, trialCeiling: TimeInterval? = nil,
         now: @escaping @MainActor () -> TimeInterval = { Date().timeIntervalSince1970 }) {
        self.client = client; self.held = held; self.synthetic = synthetic; self.trialCeiling = trialCeiling; self.now = now
    }
    var evidenceCurrent: Bool {
        guard let receivedAt else { return false }
        let age = now() - receivedAt
        return age >= 0 && age < 30 && !interrupted && !held && !cleanupUncertain
            && (review.map({ now() < $0.expires_at }) ?? true)
            && (trialCeiling.map({ $0.isFinite && now() < $0 }) ?? synthetic)
    }
    var textState: MessagesProductTextState {
        if held { return .held }
        if cleanupUncertain { return .cleanupUncertain }
        if interrupted { return .interrupted }
        guard evidenceCurrent, let s = snapshot else { return .unknown }
        if s.trialVerified { return synthetic ? .syntheticTrial : .trialVerified }
        if [.verifying, .verifyingMio].contains(s.phase) { return .verifying }
        if s.permissions.authorized && s.selection.state == "selected" { return .reviewRequired }
        return .setupRequired
    }
    // Media source capabilities are not grants; this host has no media or understanding route.
    let imageState = "source_implemented_not_admitted"
    let videoState = "source_implemented_not_admitted"
    let understandingState = "not_performed"
    let mioState = "external_event_unproven"

    func can(_ action: MessagesProductAction) -> Bool {
        guard !held else { return false }
        if action == .cancel || action == .disable { return busy || cleanupUncertain || snapshot?.enabled == true }
        guard !busy else { return false }
        if action == .refresh { return trialCeiling.map({ now() < $0 }) ?? synthetic } // distinct from passive status
        guard evidenceCurrent, let s = snapshot else { return false }
        if action == .startTest {
            return !sendAttemptObserved && s.phase == .reviewTest && s.permissions.authorized && scopeApproved && selectedGroup != nil
                && review.map({ !attemptedPlans.contains($0.plan_id) && $0.scope_id == s.selection.scope_id && now() < $0.expires_at }) == true
        }
        guard panel?.actions.first(where: { $0.id == action.hostAction })?.enabled == true else { return false }
        if action == .prepareTest { return selectedGroup != nil && !sendAttemptObserved }
        if action == .begin || action == .reconnect {
            return !cleanupUncertain && ["completed", "not_required"].contains(s.cleanup)
        }
        return true
    }
    func approveReview(_ approved: Bool) {
        scopeApproved = approved && evidenceCurrent && review != nil && selectedGroup != nil && !busy
    }
    /// Called on tab disappearance, runtime/account context change, or process interruption.
    /// This invalidates UI evidence; it does not claim to stop a host or revoke OS grants.
    func interrupt() {
        revision += 1; busy = false; interrupted = true; receivedAt = nil
        candidates = []; selectedGroup = nil; review = nil; scopeApproved = false; panel = nil; snapshot = nil
    }
    func expireEvidence() {
        if !evidenceCurrent { receivedAt = nil; scopeApproved = false }
    }
    /// Only a pure snapshot: no discovery, OS observation, launch, retries or effect resumption.
    func refreshStatus() async { await execute(.snapshot) }

    func perform(_ action: MessagesProductAction) async {
        guard can(action) else { return }
        if [.cancel, .disable].contains(action) {
            revision += 1; busy = false; receivedAt = nil; scopeApproved = false
            candidates = []; selectedGroup = nil; review = nil; cleanupUncertain = true
        }
        if action == .startTest, let review {
            attemptedPlans.insert(review.plan_id) // consume locally before awaiting; native tombstone is authoritative
            sendAttemptObserved = true // never reset across cancel/reconnect or plan changes
            scopeApproved = false
            await execute(.startTest, arguments: ["plan_id": review.plan_id]); return
        }
        switch action {
        case .begin: await execute(.begin)
        case .openMessages: await execute(.openMessages)
        case .confirmAccount: await execute(.confirmAccount, arguments: ["report": "signed_in_in_messages"])
        case .receiveSettings: await execute(.permissionAction, arguments: ["capability_id": "messages.receive.v1", "action": "open_settings"])
        case .retestAccess: await execute(.permissionAction, arguments: ["capability_id": "messages.receive.v1", "action": "retest"])
        case .requestSend: await execute(.permissionAction, arguments: ["capability_id": "messages.send.v1", "action": "request"])
        case .retestSend: await execute(.permissionAction, arguments: ["capability_id": "messages.send.v1", "action": "retest"])
        case .discoverGroups: await execute(.discoverGroups)
        case .prepareTest: await execute(.prepareTest)
        case .refresh: await execute(.refresh)
        case .cancel: await execute(.cancel)
        case .disable: await execute(.disable)
        case .reconnect: await execute(.reconnect)
        case .startTest: break
        }
    }
    func selectGroup(_ candidateID: String) async {
        guard !held, !busy, evidenceCurrent,
              let choice = candidates.first(where: { $0.id == candidateID }) else { return }
        selectedGroup = nil; review = nil; scopeApproved = false
        if await execute(.selectGroup, arguments: ["candidate_id": candidateID]),
           snapshot?.selection.state == "selected" { selectedGroup = choice }
    }
    @discardableResult private func execute(_ command: OnboardingCommand, arguments: [String: String] = [:]) async -> Bool {
        guard !held, !busy else { return false }
        let token = revision
        busy = true; lastError = nil
        // Do not display old trial success during a manual permission/effect transition.
        receivedAt = nil
        let oldEpoch = snapshot?.epoch
        do {
            let request = OnboardingRequest(command, arguments: arguments)
            let reply = try MessagesProductReply.decode(try await client.exchange(request), for: request)
            guard token == revision else { return false }
            guard reply.ok else { throw MessagesTransportFault(reply.error!.code) }
            var statusReply = reply
            if reply.snapshot == nil {
                let status = OnboardingRequest(.snapshot)
                statusReply = try MessagesProductReply.decode(try await client.exchange(status), for: status)
                guard token == revision else { return false }
                guard statusReply.ok else { throw MessagesTransportFault(statusReply.error!.code) }
            }
            guard let s = statusReply.snapshot else { throw MessagesTransportFault("invalid_response") }
            if let oldEpoch, oldEpoch != s.epoch {
                clearReview()
                if reply.candidates != nil || reply.plan != nil { throw MessagesTransportFault("invalid_evidence") }
            }
            snapshot = s; panel = statusReply.presentation; receivedAt = now(); interrupted = false
            // A reduced generic controller counter is negative evidence only.
            // Its initial 3 never establishes unused native one-send authority.
            if s.remaining_test_sends < 3 { sendAttemptObserved = true }
            if ["unknown", "failed"].contains(s.cleanup) || s.phase == .needsReview { cleanupUncertain = true }
            else if ["completed", "not_required"].contains(s.cleanup) { cleanupUncertain = false }
            if s.last_error != nil { scopeApproved = false }
            if s.selection.state != "selected" { selectedGroup = nil; review = nil; scopeApproved = false }
            if let choices = reply.candidates { candidates = choices; review = nil; scopeApproved = false }
            if let plan = reply.plan {
                guard selectedGroup != nil, plan.scope_id == s.selection.scope_id,
                      plan.expires_at > now(), plan.expires_at <= now() + 900 else { throw MessagesTransportFault("invalid_evidence") }
                review = plan; scopeApproved = false
            }
            busy = false
            return true
        } catch {
            guard token == revision else { return false }
            let code = (error as? MessagesTransportFault)?.code ?? "host_unavailable"
            lastError = MessagesProductReply.codes.union(MessagesProductReply.transportCodes).contains(code) ? code : "host_unavailable"
            if [.cancel, .disable, .startTest].contains(command) || ["send_unknown", "cleanup_unknown", "storage_uncertain"].contains(code) {
                cleanupUncertain = true
            }
            receivedAt = nil; snapshot = nil; panel = nil; clearReview(); busy = false
            return false
        }
    }
    private func clearReview() { candidates = []; selectedGroup = nil; review = nil; scopeApproved = false }
}

@MainActor @Observable final class MessagesProductFeature {
    let store: MessagesProductStore
    init(home: URL, demo: Bool, admission: MessagesProductAdmission? = nil) {
        let reviewed = demo ? nil : admission
        store = MessagesProductStore(client: MessagesProductNativeClient(home: home, admission: reviewed),
                                     held: reviewed == nil, trialCeiling: reviewed?.notAfter)
    }
}
