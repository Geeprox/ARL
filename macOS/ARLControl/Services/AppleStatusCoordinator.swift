import AppKit
import Foundation
import Observation

/// A small app-owned poller, not a second connection/execution service. The
/// injected probe has no permission-request or business-effect interface.
@MainActor @Observable final class AppleStatusCoordinator<Value: Equatable & Sendable> {
    private(set) var state: AppleConnectionState<Value>
    @ObservationIgnored private let enabled: Bool
    @ObservationIgnored private let probe: @MainActor () async throws -> Value
    @ObservationIgnored private let persist: @MainActor (Value, Date) -> Void
    @ObservationIgnored private let uptime: @MainActor () -> TimeInterval
    @ObservationIgnored private let date: @MainActor () -> Date
    @ObservationIgnored private let foreground: @MainActor () -> Bool
    @ObservationIgnored private var polling: Task<Void, Never>?
    @ObservationIgnored private var inFlight: (id: UUID, task: Task<Void, Never>)?
    @ObservationIgnored private var epoch = UUID()
    @ObservationIgnored private var paused = false
    @ObservationIgnored private var stopped = false
    @ObservationIgnored private var failures = 0
    @ObservationIgnored private var nextRefresh: TimeInterval = 0
    private let foregroundInterval: TimeInterval
    private let backgroundInterval: TimeInterval

    init(enabled: Bool, initial: AppleConnectionState<Value> = .init(),
         foregroundInterval: TimeInterval = 30, backgroundInterval: TimeInterval = 120,
         uptime: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         date: @escaping @MainActor () -> Date = { Date() },
         foreground: @escaping @MainActor () -> Bool = { NSApplication.shared.isActive },
         persist: @escaping @MainActor (Value, Date) -> Void = { _, _ in },
         startAutomatically: Bool = true,
         probe: @escaping @MainActor () async throws -> Value) {
        self.enabled = enabled; state = initial; self.probe = probe; self.persist = persist
        self.uptime = uptime; self.date = date; self.foreground = foreground
        self.foregroundInterval = foregroundInterval; self.backgroundInterval = backgroundInterval
        if startAutomatically { start() }
    }
    deinit { polling?.cancel(); inFlight?.task.cancel() }
    func start() {
        guard enabled, polling == nil, !stopped else { return }
        polling = Task { @MainActor [weak self] in
            await self?.refresh()
            while !Task.isCancelled {
                guard let delay = self?.delay else { return }
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                guard !Task.isCancelled else { return }
                await self?.refresh()
            }
        }
    }
    private var delay: TimeInterval {
        paused ? foregroundInterval : max(0.1, min(nextRefresh - uptime(), foregroundInterval))
    }
    func refresh(force: Bool = false) async {
        guard enabled, !paused, !stopped else { return }
        if let pending = inFlight { await pending.task.value; return }
        guard force || uptime() >= nextRefresh else { return }
        let id = UUID(), generation = epoch
        state.refreshing = true; state.lastAttemptAt = date()
        let work = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let value = try await probe()
                guard !Task.isCancelled, epoch == generation, !paused, !stopped else { return }
                accept(value)
            } catch {
                guard !Task.isCancelled, epoch == generation, !paused, !stopped else { return }
                state.refreshing = false
                state.lastFailure = error as? AppleStatusProbeFailure ?? .init(.probeUnavailable)
                failures = min(failures + 1, 5)
                nextRefresh = uptime() + [5.0, 15, 30, 60, 120][failures - 1]
            }
        }
        inFlight = (id, work)
        await work.value
        if inFlight?.id == id { inFlight = nil }
    }
    func accept(_ value: Value) {
        guard enabled, !stopped else { return }
        let now = date(); state.accept(value, at: now); failures = 0
        nextRefresh = uptime() + (foreground() ? foregroundInterval : backgroundInterval)
        persist(value, now)
    }
    /// Explicit foreground consent owns its own result; a queued old silent
    /// observation cannot overwrite it when the system prompt eventually returns.
    func pause() {
        paused = true; epoch = UUID(); inFlight?.task.cancel(); inFlight = nil
        state.refreshing = false
    }
    func resume() {
        paused = false; polling?.cancel(); polling = nil; start()
    }
    func stop() {
        stopped = true; epoch = UUID(); polling?.cancel(); polling = nil
        inFlight?.task.cancel(); inFlight = nil; state.refreshing = false
    }
}
