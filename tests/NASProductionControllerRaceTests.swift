import Foundation
@testable import ARLCredentialOnboarding

private enum CheckError: Error { case failed(String) }
private func check(_ value: Bool, _ reason: String) throws {
    if !value { throw CheckError.failed(reason) }
}

private final class Repository: CredentialRepository, @unchecked Sendable {
    private let lock = NSLock()
    private var row: StoredMetadata?
    private var bytes = Data()
    func metadata(_ purpose: CredentialPurpose) throws -> StoredMetadata? { lock.withLock { row } }
    func create(_ input: CredentialInput, purpose: CredentialPurpose) throws -> StoredMetadata {
        try lock.withLock {
            guard row == nil else { throw CredentialError.alreadyConfigured }
            bytes = try input.copyBytes(for: purpose)
            let next = StoredMetadata(reference: .init(purpose: purpose)); row = next; return next
        }
    }
    func lease(_ ref: CredentialReference) throws -> (metadata: StoredMetadata, secret: CredentialInput) {
        try lock.withLock {
            guard let row, row.reference == ref else { throw CredentialError.staleReference }
            return (row, try CredentialInput(purpose: ref.purpose, data: bytes))
        }
    }
    func replace(_ ref: CredentialReference, input: CredentialInput) throws -> StoredMetadata { throw CredentialError.wrongPurpose }
    func record(_ ref: CredentialReference, result: ConnectionTestResult, expectedGeneration: UUID) throws -> StoredMetadata { throw CredentialError.wrongPurpose }
    func remove(_ ref: CredentialReference) throws { throw CredentialError.wrongPurpose }
}

private actor Runtime: NASConnectionRuntime {
    private var state = NASRuntimeState()
    private var hold = false
    private var pending: CheckedContinuation<NASRuntimeState, Never>?
    private var ready: CheckedContinuation<Void, Never>?
    private var captured = NASRuntimeState()
    func connect(configuration: NASConnectionConfiguration, identity: NASCredentialIdentity, secret: CredentialInput) async throws -> NASRuntimeState {
        state = .init(connected: true, readable: true, epoch: UUID().uuidString.lowercased(),
                      scopeJSON: try configuration.scopeJSON(identity: identity))
        return state
    }
    func status() async -> NASRuntimeState {
        guard hold else { return state }
        hold = false; captured = state
        return await withCheckedContinuation { continuation in
            pending = continuation
            ready?.resume(); ready = nil
        }
    }
    func arm() { hold = true }
    func waitForSuspendedStatus() async {
        if pending != nil { return }
        await withCheckedContinuation { ready = $0 }
    }
    func release() { pending?.resume(returning: captured); pending = nil }
    func readDirectory() async throws -> Data { Data() }
    func uploadNew(_ proposal: NASUploadProposal) async throws -> NASUploadResult { .init(status: "committed", failure: nil) }
    func stop() { state = .init() }
}

@main enum NASProductionControllerRaceTests {
    @MainActor
    static func main() async {
        do {
            let home = URL(fileURLWithPath: CommandLine.arguments[1])
            let runtime = Runtime()
            let owner = NASCredentialService(repository: Repository(), runtime: runtime, enabled: true)
            let controller = NASProductionController(owner: owner, home: home, enabled: true)
            do {
                try await controller.connectSavedReadScope()
                throw CheckError.failed("missing directory unexpectedly connected")
            } catch let fault as ARLNASFault {
                try check(fault == .configurationNotSaved, "empty directory configuration is distinct before any credential/network call")
            }
            if CommandLine.arguments.contains("--scope-guard-only") {
                print("{\"status\":\"PASS\",\"checks\":1,\"case\":\"missing_directory_configuration\",\"network_keychain_permissions\":false}")
                return
            }
            let config = try ARLNASConfiguration(address: "synthetic.invalid", transport: .smb,
                share: "fixture", root: "allowed/sub", applicationScope: .readOnly, advanced: .init())
            func request(_ action: ARLNASManualAction) -> ARLNASActionRequest {
                let snapshot = controller.cachedSnapshot()
                return .init(action: action, configuration: config, expectedSnapshotRevision: snapshot.revision,
                    expectedConfigurationGeneration: snapshot.currentConfigurationGeneration, readScope: snapshot.readScope)
            }
            func perform(_ action: ARLNASManualAction) async throws {
                let req = request(action)
                let reply = await controller.perform(req, manualIntent: .init(request: req))
                try check(reply.outcome == .applied, "action_\(action)_\(reply.outcome)")
            }
            try await perform(.saveConfiguration)
            let req = request(.saveCredential)
            let saved = await controller.save(.init(username: "synthetic", password: "fixture-only"), request: req,
                                              manualIntent: .init(request: req))
            try check(saved.outcome == .applied, "synthetic_save")
            try await perform(.testConnection)

            var checks: [String] = []
            for cancelOnly in [false, true] {
                let proposal = try await controller.prepareUploadTest(directory: "test")
                await runtime.arm()
                let upload = Task { @MainActor in try await controller.uploadTestAfterConfirmation(proposal) }
                await runtime.waitForSuspendedStatus()
                if cancelOnly { upload.cancel() }
                else {
                    try await perform(.stop)
                    try await perform(.reconnect)
                }
                let newer = controller.cachedSnapshot()
                try check(newer.connected == .verified, "newer_connection")
                await runtime.release()
                let result = try await upload.value
                try check(result.status == "uncertain" && result.failure == "cancelled", "late_result_uncertain")
                try check(controller.cachedSnapshot() == newer, "late_status_mutated_newer_snapshot")
                checks.append(cancelOnly ? "cancelled_upload_status_cannot_mutate_snapshot" : "stop_reconnect_fences_late_upload_status")
            }
            try await perform(.stop)
            print(String(decoding: try JSONSerialization.data(withJSONObject: ["status":"PASS", "checks":checks,
                "production_controller":true,"production_service":true,"synthetic_repository_runtime":true,
                "real_keychain":false,"real_network":false], options:[.sortedKeys]), as:UTF8.self))
        } catch {
            print("NAS_CONTROLLER_RACE_FAILED: \(error)")
            exit(1)
        }
    }
}
