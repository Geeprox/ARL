import Foundation
@main enum MioPlaylistMetadataTests {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let list = try MioReadOwnerAdapter.respond(["jsonrpc":"2.0","id":1,"method":"tools/list"], ownerCall: {_,_ in throw OwnerReadFault.unavailable})
        let tools = (list["result"] as! [String:Any])["tools"] as! [[String:Any]]
        precondition(tools.count == 77)
        try validateMioPublishedDescriptors(tools)
        try jsonBytes(OwnerReadWire.musicMetadataDescriptors).write(to: root.appendingPathComponent("TOOL-SCHEMAS.json"))
        var cases = [String]()
        for rename in [true,false] {
            let tool = rename ? "mio_netease_playlist_update_name" : "mio_netease_playlist_update_desc"
            let field = rename ? "new_name" : "description"
            let id = UUID().uuidString
            let args: [String:Any] = ["request_id":id,"intent":rename ? "update_playlist_name":"update_playlist_description","playlist_id":String(repeating:"a",count:32),"playlist_name":"Synthetic playlist",field:rename ? "New title":""]
            let call: ([String:Any])->[String:Any] = { ["jsonrpc":"2.0","id":2,"method":"tools/call","params":["name":tool,"arguments":$0]] }
            var calls = 0
            let success = try MioReadOwnerAdapter.respond(call(args),ownerCall: { name,data in
                calls += 1;precondition(name == tool)
                let received = try OwnerReadJSON.object(data,limit:OwnerReadWire.requestLimit)
                precondition(NSDictionary(dictionary:received).isEqual(to:args))
                return try jsonBytes(["state":"verified","request_id":id,"playlist_id":args["playlist_id"]!,"readback_verified":true])
            })
            let successResult = success["result"] as! [String:Any]
            precondition(calls == 1 && successResult["isError"] as? Bool == false)
            cases.append(tool+"/verified")
            let unknown = try MioReadOwnerAdapter.respond(call(args),ownerCall: {_,_ in throw OwnerReadFault.deadline})
            let result = unknown["result"] as! [String:Any],value=result["structuredContent"] as! [String:Any]
            precondition(value["state"] as? String == "outcome_unknown" && value["request_id"] as? String == id && value["automatic_replay"] as? Bool == false && value["new_submission_allowed"] as? Bool == false)
            let text=(result["content"] as! [[String:Any]])[0]["text"] as! String
            let parsed = try OwnerReadJSON.object(Data(text.utf8),limit:OwnerReadWire.responseLimit)
            precondition(NSDictionary(dictionary:value).isEqual(to:parsed))
            cases.append(tool+"/uncertain_preserves_UUID")
            var invalids = [[String:Any]]()
            var bad=args;bad["intent"]="append_song";invalids.append(bad)
            bad=args;bad["song_id"]=String(repeating:"b",count:32);invalids.append(bad)
            bad=args;bad["reconcile_only"]=1;invalids.append(bad)
            bad=args;bad[field]=rename ? "-bad":"\u{0}";invalids.append(bad)
            bad=args;bad[field]=String(repeating:"x",count:rename ? 101:1001);invalids.append(bad)
            bad=args;bad["playlist_id"]="not-an-id";invalids.append(bad)
            for invalid in invalids {
                let reply = try MioReadOwnerAdapter.respond(call(invalid),ownerCall:{_,_ in calls += 1;throw OwnerReadFault.unavailable})
                precondition((reply["result"] as? [String:Any])?["isError"] as? Bool == true && calls == 1)
            }
            cases.append(tool+"/6_invalid_before_owner")
            var query=args;query["reconcile_only"]=true
            _ = try OwnerReadWire.metadataIntent(tool,query)
        }
        var modified=tools
        let i=modified.firstIndex(where:{$0["name"] as? String == "mio_netease_playlist_update_name"})!
        modified[i]["description"]="changed"
        do {try validateMioPublishedDescriptors(modified);preconditionFailure("modified schema accepted")}catch is ReviewFault {}
        let report: [String:Any] = ["status":"PASS","cases":cases,"invalid_before_owner":12,"catalog_count":tools.count,"catalog_sha256":digest(try jsonBytes(tools)),"exact_catalog_validation":true,"real_network":0,"real_writes":0]
        print(String(decoding:try jsonBytes(report),as:UTF8.self))
    }
}
