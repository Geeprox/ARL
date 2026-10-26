import Foundation
@testable import ARLCredentialOnboarding

// Consumes only the synthetic network-denied SDK completion fixture. Exercises
// the same native authentication-field policy used by MusicRuntimeClient.
@main enum CoverTokenNativeDecodeTests {
    static func main() throws {
        let bytes=try Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))
        let raw=try MusicStrictJSON.object(bytes,limit:bytes.count,maximumDepth:32)
        precondition(raw["state"] as? String == "not_submitted")
        let original=raw["provider_exchange"] as! [String:Any]
        let exchange=try MusicReadProtocol.providerRecord(original)
        var fields=original["fields"] as! [String:Any]
        var validation=fields["cover_token_validation"] as! [String:Any]
        var types=validation["types"] as! [String:Any]
        precondition(types["token"] == nil && types["token_type"] as? String == "string")
        precondition(validation["failed_rules"] as? [String] == ["bucket_yyimgs"])
        // The old key must remain rejected; do not weaken the native policy.
        types["token"]=types.removeValue(forKey:"token_type")
        validation["types"]=types;fields["cover_token_validation"]=validation
        var rejected=original;rejected["fields"]=fields
        var oldRejected=false
        do {_ = try MusicReadProtocol.providerRecord(rejected)} catch {oldRejected=true}
        precondition(oldRejected)
        let secret=try CredentialInput(purpose:.neteaseMusic,data:MusicEnvelope.seed(appID:"SYNTHETIC",privateKey:String(repeating:"S",count:64)))
        defer {secret.clear()}
        let effect=MusicPlaylistCoverEffect(state:"not_submitted",credential:secret,providerExchange:exchange)
        precondition(effect.state=="not_submitted" && effect.resourceID==nil && effect.uploadReceipts.isEmpty)
        print("{\"status\":\"PASS\",\"native_provider_record_accepted\":true,\"typed_not_submitted_effect_constructed\":true,\"old_authentication_key_rejected\":true,\"policy_weakened\":false,\"real_credentials\":0,\"real_network\":0}")
    }
}
