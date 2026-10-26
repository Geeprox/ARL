import Foundation
@testable import ARLCredentialOnboarding

private struct TestGate: DeploymentGate { func verify() throws {} }
private actor MemoryTransport: ProbeTransport {
    private var calls: [(Double,Double)] = []
    func send(_ probe: ProbeRequest) async throws -> ProbeResponse {
        calls.append((probe.remainingSeconds,probe.requestTimeoutSeconds))
        let rpc: [String:Any] = ["jsonrpc":"2.0","id":1,"result":["structuredContent":["status":0,"message":"success","data":"synthetic AI result"]]]
        return .init(status:200,contentType:"application/json",body:try JSONSerialization.data(withJSONObject:rpc))
    }
    func snapshot() -> [(Double,Double)] {calls}
}
private struct TimeoutTransport: ProbeTransport {
    func send(_ probe: ProbeRequest) async throws -> ProbeResponse { throw TransportFailure.timeout }
}
@main enum ReadOnlyAcceptanceRegressionTests {
    static func bytes(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject:value,options:.sortedKeys) }
    static func main() async throws {
        let profile = try FlyAIGatewayProfile(signingSecret:Data("SYNTHETIC-PROFILE".utf8),approvedContext:"SYNTHETIC-CONTEXT",clientTag:"SYNTHETIC-CLIENT")
        let secret = try CredentialInput(purpose:.fliggyTravelReadOnly,value:"SYNTHETIC-FLYAI-KEY-1234567890")
        let memory = MemoryTransport()
        let bounded = BoundedHTTPS(gate:TestGate(),configuration:{
            preconditionFailure("invalid_budget_reached_network_configuration")
        })
        let client = TravelReadClient(transport:memory,flyAIProfile:profile,allowedPurposes:[.fliggyTravelReadOnly])
        let ai=try TravelReadRequest(toolName:"mio_flyai_ai_search",argumentsJSON:bytes(["query":"synthetic query"]))
        let keyword=try TravelReadRequest(toolName:"mio_flyai_keyword_search",argumentsJSON:bytes(["query":"synthetic query"]))
        let aiWire=try client.makeRequest(secret,request:ai)
        precondition(aiWire.remainingSeconds==60 && aiWire.requestTimeoutSeconds==60)
        let result=await client.sendRead(secret,request:ai)
        precondition(result.state == .succeeded)
        let regular=try client.makeRequest(secret,request:keyword)
        precondition(regular.remainingSeconds==10 && regular.requestTimeoutSeconds==8)
        _ = try await memory.send(regular)
        let observed=await memory.snapshot()
        precondition(observed.count==2 && observed[0].0==60 && observed[0].1==60 && observed[1].0==10 && observed[1].1==8)
        var overlong=regular;overlong.remainingSeconds=60;overlong.requestTimeoutSeconds=60
        do {_ = try await bounded.send(overlong);preconditionFailure("credential_probe_budget_widened")}
        catch TransportFailure.timeout {}
        var tooLong=aiWire;tooLong.remainingSeconds=61
        do {_ = try await bounded.send(tooLong);preconditionFailure("ai_budget_unbounded")}
        catch TransportFailure.timeout {}
        let afterGuards = await memory.snapshot()
        precondition(afterGuards.count==2)
        let timeoutClient=TravelReadClient(transport:TimeoutTransport(),flyAIProfile:profile,allowedPurposes:[.fliggyTravelReadOnly])
        let timed = await timeoutClient.sendRead(secret,request:ai)
        precondition(timed.state == .timedOut)
        let cancel=Task {() -> TravelReadResult in
            withUnsafeCurrentTask {$0?.cancel()}
            return await client.sendRead(secret,request:ai)
        }
        let cancelled = await cancel.value
        precondition(cancelled.state == .cancelled)
        let args:[String:Any]=["limit":1,"offset":0]
        let collection=try MusicLibraryReadRequest(toolName:"mio_netease_album_collected",argumentsJSON:bytes(args))
        let record:[String:Any]=["fields":["code":200,"data":["recordCount":0,"records":[["name":"synthetic item"]]]],"omitted_authentication_fields":[]]
        let library:[String:Any]=["operation":"album_collected","parameters":args,"provider_record":record,"coverage":"single_provider_response"]
        let raw:[String:Any]=["state":"authorized_read","session":"present","payload":["complete":false,"library":library]]
        let decoded=try MusicReadProtocol.decode(raw,for:.library(collection))
        precondition(decoded.payload?.library?.returnedRecords==1 && decoded.payload?.complete==false)
        let encoded=try JSONSerialization.jsonObject(with:JSONEncoder().encode(decoded)) as! [String:Any]
        let out=(encoded["payload"] as! [String:Any])["library"] as! [String:Any]
        precondition(out["returned_records"] as? Int==1)
        let original=((out["provider_record"] as! [String:Any])["fields"] as! [String:Any])["data"] as! [String:Any]
        precondition(original["recordCount"] as? Int==0 && (original["records"] as! [Any]).count==1)
        let request:[String:Any]=["jsonrpc":"2.0","id":77,"method":"tools/call","params":["name":"mio_flyai_ai_search","arguments":["query":"synthetic query"]]]
        let reply=try MioReadOwnerAdapter.respond(request,ownerCall:{_,_ in try bytes(["state":"timedOut","payload":NSNull()])})
        let mcp=reply["result"] as! [String:Any],structured=mcp["structuredContent"] as! [String:Any]
        precondition(mcp["isError"] as? Bool==true && structured["state"] as? String=="timedOut" && structured["error_code"] as? String=="UNAVAILABLE")
        precondition(structured["retryable"] as? Bool==true && structured["automatic_retry"] as? Bool==false)
        let text=(mcp["content"] as! [[String:Any]])[0]["text"] as! String
        let textValue=try JSONSerialization.jsonObject(with:Data(text.utf8)) as! [String:Any]
        precondition(NSDictionary(dictionary:textValue).isEqual(to:structured))
        let invalid=try MioReadOwnerAdapter.respond(request,ownerCall:{_,_ in try bytes(["state":"invalidArguments"])})
        precondition(((invalid["result"] as! [String:Any])["structuredContent"] as! [String:Any])["error_code"] == nil)
        precondition(OwnerReadWire.seconds(for:"mio_flyai_ai_search")==75 && OwnerReadWire.seconds(for:"mio_flyai_keyword_search")==20)
        let artist=try MusicLibraryReadRequest(toolName:"mio_netease_artist_songs",argumentsJSON:bytes(["artist_id":String(repeating:"a",count:32),"limit":3,"offset":0,"start_time":1767225600000,"end_time":1792540800000]))
        precondition(artist.parameters["startTime"]=="1767225600000" && artist.parameters["endTime"]=="1792540800000")
        print(String(decoding:try bytes(["status":"PASS","in_memory_transport_responses":2,"probe_request_timeout_budgets":[60,8],"probe_resource_budgets":[60,10],"credential_budget_not_widened":true,"timeout_and_cancel_typed":true,"collection_page1_providerCount0_preserved":true,"Mio_timeout_unavailable_not_invalid":true,"text_equals_structured":true,"artist_milliseconds_unchanged":true,"real_network":false,"real_credentials":false]),as:UTF8.self))
    }
}
