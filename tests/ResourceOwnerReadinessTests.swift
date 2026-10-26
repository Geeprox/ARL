import Foundation
import Darwin

private enum FixtureFailure: Error { case check(String) }
private struct Repository: CredentialRepository {
    let musicReference = CredentialReference(purpose: .neteaseMusic)
    func metadata(_ purpose: CredentialPurpose) throws -> StoredMetadata? { nil }
    func create(_ input: CredentialInput, purpose: CredentialPurpose) throws -> StoredMetadata { throw FixtureFailure.check("unexpected_create") }
    func replace(_ ref: CredentialReference, input: CredentialInput) throws -> StoredMetadata { throw FixtureFailure.check("unexpected_replace") }
    func lease(_ ref: CredentialReference) throws -> (metadata: StoredMetadata, secret: CredentialInput) {
        let data = try MusicEnvelope.seed(appID: "SYNTHETIC", privateKey: String(repeating: "S", count: 64))
        return (.init(reference: ref), try .init(purpose: .neteaseMusic, data: data))
    }
    func record(_ ref: CredentialReference, result: ConnectionTestResult, expectedGeneration: UUID) throws -> StoredMetadata { throw FixtureFailure.check("unexpected_record") }
    func remove(_ ref: CredentialReference) throws { throw FixtureFailure.check("unexpected_remove") }
}
private actor HeldValidator: CredentialValidator {
    private var continuation: CheckedContinuation<Void, Never>?
    var waiting: Bool { continuation != nil }
    func validate(_ secret: CredentialInput, purpose: CredentialPurpose, deadline: ContinuousClock.Instant) async -> ConnectionTestResult {
        await withCheckedContinuation { continuation = $0 }
        return .init(.credentialUnconfirmed)
    }
    func release() { continuation?.resume(); continuation = nil }
}
private final class HeldMusic: MusicTransport, MusicProcessBarrier, @unchecked Sendable {
    let generation = UUID()
    private let lock = NSLock()
    private var status: MusicCleanupStatus
    init() { status = .init(phase: .idle, generation: nil, lastReapedGeneration: nil) }
    func cleanupStatus() -> MusicCleanupStatus { lock.withLock { status } }
    func reaped(_ id: UUID) { lock.withLock { status = .init(phase: .idle, generation: nil, lastReapedGeneration: id) } }
    func send(_ secret: CredentialInput, operation: MusicOperation, onLoginURL: @escaping @Sendable (URL) -> Void) async throws -> MusicRuntimeResult {
        lock.withLock { status = .init(phase: .cleanupUnproven, generation: generation, lastReapedGeneration: nil) }
        throw MusicReadRuntimeFailure.cleanupUnproven
    }
}
@main enum ResourceOwnerReadinessTests {
    static func check(_ value: Bool, _ label: String) throws { if !value { throw FixtureFailure.check(label) } }
    static func rejects(_ label: String, _ action: () throws -> Void) throws {
        do { try action() } catch { return }; throw FixtureFailure.check(label)
    }
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else { throw FixtureFailure.check("owned_root_required") }
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let app = root.appendingPathComponent("Synthetic.app")
        let resources = app.appendingPathComponent("Contents/Resources/ServiceRuntime")
        let fm = FileManager.default
        try fm.createDirectory(at: resources, withIntermediateDirectories: true)
        var inventory: [String: [String: Any]] = [:]
        for (name, data, mode) in [("Runtime/node", Data("inert-node".utf8), 0o555),
                                  ("NetEase/dist/index.js", Data("inert-cli".utf8), 0o444),
                                  ("Bridge/netease_bridge.cjs", Data(repeating: 65, count: 140*1024), 0o444)] {
            let url = resources.appendingPathComponent(name)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url); try check(chmod(url.path, mode_t(mode)) == 0, "resource_mode")
            inventory[name] = ["bytes": data.count, "sha256": MusicRuntimeResources.hash(data), "mode": mode]
        }
        let manifest = try JSONSerialization.data(withJSONObject: inventory, options: .sortedKeys)
        try manifest.write(to: resources.appendingPathComponent("inventory.json"))
        let info: [String: Any] = ["CFBundleIdentifier":"local.synthetic.r5", "CFBundlePackageType":"APPL",
            "ARLServiceRuntimeManifestSHA256":MusicRuntimeResources.hash(manifest), "ARLServiceRuntimeManifestBytes":manifest.count]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        guard let bundle = Bundle(url: app) else { throw FixtureFailure.check("fixture_bundle") }
        _ = try MusicRuntimeResources.verify(bundle: bundle)
        try check(MusicRuntimeResources.integer(true) == nil, "bool_is_not_length")
        var wrong = inventory; wrong["Bridge/netease_bridge.cjs"]?["bytes"] = 140*1024-1
        try rejects("wrong_size") { _ = try MusicRuntimeResources.verified(root: resources, name: "Bridge/netease_bridge.cjs", manifest: wrong) }
        wrong = inventory; wrong["Bridge/netease_bridge.cjs"]?["sha256"] = String(repeating: "0", count: 64)
        try rejects("wrong_hash") { _ = try MusicRuntimeResources.verified(root: resources, name: "Bridge/netease_bridge.cjs", manifest: wrong) }
        let bridge = resources.appendingPathComponent("Bridge/netease_bridge.cjs")
        try check(chmod(bridge.path, 0o644) == 0, "change_mode")
        try rejects("writable_resource") { _ = try MusicRuntimeResources.verify(bundle: bundle) }
        try check(chmod(bridge.path, 0o444) == 0, "restore_mode")
        try fm.moveItem(at: bridge, to: bridge.appendingPathExtension("original"))
        try fm.createSymbolicLink(atPath: bridge.path, withDestinationPath: "netease_bridge.cjs.original")
        try rejects("symlink_resource") { _ = try MusicRuntimeResources.verify(bundle: bundle) }
        try rejects("wrong_manifest_length") { _ = try MusicRuntimeResources.read(root: resources, relative: "inventory.json", bytes: manifest.count + 1) }

        // R12: no recovery while validation or the exact previous process
        // generation remains pending. Only synthetic repository/transports.
        let repository = Repository(), validator = HeldValidator(), music = HeldMusic()
        let owner = CredentialOnboarding(repository: repository, validator: validator, music: music)
        try check(await owner.ownerRecoveryReadiness() == .ready, "initial_ready")
        let validation = Task {
            try await owner.saveAndVerify(CredentialInput(purpose: .amapMapsWeather, data: Data("synthetic-key".utf8)), purpose: .amapMapsWeather)
        }
        let end = ContinuousClock.now.advanced(by: .seconds(2))
        while !(await validator.waiting) && ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(2)) }
        try check(await validator.waiting, "validator_started")
        try check(await owner.ownerRecoveryReadiness() == .busy, "validation_busy")
        await validator.release(); _ = try await validation.value
        try check(await owner.ownerRecoveryReadiness() == .ready, "validation_joined")
        do { _ = try await owner.performMusic(repository.musicReference, operation: .status); throw FixtureFailure.check("cleanup_not_held") }
        catch let fault as MusicReadRuntimeFailure { try check(fault == .cleanupUnproven, "expected_cleanup_fault") }
        try check(await owner.ownerRecoveryReadiness() == .cleanupUnproven, "cleanup_blocks")
        music.reaped(UUID())
        try check(await owner.ownerRecoveryReadiness() == .cleanupUnproven, "other_generation_cannot_release")
        music.reaped(music.generation)
        try check(await owner.ownerRecoveryReadiness() == .ready, "exact_generation_releases")
        print("{\"status\":\"PASS\",\"groups\":[\"R01_inventory_sizes_and_integrity\",\"R12_sdk_busy_and_exact_cleanup\"],\"real_keychain\":0,\"real_provider\":0,\"executed_resources\":0}")
    }
}
