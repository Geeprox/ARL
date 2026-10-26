import Foundation
@main enum MioMusicBusinessOutputTests {
    static func main()throws {
        let fixture=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))) as! [String:Any]
        for key in ["read","failure"] {
            let payload=fixture[key] as! [String:Any]
            let reply=try MioReadOwnerAdapter.respond(["jsonrpc":"2.0","id":1,"method":"tools/call","params":["name":"mio_netease_song_search","arguments":["keyword":"Sample"]]],ownerCall:{name,args in
                precondition(name=="mio_netease_song_search");return try OwnerReadWire.encode(payload,limit:OwnerReadWire.responseLimit)
            })
            let result=reply["result"] as! [String:Any],structured=result["structuredContent"] as! [String:Any]
            let text=(result["content"] as! [[String:Any]])[0]["text"] as! String
            let parsed=try OwnerReadJSON.object(Data(text.utf8),limit:OwnerReadWire.responseLimit)
            precondition(NSDictionary(dictionary:structured).isEqual(to:payload) && NSDictionary(dictionary:parsed).isEqual(to:payload))
            precondition(result["isError"] as? Bool == (key=="failure"))
        }
        let failed=try MioReadOwnerAdapter.respond(["jsonrpc":"2.0","id":2,"method":"tools/call","params":["name":"mio_netease_song_search","arguments":["keyword":"Sample"]]],ownerCall:{_,_ in throw OwnerReadFault.unavailable})
        precondition((failed["result"] as? [String:Any])?["structuredContent"] is [String:Any])
        print("{\"status\":\"PASS\",\"text_and_structured_preserve_same_business_payload\":true,\"owner_calls_mocked\":true}")
    }
}
