import Foundation

private enum FixtureFailure: Error { case check(String) }
private final class Counters: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}
private final class TravelRepository: CredentialRepository, @unchecked Sendable {
    private let lock = NSLock()
    private var row: StoredMetadata?
    private var value = "SYNTHETIC-OLD-KEY"
    private var commits = 0
    init(row: StoredMetadata? = nil) { self.row = row }
    func metadata(_ purpose: CredentialPurpose) throws -> StoredMetadata? { lock.withLock { row } }
    func recoverTravelMetadata(_ purpose: CredentialPurpose) throws -> StoredMetadata? { try metadata(purpose) }
    func create(_ input: CredentialInput, purpose: CredentialPurpose) throws -> StoredMetadata { throw CredentialError.deploymentNotApproved }
    func replace(_ ref: CredentialReference, input: CredentialInput) throws -> StoredMetadata { throw CredentialError.deploymentNotApproved }
    func lease(_ ref: CredentialReference) throws -> (metadata: StoredMetadata, secret: CredentialInput) { throw CredentialError.deploymentNotApproved }
    func record(_ ref: CredentialReference, result: ConnectionTestResult, expectedGeneration: UUID) throws -> StoredMetadata { throw CredentialError.deploymentNotApproved }
    func remove(_ ref: CredentialReference) throws { throw CredentialError.deploymentNotApproved }
    func installVerifiedTravel(_ input: CredentialInput, result: ConnectionTestResult, expected: StoredMetadata?) throws -> StoredMetadata {
        defer { input.clear() }
        return try lock.withLock {
            guard row == expected else { throw CredentialError.staleReference }
            guard TravelCredentialEvidence.accepts(result, purpose: input.purpose) else { throw CredentialError.wrongPurpose }
            value = String(data: try input.copyBytes(for: input.purpose), encoding: .utf8)!
            let next = StoredMetadata(reference: expected?.reference ?? .init(purpose: input.purpose), state: .verified, lastTest: result)
            row = next; commits += 1; return next
        }
    }
    func rotate() { lock.withLock { if let row { self.row = .init(reference: row.reference) } } }
    var commitCount: Int { lock.withLock { commits } }
    var oldValueRetained: Bool { lock.withLock { value == "SYNTHETIC-OLD-KEY" } }
}
private struct TravelValidator: CredentialValidator {
    let state: ConnectionState
    let evidence: ValidationEvidence
    let after: (@Sendable () -> Void)?
    init(_ state: ConnectionState = .verified, evidence: ValidationEvidence = .amapWeatherResponse, after: (@Sendable () -> Void)? = nil) {
        self.state = state; self.evidence = evidence; self.after = after
    }
    func validate(_ secret: CredentialInput, purpose: CredentialPurpose, deadline: ContinuousClock.Instant) async -> ConnectionTestResult {
        defer { secret.clear() }; after?()
        return .init(state, evidence: evidence)
    }
}
private struct TravelSource: LegacyTravelSource {
    let reads: Counters
    var changed = false
    func inspect(_ purpose: CredentialPurpose) throws -> LegacyTravelStatus { .available }
    func read(_ purpose: CredentialPurpose) throws -> LegacyTravelLease {
        reads.increment()
        let changed = self.changed
        return .init(secret: try CredentialInput(purpose: purpose, value: "SYNTHETIC-LEGACY-KEY"), check: {
            if changed { throw CredentialError.uncertainLocalState }
        })
    }
}
private struct FixtureGate: DeploymentGate { func verify() throws {} }
@main @MainActor enum TravelMigrationTests {
    static func main() async throws {
        var checks: [String] = []
        func check(_ value: Bool, _ name: String) throws { guard value else { throw FixtureFailure.check(name) }; checks.append(name) }
        let purpose = CredentialPurpose.amapMapsWeather
        let old = StoredMetadata(reference: .init(purpose: purpose), state: .verified,
                                 lastTest: .init(.verified, evidence: .amapWeatherResponse))
        for failure in [ConnectionState.invalidOrExpired, .quotaExceeded, .networkUnavailable, .timedOut, .cancelled] {
            let repo = TravelRepository(row: old)
            let service = CredentialOnboarding(repository: repo, validator: TravelValidator(failure, evidence: .none))
            let result = try await service.saveAndVerify(CredentialInput(purpose: purpose, value: "SYNTHETIC-NEW-KEY"), purpose: purpose, replacing: old.reference)
            try check(!result.saved && repo.commitCount == 0 && repo.oldValueRetained && result.snapshot.reference == old.reference,
                      "validation_failure_preserves_old_" + failure.rawValue)
            try check(result.message.contains("未切换") && !result.message.contains("已保存"), "honest_not_saved_" + failure.rawValue)
        }
        let replacement = TravelRepository(row: old)
        let replaceService = CredentialOnboarding(repository: replacement, validator: TravelValidator())
        let replaced = try await replaceService.saveAndVerify(CredentialInput(purpose: purpose, value: "SYNTHETIC-NEW-KEY"), purpose: purpose, replacing: old.reference)
        try check(replaced.saved && replacement.commitCount == 1 && !replacement.oldValueRetained && replaced.snapshot.reference == old.reference,
                  "verified_replacement_single_commit")
        let raced = TravelRepository(row: old)
        let raceService = CredentialOnboarding(repository: raced, validator: TravelValidator(after: { raced.rotate() }))
        var stale = false
        do { _ = try await raceService.saveAndVerify(CredentialInput(purpose: purpose, value: "SYNTHETIC-NEW-KEY"), purpose: purpose, replacing: old.reference) }
        catch CredentialError.staleReference { stale = true }
        try check(stale && raced.commitCount == 0 && raced.oldValueRetained, "concurrent_generation_rejected")
        let cancelledRepo = TravelRepository(row: old)
        let cancelledService = CredentialOnboarding(repository: cancelledRepo, validator: TravelValidator(after: {
            withUnsafeCurrentTask { $0?.cancel() }
        }))
        let cancelledTask = Task {
            try await cancelledService.saveAndVerify(CredentialInput(purpose: purpose, value: "SYNTHETIC-NEW-KEY"), purpose: purpose, replacing: old.reference)
        }
        var cancelled = false
        do { _ = try await cancelledTask.value } catch is CancellationError { cancelled = true }
        try check(cancelled && cancelledRepo.commitCount == 0 && cancelledRepo.oldValueRetained, "cancelled_validation_never_commits")
        let wrongEvidence = TravelRepository()
        let flyService = CredentialOnboarding(repository: wrongEvidence, validator: TravelValidator(evidence: .flyaiReadOnlyResponse))
        let unconfirmed = try await flyService.saveAndVerify(CredentialInput(purpose: .fliggyTravelReadOnly, value: "SYNTHETIC-FLYAI-KEY"), purpose: .fliggyTravelReadOnly)
        try check(!unconfirmed.saved && wrongEvidence.commitCount == 0, "flyai_requires_differential_evidence")
        let readCounts = Counters(), migrating = TravelRepository()
        let migration = CredentialOnboarding(repository: migrating, validator: TravelValidator(), legacyTravel: TravelSource(reads: readCounts))
        _ = await migration.legacyTravelStatus(purpose: purpose)
        try check(readCounts.count == 0, "presence_never_reads_source_value")
        let imported = try await migration.migrateLegacyTravel(purpose: purpose)
        try check(imported.saved && imported.snapshot.state == .verified && readCounts.count == 1 && migrating.commitCount == 1,
                  "explicit_migration_verified_before_commit")
        var duplicate = false
        do { _ = try await migration.migrateLegacyTravel(purpose: purpose) } catch CredentialError.alreadyConfigured { duplicate = true }
        try check(duplicate && readCounts.count == 1 && migrating.commitCount == 1, "existing_owner_blocks_source_read_and_replay")
        _ = try await migration.recoverTravelSave(purpose: purpose)
        try check(readCounts.count == 1 && migrating.commitCount == 1, "recovery_never_replays_or_reads_source")
        let changed = TravelRepository(), changeReads = Counters()
        let changeService = CredentialOnboarding(repository: changed, validator: TravelValidator(), legacyTravel: TravelSource(reads: changeReads, changed: true))
        var rejected = false
        do { _ = try await changeService.migrateLegacyTravel(purpose: purpose) } catch CredentialError.uncertainLocalState { rejected = true }
        try check(rejected && changed.commitCount == 0, "source_change_rejected_after_validation")
        // Native filesystem reader with synthetic fixtures only. No Keychain,
        // actual user source, signed identity, network or product installation.
        // Foundation may choose the Darwin /var temporary alias despite
        // TMPDIR. The production reader correctly rejects that symlink.
        // Use the explicitly supplied private fixture root, with no fallback.
        guard let syntheticRoot = ProcessInfo.processInfo.environment["TMPDIR"], syntheticRoot.hasPrefix("/"),
              URL(fileURLWithPath: syntheticRoot).lastPathComponent == "synthetic-tmp" else {
            throw FixtureFailure.check("private_synthetic_tmpdir_required")
        }
        let home = URL(fileURLWithPath: syntheticRoot, isDirectory: true)
            .appendingPathComponent("arl-travel-fixture-" + UUID().uuidString)
        let parent = home.appendingPathComponent("Library/Application Support/MioReadOnly")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let file = parent.appendingPathComponent("amap.json")
        try Data("{\"AMAP_MAPS_API_KEY\":\"SYNTHETIC-LEGACY-KEY\"}".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        // Use a private temporary root without a /tmp symlink component.
        let source = NativeLegacyTravelSource(gate: FixtureGate(), home: home.resolvingSymlinksInPath())
        // Fixed synthetic stages expose only this fixture's path/metadata on
        // failure. No source value or arbitrary error description is printed.
        func sourceStage<T>(_ stage: String, _ operation: () throws -> T) throws -> T {
            do { return try operation() }
            catch {
                let resolved = home.resolvingSymlinksInPath()
                var directory = URL(fileURLWithPath: "/", isDirectory: true)
                var ancestors: [[String: Any]] = []
                for part in resolved.path.split(separator: "/") {
                    directory.appendPathComponent(String(part), isDirectory: true)
                    if let attributes = try? FileManager.default.attributesOfItem(atPath: directory.path),
                       let mode = attributes[.posixPermissions] as? NSNumber,
                       let owner = attributes[.ownerAccountID] as? NSNumber {
                        ancestors.append(["path": directory.path, "mode": mode.intValue,
                            "owner": owner.intValue, "group_or_other_writable": mode.intValue & 0o022 != 0])
                    }
                }
                let report: [String: Any] = ["status": "FAIL", "phase": stage,
                    "error": error as? CredentialError == .uncertainLocalState ? "uncertainLocalState" : "other",
                    "synthetic_home": resolved.path,
                    "configured_synthetic_tmpdir": ProcessInfo.processInfo.environment["TMPDIR"] ?? "missing",
                    "ancestors": ancestors]
                if let encoded = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) {
                    FileHandle.standardOutput.write(encoded + Data([10]))
                }
                throw error
            }
        }
        let lease = try sourceStage("source_read") { try source.read(purpose) }; lease.secret.clear()
        try sourceStage("lease_verify_unchanged") { try lease.verifyUnchanged() }
        try check(try sourceStage("source_inspect") { try source.inspect(purpose) } == .available, "private_regular_source_accepted")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        var privateRejected = false
        do { _ = try source.read(purpose) } catch { privateRejected = true }
        try check(privateRejected, "public_source_permissions_rejected")
        let encoded = try JSONEncoder().encode(imported.snapshot)
        try check(!String(decoding: encoded, as: UTF8.self).contains("SYNTHETIC"), "snapshot_contains_no_source_value")
        print(String(decoding: try JSONSerialization.data(withJSONObject: ["status":"PASS", "checks":checks,
            "real_network_calls":0, "real_credential_reads":0, "real_keychain_calls":0, "installed_changes":0], options: [.sortedKeys]), as: UTF8.self))
    }
}
