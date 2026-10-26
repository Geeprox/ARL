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

private struct FixtureGate: DeploymentGate {
    func verify() throws {}
}
@main enum NASRuntimePipeTests {
    static func main() async {
        do {
            let bundle = URL(fileURLWithPath: CommandLine.arguments[1])
            var checks: [String] = []
            for (share, root, generation) in [("fixture", "approved", UInt64(1)), ("共享", "测试/资料😀", UInt64(2))] {
                let repository = Repository()
                let runtime = NASRuntimeClient(gate: FixtureGate(), repository: repository, bundleURL: bundle,
                    journalDirectory: URL(fileURLWithPath: CommandLine.arguments[2]).appendingPathComponent("journal"))
                let service = NASCredentialService(repository: repository, runtime: runtime, enabled: true)
                let config = try NASConnectionConfiguration(sourceRef: "fixture", host: "synthetic.invalid",
                    share: share, root: root, generation: generation)
                let identity = try await service.save(configuration: config, username: "fixture", password: "fixture-only", replacing: nil)
                let state = try await service.connect(configuration: config, identity: identity)
                guard state.connected, state.readable, let scope = state.scopeJSON,
                      let actual = try JSONSerialization.jsonObject(with: scope) as? NSDictionary,
                      let expected = try JSONSerialization.jsonObject(with: config.scopeJSON(identity: identity)) as? NSDictionary,
                      actual == expected else { throw CheckError.failed("scope_or_connection") }
                let data = try await service.readDirectory()
                guard let inventory = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let entries = inventory["entries"] as? [[String:Any]], entries.count == 1,
                      entries[0]["path"] == nil, entries[0]["size"] as? Int == 4,
                      inventory["snapshot_consistent"] as? Bool == false else { throw CheckError.failed("bounded_inventory") }
                checks.append(generation == 1 ? "native_pipe_and_real_factory_ascii" : "native_pipe_unicode_scope_generation_two")
                let listInput = try NASFileRequest(tool: "mio_nas_list", argumentsJSON: Data("{}".utf8))
                let listedBytes = try await service.consumeFileRead(listInput)
                guard let listed = try JSONSerialization.jsonObject(with: listedBytes) as? [String: Any],
                      let epoch = listed["connection_epoch"] as? String,
                      let rows = listed["entries"] as? [[String: Any]], let file = rows.first,
                      let object = file["object_ref"] as? String, let revision = file["revision"] as? String
                else { throw CheckError.failed("file_list_reference") }
                let arguments: [String: Any] = ["source_ref": "fixture", "config_generation": generation,
                    "connection_epoch": epoch, "object_ref": object, "revision": revision, "size": 4, "max_bytes": 65536]
                let textInput = try NASFileRequest(tool: "mio_nas_read_text", argumentsJSON: JSONSerialization.data(withJSONObject: arguments))
                let started = ProcessInfo.processInfo.systemUptime
                let textBytes = try await service.consumeFileRead(textInput)
                guard let text = try JSONSerialization.jsonObject(with: textBytes) as? [String: Any],
                      text["text"] as? String == "test", text["complete"] as? Bool == true
                else { throw CheckError.failed("strict_text_reply") }
                if generation == 1 {
                    guard ProcessInfo.processInfo.systemUptime - started > 18 else { throw CheckError.failed("delayed_file_fixture_not_exercised") }
                    checks.append("file_request_survives_delay_beyond_old18_second_budget")
                } else { checks.append("strict_text_keeps_unicode_scope_and_original_epoch") }

                if generation == 1 {
                    let proposal = try await service.prepareUploadTest(directory: "test")
                    let uploaded = try await service.uploadTestAfterConfirmation(proposal)
                    guard uploaded.committed else { throw CheckError.failed("upload_result_" + uploaded.status + "_" + (uploaded.failure ?? "none")) }
                    checks.append("native_journal_and_real_upload_storage_smb_medium")
                    do {
                        _ = try await service.uploadTestAfterConfirmation(proposal)
                        throw CheckError.failed("proposal_replay")
                    } catch CredentialError.staleReference {}
                    checks.append("native_exact_proposal_consumed_once")
                }
                repository.rotate()
                let revoked = await service.status()
                guard !revoked.connected, revoked.failure == "source_changed" else { throw CheckError.failed("rotation") }
                await service.stop()
                checks.append("generation_\(generation)_rotation_stops_owned_process")
            }
            print(String(decoding: try JSONSerialization.data(withJSONObject: [
                "status":"PASS", "checks":checks,"count":checks.count,
                "production_native_pipe":true,"production_python_factory":true,
                "synthetic_repository":true,"synthetic_smb_only":true,
                "real_keychain":false,"real_network":false],options:[.sortedKeys]),as:UTF8.self))
        } catch {
            print("NAS_RUNTIME_PIPE_FIXTURE_FAILED: \(error)")
            exit(1)
        }
    }
}
