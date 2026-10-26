import Foundation

// SYNTHETIC SOURCE FIXTURE ONLY. Not a registered host, provider or app entry.
// Its verified facts are deliberately fake. No test in this file has been run.
// A later owner may compile these three Swift sources serially and call run().
public enum ARLNASSyntheticCheck: String, CaseIterable, Hashable {
    case defaultUnsupported, oneShotExactRequest, exactConnectAdvance, exactRead
    case restartAfterStop, changedScopeRejected, stopAvailableWhileBusy
    case cleanupWaitsForOldWork, lateReadCannotRestoreAccess
}

public struct ARLNASSyntheticReport {
    public let checks: [ARLNASSyntheticCheck: Bool]
    public var allPassed: Bool {
        ARLNASSyntheticCheck.allCases.allSatisfy { checks[$0] == true }
    }
}

@MainActor
public enum ARLNASSetupModelSyntheticChecks {
    public static func run() async throws -> ARLNASSyntheticReport {
        var checks: [ARLNASSyntheticCheck: Bool] = [:]
        let unavailable = ARLNASSetupModel()
        checks[.defaultUnsupported] = unavailable.snapshot.provider == .unsupported
            && !unavailable.admission(for: .saveCredential).isAllowed
            && !unavailable.admission(for: .testWrite).isAllowed
            && unavailable.fact(for: .connected) != .verified

        let backend = try ARLNASSyntheticBackend()
        let model = ARLNASSetupModel(backend: backend)
        guard let connect = model.beginManualActionAfterClick(.testConnection) else {
            return ARLNASSyntheticReport(checks: checks)
        }
        await model.performAfterClick(connect)
        checks[.oneShotExactRequest] = !connect.consume(for: connect.request)
        checks[.exactConnectAdvance] = model.lastFault == nil
            && connect.request.readScope?.configGeneration == 1
            && model.snapshot.readScope?.configGeneration == 2
            && model.fact(for: .connected) == .verified

        if let read = model.beginManualActionAfterClick(.testRead) {
            let before = model.snapshot.readScope
            await model.performAfterClick(read)
            checks[.exactRead] = model.lastFault == nil && model.snapshot.readScope == before
                && model.fact(for: .readable) == .verified
        }
        if let stop = model.beginManualActionAfterClick(.stop) {
            await model.performAfterClick(stop)
        }
        // Stop advances current manager generation but preserves old admission.
        let stoppedHasOldAdmission = model.snapshot.currentConfigurationGeneration == 3
            && model.snapshot.readScope?.configGeneration == 2
            && model.snapshot.connectionEpoch == nil
        if let restart = model.beginManualActionAfterClick(.testConnection) {
            await model.performAfterClick(restart)
            checks[.restartAfterStop] = stoppedHasOldAdmission && model.lastFault == nil
                && restart.request.expectedConfigurationGeneration == 3
                && model.snapshot.readScope?.configGeneration == 4
                && model.fact(for: .connected) == .verified
        }

        let changedBackend = try ARLNASSyntheticBackend()
        changedBackend.changeNextFingerprint = true
        let changed = ARLNASSetupModel(backend: changedBackend)
        if let connectChanged = changed.beginManualActionAfterClick(.testConnection) {
            await changed.performAfterClick(connectChanged)
            checks[.changedScopeRejected] = changed.lastFault == .bindingMismatch
                && changed.fact(for: .connected) != .verified
        }

        backend.holdNextRead = true
        guard let occupiedRead = model.beginManualActionAfterClick(.testRead) else {
            return ARLNASSyntheticReport(checks: checks)
        }
        let readTask = Task { await model.performAfterClick(occupiedRead) }
        for _ in 0..<64 {
            if backend.hasHeldRead { break }
            await Task.yield()
        }
        checks[.stopAvailableWhileBusy] = backend.hasHeldRead && model.isPerforming
            && model.admission(for: .stop).isAllowed
        guard backend.hasHeldRead else {
            readTask.cancel()
            await readTask.value
            return ARLNASSyntheticReport(checks: checks)
        }
        // Matches the panel: cancel first, then capture a separate manual Stop.
        readTask.cancel()
        if let stop = model.beginManualActionAfterClick(.stop) {
            await model.performAfterClick(stop)
        }
        checks[.cleanupWaitsForOldWork] = model.cleanupPending && model.isPerforming
            && model.snapshot.connectionEpoch == nil
        backend.releaseHeldRead()
        await readTask.value
        checks[.lateReadCannotRestoreAccess] = !model.cleanupPending && !model.isPerforming
            && model.snapshot.connectionEpoch == nil
            && model.fact(for: .connected) != .verified && model.fact(for: .readable) != .verified
        return ARLNASSyntheticReport(checks: checks)
    }
}

@MainActor
private final class ARLNASSyntheticBackend: ARLNASSetupBackend {
    var changeNextFingerprint = false
    var holdNextRead = false
    private(set) var hasHeldRead = false
    private let configuration: ARLNASConfiguration
    private let caller: ARLNASObservedCallerPins
    private var cache: ARLNASSetupSnapshot
    private var heldContinuation: CheckedContinuation<ARLNASActionReply, Never>?
    private var heldReply: ARLNASActionReply?

    init() throws {
        configuration = try ARLNASConfiguration(address: "synthetic.invalid", transport: .smb,
            share: "synthetic_share", root: "", applicationScope: .readOnly,
            advanced: ARLNASAdvancedOptions())
        let zero = try ARLNASSHA256Digest(String(repeating: "0", count: 64))
        caller = ARLNASObservedCallerPins(executableDigest: zero,
            designatedRequirementDigest: zero,
            registrationEpoch: try ARLNASOpaqueReference("synthetic_epoch_1"))
        let scope = try ARLNASReadScope(sourceRef: ARLNASOpaqueReference("synthetic_source"),
            credentialRef: ARLNASOpaqueReference("synthetic_entry"), configFingerprint: zero,
            rootDescriptorDigest: zero, configGeneration: 1,
            credentialGeneration: ARLNASCredentialGeneration(String(repeating: "a", count: 32)))
        cache = ARLNASSetupSnapshot(revision: 1, provider: .available,
            availability: Self.availability, configuration: configuration,
            currentConfigurationGeneration: 1, readScope: scope, observedCallerPins: caller,
            configurationSaved: .verified, credentialReferenceSaved: .verified)
    }

    func cachedSnapshot() -> ARLNASSetupSnapshot { cache }

    func perform(_ request: ARLNASActionRequest,
                 manualIntent: ARLNASManualIntent) async -> ARLNASActionReply {
        guard manualIntent.consume(for: request) else {
            return ARLNASActionReply(request: request, outcome: .held(.manualIntentRequired), snapshot: cache)
        }
        switch request.action {
        case .testConnection, .reconnect:
            do {
                let generation = request.expectedConfigurationGeneration + 1
                let fingerprint = changeNextFingerprint
                    ? try ARLNASSHA256Digest(String(repeating: "1", count: 64)) : nil
                changeNextFingerprint = false
                let scope = try makeScope(generation: generation, fingerprint: fingerprint)
                cache = ARLNASSetupSnapshot(revision: cache.revision + 1, provider: .available,
                    availability: Self.availability, configuration: configuration,
                    currentConfigurationGeneration: generation, readScope: scope,
                    observedCallerPins: caller,
                    connectionEpoch: try ARLNASOpaqueReference("synthetic_session_\(generation)"),
                    configurationSaved: .verified, credentialReferenceSaved: .verified,
                    credentialAvailable: .verified, connected: .verified, readable: .verified)
            } catch {
                return ARLNASActionReply(request: request, outcome: .failed(.bindingMismatch), snapshot: cache)
            }
        case .testRead:
            if holdNextRead {
                holdNextRead = false
                let latePositiveReply = ARLNASActionReply(request: request, outcome: .applied, snapshot: cache)
                return await withCheckedContinuation { continuation in
                    hasHeldRead = true
                    heldReply = latePositiveReply
                    heldContinuation = continuation
                }
            }
        case .stop:
            cache = ARLNASSetupSnapshot(revision: cache.revision + 1, provider: .held,
                availability: Self.availability, configuration: configuration,
                currentConfigurationGeneration: cache.currentConfigurationGeneration + 1,
                readScope: cache.readScope, observedCallerPins: caller,
                configurationSaved: .verified, credentialReferenceSaved: .verified,
                credentialAvailable: .held(.disabled), connected: .held(.disabled), readable: .held(.disabled))
        case .testWrite, .saveCredential, .saveConfiguration:
            return ARLNASActionReply(request: request, outcome: .unsupported(.nativeNASPurposeUnavailable), snapshot: cache)
        }
        return ARLNASActionReply(request: request, outcome: .applied, snapshot: cache)
    }

    func releaseHeldRead() {
        guard let continuation = heldContinuation, let reply = heldReply else { return }
        heldContinuation = nil
        heldReply = nil
        hasHeldRead = false
        continuation.resume(returning: reply)
    }

    private func makeScope(generation: UInt64, fingerprint: ARLNASSHA256Digest?) throws -> ARLNASReadScope {
        guard let previous = cache.readScope else { throw ARLNASFault.bindingMismatch }
        return try ARLNASReadScope(sourceRef: previous.sourceRef, credentialRef: previous.credentialRef,
            configFingerprint: fingerprint ?? previous.configFingerprint,
            rootDescriptorDigest: previous.rootDescriptorDigest, configGeneration: generation,
            credentialGeneration: previous.credentialGeneration)
    }

    private static var availability: ARLNASActionAvailability {
        ARLNASActionAvailability(saveConfiguration: .unsupported(.hostNotConfigured),
            saveCredential: .unsupported(.nativeNASPurposeUnavailable),
            testConnection: .allowed, testRead: .allowed, reconnect: .allowed, stop: .allowed)
    }
}
