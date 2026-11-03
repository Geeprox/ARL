import Foundation
import Darwin
@testable import ARLCredentialOnboarding

@main enum NASAcceptanceContractTests {
    final class Counter: @unchecked Sendable {
        let lock=NSLock();var value=0
        func increment(){lock.withLock{value+=1}}
    }
    static func main() async throws {
        let configuration=try NASConnectionConfiguration(sourceRef:"synthetic",host:"fixture.invalid",share:"home",root:"ARL-Test")
        try NASAcceptanceProtocol.validate(configuration:configuration,approvedManifestSHA256:NASAcceptanceProtocol.manifestSHA256)
        precondition(NASAcceptanceProtocol.samples.count==6 && Set(NASAcceptanceProtocol.samples.map(\.name)).count==6)
        precondition(NASAcceptanceProtocol.samples.allSatisfy{$0.name.hasPrefix("ARL-Test-20261030-")})
        var checks=1
        for (share,root,hash) in [("home","ARL-Test","0"),("other","ARL-Test",NASAcceptanceProtocol.manifestSHA256),("home","",NASAcceptanceProtocol.manifestSHA256),("home","ARL-Test/subfolder",NASAcceptanceProtocol.manifestSHA256)] {
            let wrong=try NASConnectionConfiguration(sourceRef:"synthetic",host:"fixture.invalid",share:share,root:root)
            do {try NASAcceptanceProtocol.validate(configuration:wrong,approvedManifestSHA256:hash);preconditionFailure("unexpected acceptance authority")}
            catch CredentialError.invalidInput {}
            checks += 1
        }
        // Foundation's resolver can retain macOS's /var alias. Use POSIX
        // realpath so the fixture meets the SDK's O_NOFOLLOW contract.
        guard let temporaryPath=realpath(FileManager.default.temporaryDirectory.path,nil) else{preconditionFailure("temporary root unavailable")}
        let temporaryRoot=String(cString:temporaryPath);free(temporaryPath)
        let home=URL(fileURLWithPath:temporaryRoot,isDirectory:true).appendingPathComponent("arl-nas-acceptance-native-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:home,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        defer {try? FileManager.default.removeItem(at:home)}
        let counter=Counter(),directory=home.appendingPathComponent("grant")
        let alias=home.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at:alias,withDestinationURL:home)
        do {
            _=try NASAcceptanceAuthorization(phase:.create,configuration:configuration,directory:alias.appendingPathComponent("refused"),verify:{})
            preconditionFailure("symlink parent accepted")
        } catch CredentialError.identityMismatch {}
        precondition(!FileManager.default.fileExists(atPath:home.appendingPathComponent("refused").path));checks += 1
        let grant=try NASAcceptanceAuthorization(phase:.create,configuration:configuration,directory:directory,verify:{counter.increment()})
        try grant.authorize(consume:false);try grant.authorize(consume:true)
        do {try grant.authorize(consume:true);preconditionFailure("consume replay")}
        catch CredentialError.staleReference {}
        precondition(counter.value>=4);checks += 1
        try FileManager.default.moveItem(at:directory,to:home.appendingPathComponent("original"))
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        do {try grant.authorize(consume:false);preconditionFailure("directory replaced")}
        catch CredentialError.uncertainLocalState {}
        checks += 1

        func data(_ state:String="complete")throws->Data {
            let files=NASAcceptanceProtocol.samples.map{item in
                ["name":item.name,"size":item.size,"sha256":item.sha256,"state":"created_verified",
                 "object_ref":String(repeating:"a",count:64),"revision":String(repeating:"b",count:64),
                 "object_identity":String(repeating:"c",count:64),"error":NSNull()] as [String:Any]
            }
            return try JSONSerialization.data(withJSONObject:["schema_version":1,"operation":"nas_acceptance","phase":"create", "manifest_sha256":NASAcceptanceProtocol.manifestSHA256,"state":state,"files":files,"automatic_replay":false,"read_scope_changed":false])
        }
        let valid=try data();try NASAcceptanceProtocol.validateResponse(valid,phase:.create);checks += 1
        for phase in [NASAcceptancePhase.cleanup] {
            do {try NASAcceptanceProtocol.validateResponse(valid,phase:phase);preconditionFailure("phase mismatch")}
            catch NASRuntimeFailure.invalidReply {}
            checks += 1
        }
        var modified=try JSONSerialization.jsonObject(with:valid) as! [String:Any]
        modified["read_scope_changed"]=true
        do {try NASAcceptanceProtocol.validateResponse(JSONSerialization.data(withJSONObject:modified),phase:.create);preconditionFailure("scope drift")}
        catch NASRuntimeFailure.invalidReply {}
        checks += 1
        let disabled=CredentialOnboarding.disabled().nas
        do {_=try await disabled.runFixedAcceptance(.create,approvedManifestSHA256:NASAcceptanceProtocol.manifestSHA256);preconditionFailure("disabled owner")}
        catch CredentialError.missing {}
        checks += 1
        let report=try JSONSerialization.data(withJSONObject:["status":"PASS","checks":checks,"network_calls":0,"keychain_calls":0,"real_writes":0],options:[.sortedKeys])
        print(String(decoding:report,as:UTF8.self))
    }
}
