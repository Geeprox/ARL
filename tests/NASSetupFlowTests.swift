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
    private var directoryHold = false
    private var directoryWaiter: CheckedContinuation<Void, Never>?
    private var directoryReady: CheckedContinuation<Void, Never>?
    func armDirectory() { directoryHold = true }
    func waitForDirectory() async {
        if directoryWaiter != nil { return }
        await withCheckedContinuation { directoryReady = $0 }
    }
    func releaseDirectory() { directoryWaiter?.resume(); directoryWaiter = nil }
    func browseDirectories(path: String, cursor: String?) async throws -> NASDirectoryPage {
        if directoryHold {
            directoryHold = false
            await withCheckedContinuation { directoryWaiter = $0; directoryReady?.resume(); directoryReady = nil }
        }
        return try .init(path: path, directories: path.isEmpty ? ["child"] : [], nextCursor: nil)
    }
    func uploadNew(_ proposal: NASUploadProposal) async throws -> NASUploadResult { .init(status: "committed", failure: nil) }
    func stop() { state = .init() }
}


@MainActor private final class DiscoveryFixture: NASDiscoveryDriver {
    var callbacks: [@MainActor (NASDiscoveryEvent) -> Void] = []
    var stops = 0
    func start(_ receive: @escaping @MainActor (NASDiscoveryEvent) -> Void) { callbacks.append(receive) }
    func stop() { stops += 1 }
}

@main enum NASSetupFlowTests {
    @MainActor static func main() async {
        do {
            var checks: [String] = []
            let raw = "smb://Synthetic.local"
            let parsed = try NASAddressInput(raw)
            try check(parsed.host == "Synthetic.local" && parsed.original == raw && parsed.port == 445, "address_preserved")
            let portInput = try NASAddressInput("smb://Synthetic.local:1445"); try check(portInput.port == 1445, "url_port")
            for invalid in ["smb://user:password@host", "https://host", "smb://host/share", "smb://host?secret=x", "../host", "smb://host/%2e%2e", "smb://[::1]"] {
                do { _ = try NASAddressInput(invalid); throw CheckError.failed("invalid_address_accepted") }
                catch ARLNASFault.invalidConfiguration {}
            }
            checks.append("address_normalization_preservation_and_rejection")
            let driver = DiscoveryFixture(), discovery = NASDiscoveryModel(driver: DiscoveryFixture())
            _ = discovery // Construction itself must not invoke discovery.
            let found = NASDiscoveryModel(driver: driver)
            try check(driver.callbacks.isEmpty, "discovery_started_without_click")
            found.refresh()
            let one = NASDiscoveredDevice(id: "device", name: "Synthetic", host: "Synthetic.local", shares: ["fixture"], mounted: true)
            driver.callbacks[0](.device(.init(id: "mount", name: "Synthetic", host: "Synthetic.local", shares: ["fixture"], mounted: true)))
            driver.callbacks[0](.device(.init(id: "device", name: "Synthetic")))
            driver.callbacks[0](.device(one)); driver.callbacks[0](.device(.init(id: "device", name: "Synthetic", host: "Synthetic.local", addresses: ["192.0.2.1"])))
            try check(found.devices.count == 1 && found.devices[0].shares == ["fixture"] && found.devices[0].mounted, "dedup")
            found.cancel(); driver.callbacks[0](.device(.init(id: "late", name: "late")))
            try check(found.devices.count == 1 && found.phase == .cancelled, "cancel_fence")
            found.refresh(); driver.callbacks[0](.finished)
            try check(found.phase == .searching && found.devices.count == 1 && !found.devices[0].seenInCurrentScan, "refresh_preserves_history_and_fences_old_scan")
            driver.callbacks[1](.finished); try check(found.phase == .complete && found.devices.count == 1 && !found.devices[0].seenInCurrentScan, "empty_scan_preserves_history_as_stale")
            found.refresh(); driver.callbacks[2](.failed); try check(found.phase == .failed, "failure")
            checks.append("discovery_explicit_dedup_cancel_refresh_empty_failure")

            let home = URL(fileURLWithPath: CommandLine.arguments[1])
            let runtime = Runtime()
            let owner = NASCredentialService(repository: Repository(), runtime: runtime, enabled: true)
            let controller = NASProductionController(owner: owner, home: home, enabled: true)
            let model = ARLNASSetupModel(backend: controller, credentialConsumer: controller)
            model.selectDevice(one, address: "Synthetic.local")
            try check(model.draft.address == "Synthetic.local" && model.draft.share.isEmpty && model.shareSuggestions == ["fixture"], "selection_draft_only")
            try check(controller.cachedSnapshot().configuration == nil, "selection_saved_implicitly")
            model.draft.address = "different.invalid"
            try check(model.shareSuggestions.isEmpty, "stale_mount_hint")
            model.draft.address = raw; model.draft.share = "fixture"; model.draft.root = "allowed"
            func act(_ action: ARLNASManualAction) async throws {
                guard let intent = model.beginManualActionAfterClick(action) else { throw CheckError.failed("intent_\(action)_\(String(describing:model.lastFault))") }
                await model.performAfterClick(intent)
                try check(model.lastFault == nil, "model_rejected_\(action)_\(String(describing:model.lastFault))")
            }
            try await act(.saveConfiguration)
            try check(model.snapshot.configuration?.address == "Synthetic.local" && model.snapshot.configuration?.addressInput == raw, "saved_address")
            let reloaded = NASProductionController(owner: owner, home: home, enabled: true)
            try check(reloaded.cachedSnapshot().configuration?.addressInput == raw, "persistence_original_input")
            guard let intent = model.beginManualActionAfterClick(.saveCredential) else { throw CheckError.failed("credential_intent") }
            await model.saveCredentialAfterClick(.init(username: "synthetic", password: "fixture-only"), manualIntent: intent)
            try check(model.lastFault == nil, "credential_save")
            let generation = model.snapshot.currentConfigurationGeneration
            try await act(.testConnection)
            try check(model.snapshot.connected == .verified && model.snapshot.currentConfigurationGeneration == generation && model.canBrowseDirectories, "native_connect_contract")
            await model.browseDirectoriesAfterClick()
            try check(model.directoryPage?.directories == ["child"], "directory_root")
            await model.browseDirectoriesAfterClick(path: "child")
            try check(model.directoryPage?.path == "child", "directory_navigation")
            model.selectDirectoryAsRoot()
            try check(model.draft.root == "allowed/child" && !model.canBrowseDirectories && model.directoryPage == nil, "directory_narrows_draft_requires_save")
            model.draft.root = "allowed"
            try await act(.testRead)
            try await act(.stop)
            try check(model.snapshot.connectionEpoch == nil && model.snapshot.currentConfigurationGeneration == generation, "native_stop_contract")
            try await act(.reconnect)
            try check(model.snapshot.connected == .verified && model.snapshot.currentConfigurationGeneration == generation, "native_reconnect_contract")
            await runtime.armDirectory()
            let browse = Task { @MainActor in await model.browseDirectoriesAfterClick() }
            await runtime.waitForDirectory()
            try await act(.stop)
            let stopped = model.snapshot
            await runtime.releaseDirectory(); await browse.value
            try check(model.snapshot == stopped && model.directoryPage == nil, "late_directory_after_stop")
            checks.append("late_directory_reply_cannot_repopulate_stopped_session")
            checks.append("actual_model_controller_service_save_login_connect_read_stop_reconnect")
            checks.append("discovery_to_editable_draft_and_original_input_persistence")
            checks.append("directory_navigation_narrows_draft_and_requires_save")
            do { _ = try NASDirectoryPage(path: "child", directories: ["../escape"], nextCursor: nil); throw CheckError.failed("escaped_directory") }
            catch CredentialError.invalidInput {}
            do { _ = try NASDirectoryPage(path: "child", directories: ["sibling"], nextCursor: nil); throw CheckError.failed("sibling_directory") }
            catch CredentialError.invalidInput {}
            checks.append("directory_dto_root_boundary")
            print(String(decoding: try JSONSerialization.data(withJSONObject: ["status":"PASS","checks":checks,
                "actual_model_controller_service":true,"network":false,"keychain":false],options:[.sortedKeys]),as:UTF8.self))
        } catch { print("NAS_SETUP_FLOW_FAILED: \(error)"); exit(1) }
    }
}
