import Foundation

@main @MainActor enum MusicReadFailureTests {
    static let correlation=UUID(uuidString:"00000000-0000-4000-8000-000000000002")!
    static let request=MusicReadRequest.search(keyword:"Synthetic query")
    static var checks=0
    static func require(_ condition:Bool) {precondition(condition);checks += 1}
    static func rejected(_ raw:[String:Any], id:UUID=correlation) {
        do {_=try MusicReadProtocol.decode(raw,for:request,correlationID:id);preconditionFailure("synthetic_invalid_failure_accepted")}
        catch {checks += 1}
    }
    static func base() -> [String:Any] {
        ["state":"contract_rejected","session":"present","payload":NSNull(),"failure":[
            "reason":"cli_output_too_large","stage":"cli_output","retryable":false,"automatic_retry":false,
            "correlation_id":correlation.uuidString,"http_status":200,"local_code":-97062,
            "next_step":"inspect_adapter","output_bytes":1048577,"output_limit_bytes":1048576]]
    }
    static func changed(_ key:String,_ value:Any) -> [String:Any] {
        var raw=base(),failure=raw["failure"] as! [String:Any];failure[key]=value;raw["failure"]=failure;return raw
    }
    static func main() throws {
        let result=try MusicReadProtocol.decode(base(),for:request,correlationID:correlation)
        require(result.state == .contractRejected && result.payload == nil)
        require(result.failure?.reason == .cliOutputTooLarge && result.failure?.httpStatus == 200)
        require(result.failure?.correlationID == correlation && result.failure?.retryable == false)
        let output=try JSONSerialization.jsonObject(with:JSONEncoder().encode(result)) as! [String:Any]
        require(output["payload"] == nil && (output["failure"] as? [String:Any])?["correlation_id"] as? String == correlation.uuidString)
        rejected(changed("reason","SYNTHETIC-PRIVATE-TEXT"))
        rejected(changed("stage","provider_response"))
        rejected(changed("retryable",true));rejected(changed("automatic_retry",true))
        rejected(changed("next_step","refine_search_keywords"));rejected(changed("next_step","retry_read_manually"));rejected(changed("output_bytes",true));rejected(changed("output_limit_bytes",0))
        rejected(changed("provider_payload","SYNTHETIC-PRIVATE-PAYLOAD"))
        rejected(changed("http_status",0));rejected(changed("http_status",600));rejected(changed("http_status",true))
        rejected(changed("local_code",123));rejected(changed("local_code",-97027))
        rejected(base(),id:UUID(uuidString:"00000000-0000-4000-8000-000000000003")!)
        var wrong=base();wrong["state"]="authorized_read";rejected(wrong)
        var network=base(),failure=network["failure"] as! [String:Any]
        network["state"]="provider_unavailable";failure["reason"]="provider_unavailable";failure["stage"]="provider_response"
        failure["retryable"]=true;failure["http_status"]=NSNull();failure["local_code"]=NSNull();failure["next_step"]="retry_read_manually";failure["output_bytes"]=NSNull();failure["output_limit_bytes"]=NSNull();network["failure"]=failure
        let unavailable=try MusicReadProtocol.decode(network,for:request,correlationID:correlation)
        require(unavailable.failure?.retryable == true && unavailable.failure?.httpStatus == nil)
        let publicNetwork=try JSONSerialization.jsonObject(with:JSONEncoder().encode(unavailable)) as! [String:Any]
        let publicFailure=publicNetwork["failure"] as! [String:Any]
        require(publicFailure["http_status"] == nil && publicFailure["local_code"] == nil)
        var formatting=base(),formatFailure=formatting["failure"] as! [String:Any]
        let formatLimit=1048576+(1048576+1)*(1+2*16)
        formatFailure["output_bytes"]=formatLimit+1;formatFailure["output_limit_bytes"]=formatLimit;formatting["failure"]=formatFailure
        let formatResult=try MusicReadProtocol.decode(formatting,for:request,correlationID:correlation)
        require(formatResult.failure?.outputLimitBytes==formatLimit && formatResult.failure?.nextStep == .inspectAdapter)
        rejected(changed("output_limit_bytes",1048577))
        let legacy=try MusicReadProtocol.decode(["state":"contract_rejected","session":"present","payload":NSNull()],for:request)
        require(legacy.failure == nil)
        print("{\"status\":\"PASS\",\"checks\":\(checks),\"real_credentials\":false,\"business_calls\":0}")
    }
}
