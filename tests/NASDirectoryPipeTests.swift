import Foundation
@testable import ARLCredentialOnboarding
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

private struct FixtureGate: DeploymentGate {
    func verify() throws {}
}

@main enum NASDirectoryPipeTests {
    @MainActor static func main() async {
        do {
            let bundle=URL(fileURLWithPath:CommandLine.arguments[1])
            let repository=Repository()
            let runtime=NASRuntimeClient(gate:FixtureGate(),repository:repository,bundleURL:bundle)
            let service=NASCredentialService(repository:repository,runtime:runtime,enabled:true)
            let config=try NASConnectionConfiguration(sourceRef:"fixture",host:"synthetic.invalid",share:"fixture",root:"approved")
            let identity=try await service.save(configuration:config,username:"fixture",password:"fixture-only",replacing:nil)
            let state=try await service.connect(configuration:config,identity:identity)
            guard state.connected else { throw CheckError.failed("connect") }
            let page=try await service.browseDirectories(path:"")
            guard page.directories == ["test"], page.nextCursor == nil else { throw CheckError.failed("directory_projection") }
            let child=try await service.browseDirectories(path:"test")
            guard child.path == "test", child.directories.isEmpty else { throw CheckError.failed("directory_navigation") }
            let inventory=try await service.readDirectory()
            guard let dto=try JSONSerialization.jsonObject(with:inventory) as? [String:Any],
                  let entries=dto["entries"] as? [[String:Any]], entries.count == 2,
                  entries.allSatisfy({$0["path"] == nil}) else { throw CheckError.failed("public_inventory_privacy") }
            func file(_ tool: String, _ args: [String: Any]) async throws -> [String: Any] {
                let request = try NASFileRequest(tool: tool, argumentsJSON: JSONSerialization.data(withJSONObject: args))
                let data = try await service.consumeFileRead(request)
                return try JSONSerialization.jsonObject(with: data) as! [String: Any]
            }
            let first = try await file("mio_nas_list", ["limit":1])
            guard let cursor = first["next_cursor"] as? String, first["partial"] as? Bool == true,
                  (first["entries"] as? [[String:Any]])?.first?["path"] as? String == "approved/synthetic.txt"
            else { throw CheckError.failed("real_file_page_path") }
            let second = try await file("mio_nas_list", ["limit":1,"cursor":cursor])
            guard second["enumeration_complete"] as? Bool == true,
                  (second["entries"] as? [[String:Any]])?.first?["path"] as? String == "approved/test"
            else { throw CheckError.failed("continuation_not_restart") }
            let found = try await file("mio_nas_search", ["keyword":"SYNTHETIC"])
            guard let foundEntry = (found["entries"] as? [[String:Any]])?.first,
                  foundEntry["path"] as? String == "approved/synthetic.txt" else { throw CheckError.failed("native_search") }
            let readArgs: [String:Any] = ["source_ref":found["source_ref"]!,"config_generation":found["config_generation"]!,
                "connection_epoch":found["connection_epoch"]!,"object_ref":foundEntry["object_ref"]!,
                "revision":foundEntry["revision"]!,"offset":1,"length":2]
            let read = try await file("mio_nas_read", readArgs)
            guard read["data_base64"] as? String == Data("at".utf8).base64EncodedString(),
                  read["bytes_read"] as? Int == 2, read["next_offset"] as? Int == 3
            else { throw CheckError.failed("native_original_range") }
            var bad = readArgs; bad["offset"] = 5
            do { _ = try await file("mio_nas_read",bad); throw CheckError.failed("offset_accepted") }
            catch NASRuntimeFailure.invalidRequest {}
            _ = try await file("mio_nas_search", ["keyword":"synthetic"])
            do { _ = try NASFileRequest(tool:"mio_nas_list",argumentsJSON:Data("{\"limit\":true}".utf8)); throw CheckError.failed("boolean_limit") }
            catch NASRuntimeFailure.invalidRequest {}
            await service.stop()
            do { _ = try await service.browseDirectories(path:""); throw CheckError.failed("browse_after_stop") }
            catch CredentialError.missing {}
            guard repository.leases == 1 else { throw CheckError.failed("extra_lease") }
            // Exercise the exact model seam shared owner/Mio will call, using the same real pipe.
            let home = bundle.deletingLastPathComponent().appendingPathComponent("controller-home")
            try FileManager.default.createDirectory(at:home,withIntermediateDirectories:true)
            let controllerRepository = Repository()
            let controllerRuntime = NASRuntimeClient(gate:FixtureGate(),repository:controllerRepository,bundleURL:bundle)
            let controllerService = NASCredentialService(repository:controllerRepository,runtime:controllerRuntime,enabled:true)
            let controller = NASProductionController(owner:controllerService,home:home,enabled:true)
            let ui = try ARLNASConfiguration(address:"synthetic.invalid",transport:.smb,share:"fixture",root:"approved",applicationScope:.readOnly,advanced:.init())
            func action(_ kind:ARLNASManualAction) -> ARLNASActionRequest {
                let snapshot = controller.cachedSnapshot()
                return .init(action:kind,configuration:ui,expectedSnapshotRevision:snapshot.revision,
                    expectedConfigurationGeneration:snapshot.currentConfigurationGeneration,readScope:snapshot.readScope)
            }
            let configRequest = action(.saveConfiguration)
            let configured = await controller.perform(configRequest,manualIntent:.init(request:configRequest))
            guard configured.outcome == .applied else { throw CheckError.failed("controller_configure") }
            let saveRequest = action(.saveCredential)
            let saved = await controller.save(.init(username:"fixture",password:"fixture-only"),request:saveRequest,manualIntent:.init(request:saveRequest))
            guard saved.outcome == .applied else { throw CheckError.failed("controller_save") }
            let model = ARLNASSetupModel(backend:controller,credentialConsumer:controller)
            try await model.connectSavedReadScope()
            let modelSearch = try await model.consumeFileRead(tool:"mio_nas_search",argumentsJSON:Data("{\"keyword\":\"synthetic\"}".utf8))
            let modelResult = try JSONSerialization.jsonObject(with:modelSearch) as! [String:Any]
            let modelEntry = (modelResult["entries"] as! [[String:Any]])[0]
            var modelRead = readArgs
            for key in ["source_ref","config_generation","connection_epoch"] {modelRead[key]=modelResult[key]}
            for key in ["object_ref","revision"] {modelRead[key]=modelEntry[key]}
            try await model.connectSavedReadScope() // Healthy current scope must reuse its epoch and one lease.
            let modelBytes = try await model.consumeFileRead(tool:"mio_nas_read",argumentsJSON:JSONSerialization.data(withJSONObject:modelRead))
            let modelReadResult = try JSONSerialization.jsonObject(with:modelBytes) as! [String:Any]
            guard modelReadResult["data_base64"] as? String == "YXQ=", controllerRepository.leases == 1
            else { throw CheckError.failed("model_controller_same_owner_original_range") }
            await controllerService.stop()
            print("{\"status\":\"PASS\",\"checks\":[\"production_native_wire_directory_navigation\",\"public_inventory_stays_opaque\",\"stop_revokes_directory_browse\",\"single_connection_lease\",\"native_file_pages_search_and_original_bytes\",\"offset_rejection_preserves_session\",\"model_controller_service_pipe_file_read\",\"healthy_scope_reuses_epoch_and_lease\"],\"network\":false,\"keychain\":false}")
        } catch { print("DIRECTORY_PIPE_FAILED: \(error)"); exit(1) }
    }
}
