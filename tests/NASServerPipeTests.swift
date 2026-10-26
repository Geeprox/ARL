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

@main enum NASServerPipeTests {
    static func main() async throws {
        let bundle=URL(fileURLWithPath:CommandLine.arguments[1])
        let repository=Repository()
        let runtime=NASRuntimeClient(gate:FixtureGate(),repository:repository,bundleURL:bundle)
        let service=NASCredentialService(repository:repository,runtime:runtime,enabled:true)
        let endpoint=try NASServerEndpoint(sourceRef:"fixture",host:"synthetic.invalid")
        let identity=try await service.saveServer(endpoint:endpoint,username:"fixture",password:"fixture-only",replacing:nil)
        let authenticated=try await service.authenticateServer(endpoint:endpoint,identity:identity)
        guard authenticated.authenticated,authenticated.shares.isEmpty else{throw CheckError.failed("login")}
        let shares=try await service.listServerShares()
        guard shares.shares.map(\.name)==["Data","资料"],shares.epoch==authenticated.epoch else{throw CheckError.failed("shares")}
        let page=try await service.previewServerDirectories(share:"Data",path:"")
        guard page.directories==["selected"] else{throw CheckError.failed("preview")}
        let nested=try await service.previewServerDirectories(share:"Data",path:"selected")
        guard nested.path=="selected",nested.directories.isEmpty else{throw CheckError.failed("nested")}
        do {_=try await service.readDirectory();throw CheckError.failed("file_data_before_scope")}catch CredentialError.missing{}
        repository.rotate()
        let revoked=await service.serverStatus()
        guard !revoked.authenticated,revoked.failure=="source_changed" else{throw CheckError.failed("rotation")}
        await service.stop()
        guard repository.leases==1 else{throw CheckError.failed("single_lease")}
        print("PASS native NAS server pipe: actual Swift owner→private pipe→production Python host; synthetic SMB only, network forbidden")
    }
}
