import Foundation
private enum CheckError: Error { case failed(String) }
private final class Repository: CredentialRepository, @unchecked Sendable {
    private let lock = NSLock()
    private var row: StoredMetadata?
    private var bytes = Data()
    private(set) var leases = 0
    func metadata(_ purpose: CredentialPurpose) throws -> StoredMetadata? { lock.withLock { row?.reference.purpose == purpose ? row : nil } }
    func create(_ input: CredentialInput, purpose: CredentialPurpose) throws -> StoredMetadata {
        try lock.withLock {
            guard row == nil else { throw CredentialError.alreadyConfigured }
            bytes = try input.copyBytes(for: purpose)
            let next = StoredMetadata(reference: .init(purpose: purpose)); row = next; return next
        }
    }
    func replace(_ ref: CredentialReference, input: CredentialInput) throws -> StoredMetadata {
        try lock.withLock {
            guard row?.reference == ref else { throw CredentialError.staleReference }
            bytes = try input.copyBytes(for: ref.purpose)
            let next = StoredMetadata(reference: ref); row = next; return next
        }
    }
    func lease(_ ref: CredentialReference) throws -> (metadata: StoredMetadata, secret: CredentialInput) {
        try lock.withLock {
            guard let row, row.reference == ref else { throw CredentialError.staleReference }
            leases += 1
            return (row, try CredentialInput(purpose: ref.purpose, data: bytes))
        }
    }
    func rotate() { lock.withLock { if let row { self.row = .init(reference: row.reference) } } }
    func record(_ ref: CredentialReference, result: ConnectionTestResult, expectedGeneration: UUID) throws -> StoredMetadata { throw CredentialError.wrongPurpose }
    func remove(_ ref: CredentialReference) throws { throw CredentialError.wrongPurpose }
}
private actor Runtime: NASConnectionRuntime {
    var connects = 0
    var stops = 0
    var connected = false
    var paused = false
    var didStart = false
    var waiter: CheckedContinuation<Void, Never>?
    var pending: CheckedContinuation<Void, Never>?
    var after: (@Sendable () -> Void)?
    var lastSecret: CredentialInput?
    func setup(paused: Bool = false, after: (@Sendable () -> Void)? = nil) { self.paused = paused; self.after = after }
    func connect(configuration: NASConnectionConfiguration, identity: NASCredentialIdentity, secret: CredentialInput) async throws -> NASRuntimeState {
        connects += 1; lastSecret = secret
        _ = try NASEnvelope.fields(secret.copyBytes(for: .nasSMB))
        didStart = true; waiter?.resume(); waiter = nil
        if paused { await withCheckedContinuation { pending = $0 } }
        after?(); connected = true
        return .init(connected: true, readable: true, epoch: "synthetic-only")
    }
    func waitStarted() async { if !didStart { await withCheckedContinuation { waiter = $0 } } }
    func status() async -> NASRuntimeState { .init(connected: connected) }
    func readDirectory() async throws -> Data { Data("{\"synthetic\":true}".utf8) }
    func stop() async { stops += 1; connected = false; pending?.resume(); pending = nil }
    func secretCleared() -> Bool {
        guard let lastSecret else { return false }
        do { _ = try lastSecret.copyBytes(for: .nasSMB); return false } catch { return true }
    }
}
@main enum NASCredentialProviderTests {
    static func main() async throws {
        var checks: [String] = []
        func check(_ value: Bool, _ name: String) throws {
            guard value else { throw CheckError.failed(name) }; checks.append(name)
        }
        let config = try NASConnectionConfiguration(sourceRef: "fixture", host: "synthetic.invalid", share: "fixture", root: "approved")
        let repo = Repository(), runtime = Runtime()
        let disabled = NASCredentialService(repository: repo, runtime: runtime)
        do { _ = try await disabled.savedIdentity(); throw CheckError.failed("disabled") }
        catch CredentialError.deploymentNotApproved {}
        try check(repo.leases == 0, "disabled_has_no_repository_lease")
        let service = NASCredentialService(repository: repo, runtime: runtime, enabled: true)
        let identity = try await service.save(configuration: config, username: "fixture-user", password: "fixture-password", replacing: nil)
        try check(identity.reference.purpose == .nasSMB && repo.leases == 0, "save_uses_separate_purpose_without_connect")
        let other = try NASConnectionConfiguration(sourceRef: "fixture", host: "other.invalid", share: "fixture", root: "approved")
        do { _ = try await service.connect(configuration: other, identity: identity); throw CheckError.failed("wrong_endpoint") }
        catch CredentialError.wrongPurpose {}
        try check(await runtime.connects == 0, "endpoint_change_rejected_before_transport")
        let result = try await service.connect(configuration: config, identity: identity)
        let cleared = await runtime.secretCleared()
        try check(result.connected && cleared, "exact_binding_connect_and_lease_cleared")
        repo.rotate()
        let rotated = await service.status()
        try check(!rotated.connected && rotated.failure == "source_changed", "rotation_closes_existing_session")
        let fresh = try await service.savedIdentity()!
        await runtime.setup(after: { repo.rotate() })
        do { _ = try await service.connect(configuration: config, identity: fresh); throw CheckError.failed("late_rotation") }
        catch CredentialError.staleReference {}
        try check(!(await runtime.connected), "rotation_during_connect_fences_success")
        let cancelRepo = Repository(), cancelRuntime = Runtime()
        let cancelService = NASCredentialService(repository: cancelRepo, runtime: cancelRuntime, enabled: true)
        let cancelID = try await cancelService.save(configuration: config, username: "fixture-user", password: "fixture-password", replacing: nil)
        await cancelRuntime.setup(paused: true)
        let task = Task { try await cancelService.connect(configuration: config, identity: cancelID) }
        await cancelRuntime.waitStarted()
        await cancelService.stop()
        do { _ = try await task.value; throw CheckError.failed("late_cancel") } catch is CancellationError {}
        try check(!(await cancelRuntime.connected), "stop_fences_late_connect")
        print(String(decoding: try JSONSerialization.data(withJSONObject: ["checks": checks, "count": checks.count,
            "production_provider": true, "real_keychain": false, "real_network": false], options: [.sortedKeys]), as: UTF8.self))
    }
}
