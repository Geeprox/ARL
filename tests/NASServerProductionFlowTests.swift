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
    var state=NASRuntimeState()
    var server=NASServerState()
    var hold=false
    var pending:CheckedContinuation<Void,Never>?
    var waiter:CheckedContinuation<Void,Never>?
    var started=false
    func authenticate(endpoint:NASServerEndpoint,identity:NASCredentialIdentity,secret:CredentialInput) async throws -> NASServerState {
        let envelope=try NASEnvelope.fields(secret.copyBytes(for:.nasSMB))
        precondition((envelope["schema"] as? NSNumber)?.intValue==2)
        precondition(envelope["endpoint_fingerprint"] as? String==endpoint.fingerprint)
        started=true;waiter?.resume();waiter=nil
        if hold {await withCheckedContinuation{pending=$0}}
        server = .init(authenticated:true,epoch:String(repeating:"a",count:32));return server
    }
    func arm(){hold=true;started=false}
    func waitStarted() async{if !started {await withCheckedContinuation{waiter=$0}}}
    func serverStatus() async -> NASServerState{server}
    func listShares(cursor:String?) async throws -> NASServerState{.init(authenticated:true,epoch:server.epoch,shares:[try NASShareRecord(name:"Data")])}
    func previewDirectories(share:String,path:String,cursor:String?) async throws -> NASDirectoryPage{
        let raw=try JSONSerialization.data(withJSONObject:["path":path,"directories":path.isEmpty ? ["selected"] : [],"next_cursor":NSNull()])
        return try .init(data:raw,expectedPath:path)
    }
    func connect(configuration:NASConnectionConfiguration,identity:NASCredentialIdentity,secret:CredentialInput) async throws -> NASRuntimeState{
        precondition(configuration.root=="selected")
        state = .init(connected:true,readable:true,epoch:String(repeating:"b",count:32),scopeJSON:try configuration.scopeJSON(identity:identity));return state
    }
    func status() async -> NASRuntimeState{state}
    func readDirectory() async throws -> Data{Data()}
    func stop(){state = .init();server = .init();pending?.resume();pending=nil}
}
@main enum NASServerProductionFlowTests {
    @MainActor static func main() async throws {
        let home=URL(fileURLWithPath:CommandLine.arguments[1])
        let repository=Repository(),runtime=Runtime()
        let owner=NASCredentialService(repository:repository,runtime:runtime,enabled:true)
        let controller=NASProductionController(owner:owner,home:home,enabled:true)
        func run(_ action:NASServerSetupAction,input:ARLNASCredentialInput?=nil) async throws{
            guard let intent=controller.beginServerAction(action) else{throw CheckError.failed("begin")}
            await controller.performServerAction(intent,input:input)
        }
        try await run(.save(address:"smb://synthetic.invalid",port:445,timeout:2),input:.init(username:"fixture",password:"synthetic-only"))
        try check(controller.serverSetupSnapshot().saved,"save_without_share")
        try check(controller.cachedSnapshot().configuration==nil && controller.cachedSnapshot().readScope==nil,"save_grants_no_directory")
        let bytes=try Data(contentsOf:home.appendingPathComponent("nas/server-login-v2.json"))
        let text=String(decoding:bytes,as:UTF8.self)
        try check(!text.contains("synthetic-only") && !text.contains("username") && !text.contains("password"),"secret_not_in_settings")
        try await run(.login)
        try check(controller.serverSetupSnapshot().state.authenticated,"real_owner_login")
        try await run(.shares(cursor:nil))
        try check(controller.serverSetupSnapshot().state.shares.map(\.name)==["Data"],"runtime_shares_consumed")
        try await run(.directory(share:"Data",path:"",cursor:nil))
        try await run(.authorize(share:"Data",path:"",wholeShare:false))
        try check(controller.cachedSnapshot().configuration==nil,"whole_share_requires_explicit_choice")
        try await run(.login);try await run(.shares(cursor:nil));try await run(.directory(share:"Data",path:"",cursor:nil));try await run(.directory(share:"Data",path:"selected",cursor:nil))
        try await run(.authorize(share:"Data",path:"selected",wholeShare:false))
        let snapshot=controller.cachedSnapshot()
        try check(snapshot.configuration?.root=="selected" && snapshot.credentialReferenceSaved == .verified,"selected_scope_uses_same_credential")
        let configuration=snapshot.configuration!
        let request=ARLNASActionRequest(action:.testConnection,configuration:configuration,expectedSnapshotRevision:snapshot.revision,expectedConfigurationGeneration:snapshot.currentConfigurationGeneration,readScope:snapshot.readScope)
        let reply=await controller.perform(request,manualIntent:.init(request:request))
        try check(reply.outcome == .applied && reply.snapshot.connected == .verified,"final_scoped_connection_consumes_v2_envelope")
        try await run(.stop)
        await runtime.arm()
        let intent=controller.beginServerAction(.login)!
        let pending=Task{@MainActor in await controller.performServerAction(intent,input:nil)}
        await runtime.waitStarted()
        try await run(.stop);await pending.value
        try check(!controller.serverSetupSnapshot().state.authenticated,"stop_fences_late_login")
        let reloaded=NASProductionController(owner:owner,home:home,enabled:true)
        try check(reloaded.serverSetupSnapshot().saved && !reloaded.serverSetupSnapshot().state.authenticated,"reload_does_not_auto_login")
        let same=try NASServerEndpoint(sourceRef:"other",host:"SYNTHETIC.invalid",port:445,timeoutSeconds:20,generation:9)
        let original=try NASServerEndpoint(sourceRef:"fixture",host:"synthetic.invalid",port:445,timeoutSeconds:2)
        try check(same.fingerprint==original.fingerprint,"server_binding_independent_of_share_root_timeout")
        print("PASS NAS production flow: save→login→shares→preview→explicit scope→scoped connection; no real Keychain/network")
    }
}
