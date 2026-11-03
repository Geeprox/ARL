import Foundation
import AppKit
import Observation

/// Owns the single native reader. Initialization and status refresh do not open
/// the protected database; metadata discovery and scope changes are local UI acts.
@MainActor @Observable final class MessagesReceiveController {
    let enabled: Bool
    private let home: URL
    private let executor: AppleDirectExecutor
    private var service: MessagesReceiveService?
    private var loop: Task<Void, Never>?
    private var visible = false
    private var epoch = UUID()
    private var held = false
    private var actionStop: AppleDirectCancellation?
    private(set) var busy = false
    private(set) var status: MessagesReceiveStatus?
    private(set) var selections: [MessagesReceiveSelection] = []
    private(set) var nextBeforeRowID: Int64?
    private(set) var selected: MessagesReceiveSelection?
    private(set) var message: String?
    private(set) var agentTransportAvailable = false
    private(set) var agentTransportCode: String? = "not_configured"
    init(home: URL, enabled: Bool, executor: AppleDirectExecutor) { self.home = home; self.enabled = enabled; self.executor = executor }
    func appear() { visible = true; epoch = UUID() }
    func disappear() { visible = false; epoch = UUID(); actionStop?.cancel(); selections = []; selected = nil }
    private func owner() throws -> MessagesReceiveService {
        if let service { return service }
        let value = try MessagesReceiveService(home: home); service = value; status = value.status(); return value
    }
    private func begin() throws -> (UUID, AppleDirectCancellation) {
        guard enabled, visible, !held, !busy, NSApplication.shared.isActive else { throw MessagesReceiveFault("receive_local_action_required") }
        busy = true; let stop = AppleDirectCancellation(); actionStop = stop; return (epoch, stop)
    }
    private func finish() { busy = false; actionStop = nil }
    private func failure(_ error: Error) {
        let code = (error as? MessagesReceiveFault)?.code ?? (error as? AppleDirectFault)?.code ?? "receive_unavailable"
        switch code {
        case "messages_database_permission_or_availability", "messages_database_unavailable": message = "无法读取信息资料库，请核对 ARL 的完全磁盘访问权限。"
        case "unsupported_messages_schema": message = "当前信息资料库格式尚不支持，接收未开始。"
        case "receive_selection_expired": message = "会话记录已过期，请重新列出并选择。"
        case "receive_pending_delivery_requires_review": message = "原范围仍有待确认的信息，请先处理再更换。"
        case "messages_receive_scope_changed", "messages_database_changed", "messages_database_rewound": message = "账号、成员或资料库已变化，接收已暂停，请重新选择。"
        default: message = "接收未完成：" + code
        }
    }
    func loadConversations(nextPage: Bool = false) async {
        do {
            let (generation, stop) = try begin(); defer { finish() }
            let value = try owner(), before = nextPage ? nextBeforeRowID ?? .max : .max
            let page = try await executor.run { try stop.check(); return try value.selections(beforeRowID: before) }
            guard visible, generation == epoch, !held else { return }
            selections = page.entries; nextBeforeRowID = page.nextBeforeRowID; selected = nil
            message = page.excludedCount == 0 ? "已读取会话目录，请核对账号与全部成员。" : "已读取会话目录；\(page.excludedCount) 个会话因账号或成员格式不支持而未开放。"
        } catch { failure(error) }
    }
    func select(_ value: MessagesReceiveSelection) {
        guard visible, !held, !busy, selections.contains(where: { $0.source == value.source && $0.conversation == value.conversation }) else { return }
        selected = value
    }
    func start(consumerAppID: String) async {
        do {
            let (generation, stop) = try begin(); defer { finish() }
            guard agentTransportAvailable else { throw MessagesReceiveFault("receive_agent_transport_unavailable") }
            guard let selected else { throw MessagesReceiveFault("receive_scope_required") }
            let value = try owner()
            let result = try await executor.run { try stop.check(); return try value.enable(selection: selected, consumerAppID: consumerAppID) }
            guard visible, generation == epoch, !held else { value.pause(); return }
            status = result; message = "只接收此刻之后的新入站信息。"; startLoop()
        } catch { failure(error) }
    }
    func resume() async {
        do {
            let (generation, stop) = try begin(); defer { finish() }; let value = try owner()
            guard agentTransportAvailable else { throw MessagesReceiveFault("receive_agent_transport_unavailable") }
            let result = try await executor.run { try stop.check(); return try value.resumeFromNow() }
            guard visible, generation == epoch, !held else { value.pause(); return }
            status = result; message = "已从现在继续，暂停期间的消息不回溯。"; startLoop()
        } catch { failure(error) }
    }
    func loadSavedStatus() async {
        // Explicit UI action loads only ARL's own bounded state, not chat.db.
        do { let (_, _) = try begin(); defer { finish() }; status = try owner().status() } catch { failure(error) }
    }
    func stopReceiving() async {
        do {
            let (_, stop) = try begin(); defer { finish() }; let value = try owner()
            loop?.cancel(); loop = nil
            try await executor.run { try stop.check(); try value.revoke() }
            status = value.status(); message = "已停止接收，待确认信息保留在本机。"
        } catch { failure(error) }
    }
    func discardPending() async {
        do {
            let (_, stop) = try begin(); defer { finish() }; let value = try owner()
            try await executor.run { try stop.check(); try value.discardPendingAfterReview() }
            status = value.status(); message = "已清除本机待确认副本，系统信息原件未改动。"
        } catch { failure(error) }
    }
    private func startLoop() {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard await self?.captureOnce() == true else { break }
                do { try await Task.sleep(for: .seconds(2)) } catch { break }
            }
        }
    }
    private func captureOnce() async -> Bool {
        guard !held, let service, service.status().running else { return false }
        do { status = try await executor.run { try service.capture() }; return !held }
        catch { service.pause(); status = service.status(); failure(error); return false }
    }
    func suspendForExit() { held = true; epoch = UUID(); actionStop?.cancel(); loop?.cancel(); loop = nil; service?.pause(); status = service?.status() }
    func resumeAfterCancelledExit() { held = false }
    func finishExit() { suspendForExit() }
    func setAgentTransportState(available: Bool, code: String? = nil) {
        agentTransportAvailable = available; agentTransportCode = code
        if !available { loop?.cancel(); loop = nil; service?.pause(); status = service?.status() }
    }
    /// Parent connects this only to local authenticated AppRegistry consumers
    /// granted messages.receive, never to the Mio public descriptor catalog.
    func agent(method: String, parameters: Data, consumer: MessagesReceiveConsumer,
               verify: @escaping @Sendable (MessagesReceiveConsumer) throws -> Void) async throws -> Data {
        guard enabled, agentTransportAvailable, !held, !busy, let service else { throw MessagesReceiveFault("receive_scope_required") }
        busy = true; defer { busy = false }
        let result = try await executor.run {
            guard parameters.count <= 2048, let args = try JSONSerialization.jsonObject(with: parameters) as? [String: Any],
                  args.values.allSatisfy({ $0 is String }) else { throw MessagesReceiveFault("invalid_receive_request") }
            return try service.dispatch(method: method, parameters: args, consumer: consumer, verify: verify)
        }
        guard enabled, agentTransportAvailable, !held, !Task.isCancelled, service.status().enabled else { throw MessagesReceiveFault("receive_paused_or_revoked") }
        return result
    }
}
