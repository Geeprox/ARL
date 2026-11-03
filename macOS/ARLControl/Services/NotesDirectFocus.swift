import Foundation
import AppKit

/// One native Button intent may request activation once. A notification is only
/// evidence when the app is actually active and the original page/target gate
/// is still current. This helper never reads Notes or issues an action ticket.
@MainActor final class NotesDirectFocusAttempt {
    enum Outcome: Equatable, Sendable { case confirmed, timedOut, cancelled, invalidated }
    enum Phase: Equatable { case idle, waiting, finished(Outcome) }
    private(set) var phase: Phase = .idle
    private let center: NotificationCenter
    private let object: AnyObject?
    private let isActive: @MainActor () -> Bool
    private let isCurrent: @MainActor () -> Bool
    private let activate: @MainActor () -> Void
    private let timeout: TimeInterval
    private let now: @MainActor () -> TimeInterval
    private var deadline: TimeInterval?
    private var observer: (any NSObjectProtocol)?
    private var timer: Task<Void, Never>?
    private var continuation: CheckedContinuation<Outcome, Never>?
    private var outcome: Outcome?
    init(center: NotificationCenter = .default, object: AnyObject? = nil,
         timeout: TimeInterval = 1.5,
         now: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         isActive: @escaping @MainActor () -> Bool,
         isCurrent: @escaping @MainActor () -> Bool,
         activate: @escaping @MainActor () -> Void) {
        precondition(timeout.isFinite && timeout > 0 && timeout <= 5)
        self.center = center; self.object = object; self.timeout = timeout; self.now = now
        self.isActive = isActive; self.isCurrent = isCurrent; self.activate = activate
    }
    /// Called synchronously on the actual Button action stack, not by a status
    /// refresh, onAppear, timer, owner RPC or a synthesized permission flag.
    func startAfterClick() {
        guard phase == .idle else { return }
        deadline = now() + timeout
        guard isCurrent() else { finish(.invalidated); return }
        if isActive() { finish(.confirmed); return }
        phase = .waiting
        observer = center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: object, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.activationObserved() }
        }
        timer = Task { @MainActor [weak self, timeout] in
            do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
            guard let self else { return }
            finish(isCurrent() ? .timedOut : .invalidated)
        }
        activate()
    }
    private func activationObserved() {
        guard phase == .waiting else { return }
        guard isCurrent() else { finish(.invalidated); return }
        guard let deadline, now() < deadline else { finish(.timedOut); return }
        guard isActive() else { return }
        finish(.confirmed)
    }
    func wait() async -> Outcome {
        if Task.isCancelled { cancel(); return .cancelled }
        if let outcome { return outcome }
        guard phase == .waiting else { return .invalidated }
        if let deadline, now() >= deadline { finish(.timedOut); return .timedOut }
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { waiting in
                if let outcome { waiting.resume(returning: outcome) }
                else { continuation = waiting }
            }
        }, onCancel: { [weak self] in
            guard let attempt = self else { return }
            Task { @MainActor [attempt] in attempt.cancel() }
        })
    }
    var confirmationStillValid: Bool {
        guard outcome == .confirmed, let deadline else { return false }
        return isCurrent() && isActive() && now() < deadline
    }
    func cancel() { finish(.cancelled) }
    func close() {
        if outcome == nil { finish(.cancelled) }
        removeObservation()
    }
    private func finish(_ value: Outcome) {
        guard outcome == nil else { return }
        outcome = value; phase = .finished(value)
        removeObservation()
        continuation?.resume(returning: value); continuation = nil
    }
    private func removeObservation() {
        timer?.cancel(); timer = nil
        if let observer { center.removeObserver(observer); self.observer = nil }
    }
}
