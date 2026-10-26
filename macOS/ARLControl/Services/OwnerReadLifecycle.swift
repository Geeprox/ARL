import Foundation

/// Local lifecycle evidence only. No credential, caller policy, request replay,
/// effect target, socket path or RPC command can be supplied through this state.
final class OwnerReadLifecycle: @unchecked Sendable {
    enum Failure: String, Sendable { case identity, listener, transport, taskPending, cleanupPending }
    enum Phase: String, Sendable { case disabled, starting, listening, stopping, failed }
    struct Snapshot: Sendable {
        let phase: Phase
        let failure: Failure?
        let workerJoined: Bool
        let operationPending: Bool
        let listenerCleanupProven: Bool
        var drained: Bool { workerJoined && !operationPending && listenerCleanupProven }
        var canRequestRecovery: Bool { phase == .failed || phase == .stopping }
        static let disabled = Snapshot(phase: .disabled, failure: nil, workerJoined: true,
                                       operationPending: false, listenerCleanupProven: true)
        var title: String {
            switch phase {
            case .disabled: "尚未启用"
            case .starting: "连接中"
            case .listening: "本机就绪"
            case .stopping: "正在结束"
            case .failed: "连接故障"
            }
        }
        var detail: String {
            if operationPending && phase != .listening { return "旧请求尚未结束；结束前不会建立第二个连接。" }
            if !listenerCleanupProven && workerJoined { return "旧连接尚未确认关闭，暂时无法恢复。" }
            switch failure {
            case .identity: return "应用身份或连接配置未通过核验，请检查完整安装后手动恢复。"
            case .listener: return "本机连接端点未能建立。可手动恢复；不会移除其他进程的端点。"
            case .cleanupPending: return "旧连接尚未确认关闭，关闭后才能恢复。"
            case .taskPending: return "旧请求仍在结束，恢复会先核对其完成状态。"
            case .transport: return "本机连接意外结束，可手动恢复。"
            case nil: return "仅表示 ARL 本机连接状态，不代表供应方登录或业务操作成功。"
            }
        }
    }
    private let lock = NSLock()
    private var phase: Phase = .starting
    private var failure: Failure?
    private var workerJoined = false
    private var listenerCleanupProven = true // No listener has been created yet.
    private var operation: UUID?
    private var task: Task<Void, Never>?
    var snapshot: Snapshot {
        lock.withLock { .init(phase: phase, failure: failure, workerJoined: workerJoined,
            operationPending: operation != nil, listenerCleanupProven: listenerCleanupProven) }
    }
    func listening() {
        lock.withLock {
            listenerCleanupProven = false
            if phase == .starting { phase = .listening }
        }
    }
    func listenerClosed(cleanupProven: Bool) { lock.withLock { listenerCleanupProven = cleanupProven } }
    func fail(_ reason: Failure) { lock.withLock { failure = reason; phase = .failed } }
    func cancel() {
        let current = lock.withLock { () -> Task<Void, Never>? in
            if phase != .failed { phase = .stopping }
            return task
        }
        current?.cancel()
    }
    /// Reserve before constructing the task, so immediate completion/cancel
    /// cannot race ahead of the retained operation identity.
    func reserveOperation() -> UUID? {
        lock.withLock {
            guard phase == .listening, !workerJoined, operation == nil else { return nil }
            let token = UUID(); operation = token; return token
        }
    }
    func retain(_ work: Task<Void, Never>, for token: UUID) {
        let cancel = lock.withLock { () -> Bool in
            guard operation == token else { return true }
            task = work; return phase != .listening
        }
        if cancel { work.cancel() }
        Task.detached { [self] in
            await work.value
            lock.withLock {
                if operation == token { task = nil; operation = nil }
            }
        }
    }
    func operationEnded(_ token: UUID) -> Bool { lock.withLock { operation != token } }
    func observeWorker(_ worker: Task<Void, Never>) {
        Task.detached { [self] in
            await worker.value
            lock.withLock {
                workerJoined = true
                if phase != .failed { phase = .stopping }
            }
        }
    }
}
