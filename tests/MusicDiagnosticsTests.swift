import Foundation

private struct TestGate:DeploymentGate { func verify() throws {} }
private enum TestFailure:Error { case assertion(String) }
private final class TraceBox:@unchecked Sendable {
    private let lock=NSLock();private var entries:[MusicDiagnostic]=[]
    func append(_ e:MusicDiagnostic) { lock.withLock{entries.append(e)} }
    var values:[MusicDiagnostic] { lock.withLock{entries} }
}
private func synthetic() throws -> CredentialInput {
    let device=try JSONSerialization.data(withJSONObject:["deviceId":"00000000-0000-4000-8000-000000000001"])
    let encrypted=try JSONSerialization.data(withJSONObject:["iv":String(repeating:"0",count:32),"data":String(repeating:"0",count:32)])
    return try CredentialInput(purpose:.neteaseMusic,data:JSONSerialization.data(withJSONObject:["schema":1,"storage":"official","files":[".netease_mcp_device.json":device.base64EncodedString(),".config/ncm-cli/credentials.enc.json":encrypted.base64EncodedString()]]))
}
private struct FakeRepository:CredentialRepository {
    let stored=StoredMetadata(reference:.init(purpose:.neteaseMusic))
    func metadata(_ purpose:CredentialPurpose)throws->StoredMetadata? {stored}
    func create(_ input:CredentialInput,purpose:CredentialPurpose)throws->StoredMetadata {stored}
    func replace(_ ref:CredentialReference,input:CredentialInput)throws->StoredMetadata {stored}
    func lease(_ ref:CredentialReference)throws->(metadata:StoredMetadata,secret:CredentialInput) {(stored,try synthetic())}
    func record(_ ref:CredentialReference,result:ConnectionTestResult,expectedGeneration:UUID)throws->StoredMetadata {stored}
    func remove(_ ref:CredentialReference)throws {}
    func commitLease(_ ref:CredentialReference,input:CredentialInput,result:ConnectionTestResult?,expectedGeneration:UUID)throws->StoredMetadata {throw CredentialError.storageUnavailable}
}
private struct FakeValidator:CredentialValidator {
    func validate(_ secret:CredentialInput,purpose:CredentialPurpose,deadline:ContinuousClock.Instant)async->ConnectionTestResult {.init(.credentialUnconfirmed)}
}
private struct FakeMusic:MusicTransport {
    func send(_ secret:CredentialInput,operation:MusicOperation,onLoginURL:@escaping @Sendable(URL)->Void)async throws->MusicRuntimeResult {
        .init(state:.sessionPresentUnverified,credential:try synthetic())
    }
}
@main @MainActor enum MusicDiagnosticsTests {
    static func main()async throws {
        var checks:[String]=[]
        func check(_ condition:Bool,_ name:String)throws {guard condition else {throw TestFailure.assertion(name)};checks.append(name)}
        let id=UUID(),reference=CredentialReference(purpose:.neteaseMusic)
        let frame:[String:Any]=["schema":1,"event":"diagnostic","call_id":id.uuidString,"sequence":1,"phase":"qr_create","kind":"provider_rejected","http_status":403,"code":40101,"sub_code":NSNull(),"provider_status":NSNull(),"elapsed_ms":12]
        let valid=try MusicDiagnostic.decode(frame,callID:id.uuidString,expectedSequence:1)
        try check(valid.httpStatus==403 && valid.code==40101 && valid.phase == .qr_create,"finite_frame_decoded")
        for (key,value) in [("message","SYNTHETIC-PRIVATE-KEY" as Any),("phase","SYNTHETIC-TOKEN"),("code",true),("code",1.5),("sub_code","123456-secret"),("http_status",999),("sequence",2),("elapsed_ms",-1),("kind","secret-kind")] {
            var bad=frame;bad[key]=value;var rejected=false
            do {_=try MusicDiagnostic.decode(bad,callID:id.uuidString,expectedSequence:1)}catch {rejected=true}
            try check(rejected,"reject_"+key+"_\(checks.count)")
        }
        var providerFrame=frame;providerFrame["phase"]="effect";providerFrame["code"]=400
        providerFrame["provider_code"]="UNEXPECTED_COLLECTION_TYPE";providerFrame["provider_message"]="songIdList: expected JSON array"
        providerFrame["provider_msg"]="playlistId has a valid scalar type"
        let provider=try MusicDiagnostic.decode(providerFrame,callID:id.uuidString,expectedSequence:1)
        try check(provider.code==400 && provider.providerCode == "UNEXPECTED_COLLECTION_TYPE" && provider.providerMessage == "songIdList: expected JSON array","effect_provider_actual_text")
        try check(provider.providerMsg == "playlistId has a valid scalar type","message_and_msg_keep_sources")
        for (key,value) in [("provider_message","https://example.invalid/private"),("provider_code",String(repeating:"X",count:65)),("provider_message",String(repeating:"中",count:171)),("provider_message","line\nbreak"),("phase","qr_poll"),("kind","succeeded")] {
            var bad=providerFrame;bad[key]=value;var rejected=false
            do {_=try MusicDiagnostic.decode(bad,callID:id.uuidString,expectedSequence:1)}catch {rejected=true}
            try check(rejected,"reject_provider_"+key)
        }
        try provider.validateProviderFields()
        var unsafeLogEntry=provider;unsafeLogEntry.providerMessage="https://example.invalid/private"
        var unsafeLogRejected=false
        do {try unsafeLogEntry.validateProviderFields()} catch {unsafeLogRejected=true}
        try check(unsafeLogRejected,"public_log_uses_same_sanitized_text_boundary")
        let providerEncoded=String(decoding:try JSONEncoder().encode(provider),as:UTF8.self)
        try check(providerEncoded.contains("expected JSON array") && !providerEncoded.contains("https:"),"provider_safe_text_logged")
        var ui=MusicLoginPresentation();_ = ui.begin(id:id,reference:reference)
        ui.fail(MusicDiagnosticFailure(diagnostic:valid),id:id,reference:reference)
        try check(ui.phase.message?.contains("创建二维码")==true && ui.phase.message?.contains("40101")==true && ui.image==nil,"ui_concrete_phase_code_correlation")
        let cancelID=UUID();_ = ui.begin(id:cancelID,reference:reference);ui.cancel();ui.fail(MusicDiagnosticFailure(diagnostic:valid),id:cancelID,reference:reference)
        try check(ui.phase == .cancelled,"late_diagnostic_does_not_override_cancel")
        let timeoutID=UUID();_ = ui.begin(id:timeoutID,reference:reference);ui.fail(TransportFailure.timeout,id:timeoutID,reference:reference)
        try check(ui.phase == .timedOut,"scan_wait_timeout_retains_manual_refresh")
        let timeoutTrace=MusicDiagnosticTrace(sink:{_ in});timeoutTrace.fail(TransportFailure.timeout,phase:.qr_poll)
        try check(timeoutTrace.lastFailure?.kind == .timed_out,"scan_wait_not_mislabeled_network_timeout")
        for mode in ["create","poll","account","signing","success","malformed","wrong_sequence","exited"] {
            let box=TraceBox(),trace=MusicDiagnosticTrace(sink:{box.append($0)}),owner=MusicReadProcessOwner()
            let runtime=MusicRuntimeClient(gate:TestGate(),bundleURL:URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent(mode+".app"),processOwner:owner)
            let secret=try synthetic();defer{secret.clear()}
            do {
                let result=try await MusicDiagnostics.$current.withValue(trace) {try await runtime.send(secret,operation:.login,onLoginURL:{_ in})}
                defer{result.credential.clear()}
                try check(!["malformed","wrong_sequence","exited"].contains(mode),"runtime_return_"+mode)
                try check(result.state == (mode=="success" ? .sessionPresentUnverified:.credentialUnconfirmed),"state_"+mode)
            } catch let error as MusicDiagnosticFailure {
                try check(["malformed","wrong_sequence","exited"].contains(mode),"runtime_failure_"+mode)
                try check(error.diagnostic.callID==trace.id,"failure_correlation_"+mode)
            }
            try check(owner.status().provedIdle,"owned_child_cleanup_"+mode)
            try check(!box.values.isEmpty && box.values.allSatisfy{$0.callID==trace.id},"trace_kept_across_detached_task_"+mode)
            if mode=="create" {try check(trace.lastFailure?.code==40101 && trace.lastFailure?.phase == .qr_create,"actual_parser_create_failure")}
            if mode=="account" {try check(trace.lastFailure?.code==301 && trace.lastFailure?.phase == .account_read,"actual_parser_profile_failure")}
            let encoded=String(decoding:try JSONEncoder().encode(box.values),as:UTF8.self)
            try check(!encoded.contains("SYNTHETIC-SECRET") && !encoded.contains("credential") && !encoded.contains("https:"),"no_secret_in_trace_"+mode)
        }
        let repository=FakeRepository(),onboarding=CredentialOnboarding(repository:repository,validator:FakeValidator(),music:FakeMusic())
        do {_=try await onboarding.performMusic(repository.stored.reference,operation:.login);try check(false,"commit_must_fail")}
        catch let error as MusicDiagnosticFailure {try check(error.diagnostic.phase == .token_store && error.diagnostic.kind == .storage_failed,"actual_owner_commit_failure_stage")}
        print(String(decoding:try JSONSerialization.data(withJSONObject:["status":"PASS","checks":checks.count,"passed":checks,"real_keychain_calls":0,"real_provider_calls":0]),as:UTF8.self))
    }
}
