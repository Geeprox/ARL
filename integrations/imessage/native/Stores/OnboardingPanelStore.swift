import Foundation
import Observation

@MainActor @Observable
public final class OnboardingPanelStore {
    public private(set) var panel: OnboardingPanel
    private var pendingRequests = 0
    private var lifecycleRevision = 0
    private var statusTask: Task<Void, Never>?
    public var busy: Bool { pendingRequests > 0 }
    public private(set) var candidates: [GroupChoice] = []
    public private(set) var review: TestReview?
    public private(set) var errorCode: String?
    private let client: any MessagesOnboardingClient

    public init(panel: OnboardingPanel, client: any MessagesOnboardingClient) {
        self.panel = panel
        self.client = client
    }

    public func perform(_ command: OnboardingCommand, arguments: [String: String] = [:]) async {
        // Cancel/disable must remain usable while another request is pending.
        guard !busy || command == .cancel || command == .disable else { return }
        if command == .cancel || command == .disable {
            lifecycleRevision += 1
            statusTask?.cancel()
            statusTask = nil
        }
        let revision = lifecycleRevision
        pendingRequests += 1
        defer { pendingRequests -= 1 }
        do {
            let result = try await client.perform(OnboardingRequest(command, arguments: arguments))
            guard revision == lifecycleRevision else { return }
            guard result.schemaVersion == 1 else { errorCode = "unsupported"; return }
            guard result.ok, let next = result.presentation else {
                errorCode = result.error?.code ?? "host_unavailable"
                return
            }
            panel = next
            errorCode = next.lastError
            if let groups = result.candidates { candidates = groups }
            if let plan = result.plan { review = plan }
            if next.phase == "verifying" || next.phase == "verifying_mio", statusTask == nil {
                statusTask = Task { [weak self] in await self?.pollStatus(revision: revision) }
            }
        } catch {
            guard revision == lifecycleRevision else { return }
            // Never render raw native/SQL/process/credential diagnostics.
            errorCode = "host_unavailable"
        }
    }

    private func pollStatus(revision: Int) async {
        defer { if revision == lifecycleRevision { statusTask = nil } }
        // Pure private snapshots only, bounded beyond the controller's watchdog.
        // No account inspection, database access, automatic permission or effect retry.
        for _ in 0..<100 {
            do {
                try await Task.sleep(nanoseconds: 2_000_000_000)
                guard revision == lifecycleRevision, !Task.isCancelled else { return }
                let result = try await client.perform(OnboardingRequest(.snapshot))
                guard revision == lifecycleRevision, !Task.isCancelled else { return }
                guard result.schemaVersion == 1, result.ok, let next = result.presentation else {
                    errorCode = result.error?.code ?? "host_unavailable"
                    return
                }
                panel = next
                errorCode = next.lastError
                if next.phase != "verifying" && next.phase != "verifying_mio" { return }
            } catch {
                if revision == lifecycleRevision && !Task.isCancelled { errorCode = "host_unavailable" }
                return
            }
        }
        errorCode = "verification_timeout"
    }
}
