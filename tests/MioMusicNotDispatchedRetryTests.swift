import Foundation
private enum Failure: Error { case assertion }
@main enum MioMusicNotDispatchedRetryTests {
    static func check(_ value: Bool) throws { if !value { throw Failure.assertion } }
    static func main() throws {
        let id = UUID().uuidString.lowercased()
        var calls = 0
        for state in ["not_dispatched", "outcome_unknown"] {
            let response = try MioReadOwnerAdapter.respond(["jsonrpc":"2.0","id":1,"method":"tools/call",
                "params":["name":"mio_netease_playlist_create","arguments":["request_id":id,"intent":"create_playlist","name":"Synthetic playlist","reconcile_only":false]]], ownerCall: { name, raw in
                calls += 1
                let args = try OwnerReadJSON.object(raw, limit: OwnerReadWire.requestLimit)
                try check(name == "mio_netease_playlist_create" && args["request_id"] as? String == id)
                return try OwnerReadWire.encode(["state":state,"request_id":UUID(uuidString:id)!.uuidString,"readback_verified":false],limit:OwnerReadWire.responseLimit)
            })
            let result = response["result"] as! [String:Any]
            let text = (result["content"] as! [[String:Any]])[0]["text"] as! String
            let value = try OwnerReadJSON.object(Data(text.utf8),limit:OwnerReadWire.responseLimit)
            try check(value["automatic_replay"] as? Bool == false)
            if state == "not_dispatched" {
                try check(value["new_submission_allowed"] as? Bool == true)
                try check((value["next_step"] as? String)?.contains("原 request_id") == true)
            } else {
                try check(value["new_submission_allowed"] as? Bool != true)
                try check(value["reconcile_only"] as? Bool == true)
            }
        }
        try check(calls == 2)
        print("{\"status\":\"PASS\",\"groups\":[\"not_dispatched_explicit_original_retry_guidance\",\"unknown_readback_only_guidance\"],\"actual_owner_calls\":0,\"business_calls\":0}")
    }
}
