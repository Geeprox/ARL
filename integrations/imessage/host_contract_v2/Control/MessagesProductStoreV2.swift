import Foundation
import Observation

/// One owned feature per RuntimeStore. Durable send/cleanup authority remains in the native host.
@MainActor @Observable final class MessagesProductStoreV2 {
    private let client: any MessagesProductClientV2
    let held: Bool
    let holdReason: MessagesProductHoldReasonV2?
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
    private(set) var authority: MessagesNativeAuthorityV2?
    private(set) var candidateVerified = false
    private var lastAuthority: MessagesNativeAuthorityV2?
    private let expectedRunID: String?
    private let expectedPolicyHash: String?
    private var panel: OnboardingPanel?
    private var revision = 0
    private var receivedAt: TimeInterval?
    private var attemptedPlans = Set<String>()
    private let now: @MainActor () -> TimeInterval

    init(client: any MessagesProductClientV2, held: Bool = true, holdReason: MessagesProductHoldReasonV2 = .admissionMissing, synthetic: Bool = false, trialCeiling: TimeInterval? = nil, expectedRunID: String? = nil, expectedPolicyHash: String? = nil,
         now: @escaping @MainActor () -> TimeInterval = { Date().timeIntervalSince1970 }) {
        self.client = client; self.held = held; self.holdReason = held ? holdReason : nil; self.synthetic = synthetic; self.trialCeiling = trialCeiling; self.now = now; self.expectedRunID = expectedRunID; self.expectedPolicyHash = expectedPolicyHash
    }
    var evidenceCurrent: Bool {
        guard let receivedAt, let authority, !authority.expired, now() < authority.deadline, authority.backend_ready else { return false }
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
        if s.trialVerified && authority?.trialActive == true && authority?.send.outcome == "accepted" { return synthetic ? .syntheticTrial : .trialVerified }
        if [.verifying, .verifyingMio].contains(s.phase) { return .verifying }
        if s.permissions.authorized && s.selection.state == "selected" { return .reviewRequired }
        return .setupRequired
    }
    // Media source capabilities are not grants; this host has no media or understanding route.
    let imageState = "not_admitted_or_verified"
    let videoState = "not_admitted_or_verified"
    let understandingState = "not_performed"
    let mioState = "external_event_unproven"

    var diagnostic: MessagesProductDiagnosticV2? {
        let statusFresh = receivedAt.map { now() >= $0 && now() - $0 < 30 } == true
            && authority != nil && !held && !interrupted
        let code = lastError ?? (statusFresh ? snapshot?.last_error : nil)
        return code.map { MessagesProductDiagnosticV2(code: Self.normalizedError($0)) }
    }
    private static func normalizedError(_ code: String) -> String {
        MessagesProductReply.codes.union(MessagesProductReply.transportCodes)
            .union(["host_not_connected", "protocol_upgrade_required"]).contains(code) ? code : "host_unavailable"
    }

    func can(_ action: MessagesProductAction) -> Bool {
        guard !held else { return false }
        if action == .cancel || action == .disable { return busy || cleanupUncertain || snapshot?.enabled == true }
        guard !busy else { return false }
        if action == .refresh { return trialCeiling.map({ now() < $0 }) ?? synthetic } // distinct from passive status
        if action == .begin {
            guard candidateVerified, !cleanupUncertain, !sendAttemptObserved,
                  trialCeiling.map({ now() < $0 }) ?? synthetic else { return false }
            if authority == nil { return snapshot == nil } // explicit verified-candidate bootstrap; status still unknown
            return evidenceCurrent && authority?.clean == true && authority?.lease.state != "active"
                && snapshot.map({ [.disabled, .failed].contains($0.phase) }) == true
        }
        guard evidenceCurrent, let s = snapshot else { return false }
        if action == .startTest {
            return s.last_error == nil && authority?.send.outcome == "unused" && !sendAttemptObserved && s.phase == .reviewTest && s.permissions.authorized && scopeApproved && selectedGroup != nil
                && review.map({ !attemptedPlans.contains($0.plan_id) && $0.scope_id == s.selection.scope_id && now() < $0.expires_at }) == true
        }
        guard panel?.actions.first(where: { $0.id == action.hostAction })?.enabled == true else { return false }
        if action == .prepareTest { return s.last_error == nil && selectedGroup != nil && !sendAttemptObserved && authority?.send.outcome == "unused" }
        if action == .begin || action == .reconnect {
            return !cleanupUncertain && authority?.clean == true && authority?.send.outcome != "consumed_unknown" && ["completed", "not_required"].contains(s.cleanup)
        }
        return true
    }
    func approveReview(_ approved: Bool) {
        scopeApproved = approved && evidenceCurrent && review != nil && selectedGroup != nil && !busy
    }
    /// Called on tab disappearance, runtime/account context change, or process interruption.
    /// This invalidates UI evidence; it does not claim to stop a host or revoke OS grants.
    func interrupt() {
        revision += 1; busy = false; interrupted = true; receivedAt = nil; authority = nil; candidateVerified = false
        candidates = []; selectedGroup = nil; review = nil; scopeApproved = false; panel = nil; snapshot = nil
    }
    func expireEvidence() {
        if !evidenceCurrent { receivedAt = nil; scopeApproved = false }
    }
    /// Only a pure snapshot: no discovery, OS observation, launch, retries or effect resumption.
    func refreshStatus() async {
        guard !held, !busy else { return }
        let token = revision; busy = true
        do {
            switch try await client.inspectCandidate() {
            case .held: throw MessagesTransportFault("activation_not_approved")
            case .verified(let run, let policy):
                guard run == expectedRunID, policy == expectedPolicyHash else { throw MessagesTransportFault("identity_changed") }
            }
            guard token == revision else { return }
            candidateVerified = true; busy = false
            await execute(.snapshot)
        } catch {
            guard token == revision else { return }
            candidateVerified = false; busy = false; authority = nil; snapshot = nil; receivedAt = nil; panel = nil; clearReview()
            lastError = Self.normalizedError((error as? MessagesTransportFault)?.code ?? "host_unavailable")
        }
    }

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
            let nativeReply = try MessagesProductReplyV2.decode(try await client.exchange(request), for: request)
            guard token == revision else { return false }
            try acceptAuthority(nativeReply.authority)
            let reply = nativeReply.core
            guard reply.ok else { throw MessagesTransportFault(reply.error!.code) }
            var statusReply = reply
            if reply.snapshot == nil {
                let status = OnboardingRequest(.snapshot)
                let nativeStatus = try MessagesProductReplyV2.decode(try await client.exchange(status), for: status)
                guard token == revision else { return false }
                try acceptAuthority(nativeStatus.authority)
                statusReply = nativeStatus.core
                guard statusReply.ok else { throw MessagesTransportFault(statusReply.error!.code) }
            }
            guard let s = statusReply.snapshot else { throw MessagesTransportFault("invalid_response") }
            if authority?.lease.state == "active" {
                guard s.session_id == authority?.lease.session_id, s.generation == authority?.lease.generation,
                      s.selection.scope_id == authority?.lease.scope_id else { throw MessagesTransportFault("invalid_evidence") }
            }
            if let oldEpoch, oldEpoch != s.epoch {
                clearReview()
                if reply.candidates != nil || reply.plan != nil { throw MessagesTransportFault("invalid_evidence") }
            }
            snapshot = s; panel = statusReply.presentation; receivedAt = now(); interrupted = false
            // Only the native durable tombstone determines lifetime consumption; generic counter is never authority.
            if authority?.send.consumed == true { sendAttemptObserved = true }
            if ["unknown", "failed"].contains(s.cleanup) || s.phase == .needsReview { cleanupUncertain = true }
            else if ["completed", "not_required"].contains(s.cleanup), authority?.clean == true { cleanupUncertain = false }
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
            lastError = Self.normalizedError(code)
            if [.cancel, .disable, .startTest].contains(command) || ["send_unknown", "cleanup_unknown", "storage_uncertain"].contains(code) {
                cleanupUncertain = true
            }
            if code != "host_not_connected" { candidateVerified = false }
            receivedAt = nil; snapshot = nil; authority = nil; panel = nil; clearReview(); busy = false
            return false
        }
    }
    private func acceptAuthority(_ next: MessagesNativeAuthorityV2?) throws {
        guard let next else { return } // error replies carry no success evidence
        guard next.run_id == expectedRunID, next.policy_sha256 == expectedPolicyHash,
              next.observed_at <= now(), now() - next.observed_at < 30,
              trialCeiling.map({ next.deadline <= $0 }) ?? synthetic else { throw MessagesTransportFault("invalid_evidence") }
        if let old = lastAuthority {
            guard next.deadline == old.deadline, next.started_at == old.started_at,
                  next.host_generation >= old.host_generation, next.revision >= old.revision,
                  next.cleanup.epoch >= old.cleanup.epoch, next.observed_at >= old.observed_at,
                  !old.send.consumed || next.send.consumed,
                  old.send.operation_id == nil || !old.send.consumed || next.send.operation_id == old.send.operation_id else { throw MessagesTransportFault("invalid_evidence") }
            if next.revision == old.revision {
                guard try MessagesJSON(next.wireValue).data == MessagesJSON(old.wireValue).data else { throw MessagesTransportFault("invalid_evidence") }
            }
            if next.host_generation != old.host_generation || next.cleanup.epoch != old.cleanup.epoch { clearReview() }
        }
        if next.send.consumed { sendAttemptObserved = true }
        if ["unknown", "in_progress"].contains(next.cleanup.state) { cleanupUncertain = true }
        authority = next; lastAuthority = next
    }
    private func clearReview() { candidates = []; selectedGroup = nil; review = nil; scopeApproved = false }
}

@MainActor @Observable final class MessagesProductFeatureV2 {
    let store: MessagesProductStoreV2
    init(home: URL, demo: Bool, isolated: Bool = false, sourceHeld: Bool = false,
         admission: MessagesProductAdmission? = nil) {
        // Admission comes only from the explicit reviewed owner. Source/demo/runtime-home
        // isolation cannot activate Messages even if that owner accidentally supplies pins.
        let reviewed = demo || isolated || sourceHeld ? nil : admission
        store = MessagesProductStoreV2(client: MessagesProductNativeClientV2(home: home, admission: reviewed),
                                     held: reviewed == nil, holdReason: demo ? .preview : isolated ? .isolated : sourceHeld ? .sourceHeld : .admissionMissing, trialCeiling: reviewed?.notAfter, expectedRunID: reviewed?.runID, expectedPolicyHash: reviewed?.policySHA256)
    }
}

/// A composition hold is not a TCC denial or evidence that a helper is installed.
enum MessagesProductHoldReasonV2: Sendable, Equatable {
    case admissionMissing, preview, isolated, sourceHeld
    var detail: String {
        switch self {
        case .admissionMissing: "信息辅助程序尚未获准接入。系统权限未知；先完成辅助程序安装与身份核验，再设置权限。"
        case .preview: "当前为演示界面，系统授权与消息操作不可用。"
        case .isolated: "当前为隔离运行，不能使用真实账户、系统授权或消息操作。"
        case .sourceHeld: "当前源码候选仍在审核，系统授权与消息操作不可用。"
        }
    }
}

/// Only bounded protocol codes reach the presentation; no backend message/content is logged.
struct MessagesProductDiagnosticV2: Sendable {
    let code: String
    let title: String
    let nextStep: String
    init(code: String) {
        self.code = code
        switch code {
        case "host_not_connected", "host_unavailable", "transport_unavailable":
            title = "未连接"
            nextStep = "确认已安装审核通过的信息辅助程序；身份核验通过后，手动开始设置。读取状态不会启动服务。"
        case "protocol_upgrade_required":
            title = "版本不符"
            nextStep = "由接入负责人核对 ARL 与信息辅助程序的版本及身份，重新审核后再连接。"
        case "activation_not_approved", "disabled":
            title = "未接入"
            nextStep = "先完成本次辅助程序与操作范围审核。系统权限不能代替接入批准。"
        case "identity_unverified", "identity_changed", "invalid_deployment", "unsafe_config", "unsafe_home", "unsafe_socket":
            title = "身份不符"
            nextStep = "由接入负责人重新核对信息辅助程序身份与安装配置；暂不为其他程序授权。"
        case "permission_required":
            title = "待核权限"
            nextStep = "基础发送核对自动化“信息”；本次群试验另含读取与结果回读，分别核对这些路径的完全磁盘访问及范围。仅发送、不读聊天的调用链尚未接入。无需联系人权限。"
        case "account_confirmation_required":
            title = "待核账户"
            nextStep = "在系统信息应用中确认登录，再手动报告。报告登录不代表 Apple 服务端状态已核验。"
        case "metadata_scope_not_approved":
            title = "群信息范围未批准"
            nextStep = "先由主会话确认最多 20 个群名称与成员的只读范围，再手动读取群组；不自动扫描正文或联系人。"
        case "group_changed", "group_not_selected":
            title = "需要重新审核群组"
            nextStep = "核对确切群与全部成员，再生成本次审核单。成员变化后不得沿用此前批准。"
        case "send_unknown", "outcome_unknown":
            title = "发送结果未知"
            nextStep = "未知发送结果会占用本次次数，不能重发。由主会话核对收件人确认及持久发送记录。"
        case "attempt_consumed", "budget_exhausted":
            title = "本次发送次数已用"
            nextStep = "取消、重连和重新生成审核单不会补充次数；保留原发送记录，不自动重发。"
        case "cleanup_unknown", "storage_uncertain":
            title = "清理尚未确认"
            nextStep = "等待负责程序确认清理；保留原有记录，不清空记录、重发或用重连补充次数。"
        case "verification_expired", "clock_rollback":
            title = "本次审核已失效"
            nextStep = "停止本次测试，交由主会话核对原截止时间与清理状态。不会自动续期。"
        case "verification_timeout", "receive_timeout":
            title = "验证尚未完成"
            nextStep = "核对本次群范围与挑战记录；超时不能证明接收或送达，也不会自动重发。"
        case "busy":
            title = "操作仍在进行"
            nextStep = "等待当前操作结束后再读取状态。"
        case "cancelled":
            title = "操作已取消"
            nextStep = "读取清理状态；收到负责程序的清理确认后再审核连接。"
        case "event_unproven", "event_attempt_consumed":
            title = "消息触发尚未验证"
            nextStep = "本次文字试验不能证明 Mio 入站或同一工作流唤醒。"
        default:
            title = "状态核验未通过"
            nextStep = "读取状态并由接入负责人核对诊断代码；当前不据此声明收发可用。"
        }
    }
}
