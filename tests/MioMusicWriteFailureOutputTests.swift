import Foundation
@main enum MioMusicWriteFailureOutputTests {
    static func main() throws {
        let requestID=UUID().uuidString, message=String(repeating:"original business explanation ",count:1200)
        let arguments:[String:Any] = ["request_id":requestID,"intent":"append_song","playlist_name":"Synthetic playlist","playlist_id":String(repeating:"1",count:32),"song_id":String(repeating:"2",count:32)]
        let call:[String:Any] = ["jsonrpc":"2.0","id":1,"method":"tools/call","params":["name":"mio_netease_playlist_append_song","arguments":arguments]]
        let body:[String:Any] = ["code":200,"subCode":10007,"message":message,"data":[["songId":String(repeating:"2",count:32),"code":501,"msg":"per item explanation"]]]
        for state in ["readback_failed","song_absent","incomplete_read","outcome_unknown"] {
            let payload:[String:Any] = ["state":state,"request_id":requestID,"readback_verified":false,"provider_result":["fields":["body":body],"omitted_authentication_fields":[]]]
            let reply=try MioReadOwnerAdapter.respond(call,ownerCall:{_,_ in try OwnerReadWire.encode(payload,limit:OwnerReadWire.responseLimit)})
            let result=reply["result"] as! [String:Any], value=result["structuredContent"] as! [String:Any]
            precondition(value["state"] as? String == state && value["automatic_replay"] as? Bool == false && value["new_submission_allowed"] as? Bool == false)
            precondition(NSDictionary(dictionary:value["provider_result"] as! [String:Any]).isEqual(to:payload["provider_result"] as! [String:Any]))
            let text=(result["content"] as! [[String:Any]])[0]["text"] as! String
            let parsed=try OwnerReadJSON.object(Data(text.utf8),limit:OwnerReadWire.responseLimit,maximumDepth:32)
            precondition(NSDictionary(dictionary:value).isEqual(to:parsed) && result["isError"] as? Bool == true)
        }
        let fault=try MioReadOwnerAdapter.respond(call,ownerCall:{_,_ in throw OwnerReadFault.businessLogUnavailable})
        let value=(fault["result"] as! [String:Any])["structuredContent"] as! [String:Any]
        precondition((value["error"] as? [String:Any])?["code"] as? String == "business_log_unavailable")
        precondition(value["request_id"] as? String == requestID && value["automatic_replay"] as? Bool == false)
        print("{\"status\":\"PASS\",\"full_write_error_text_and_structured_preserved\":true,\"fault_code_preserved\":true,\"real_network\":0}")
    }
}
