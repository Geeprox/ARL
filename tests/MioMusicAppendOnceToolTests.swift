import Foundation
import CoreFoundation
private enum Failure: Error { case assertion(String) }
@main enum MioMusicAppendOnceToolTests {
    static func check(_ value: Bool, _ message: String) throws { if !value { throw Failure.assertion(message) } }
    static func main() throws {
        let tool = OwnerReadWire.musicAppendRecovery, id = UUID().uuidString
        let d = OwnerReadWire.musicAppendRecoveryDescriptor, schema = d["inputSchema"] as! [String: Any]
        try check(Set((schema["properties"] as! [String: Any]).keys) == ["request_id"], "only original ID")
        try check(!OwnerReadWire.isReadTool(tool) && OwnerReadWire.isTool(tool) && OwnerReadWire.seconds(for: tool) == 180, "effect classification")
        try check((d["annotations"] as! [String: Any])["readOnlyHint"] as? Bool == false, "not a read")
        let catalog = try MioReadOwnerAdapter.respond(["jsonrpc":"2.0","id":1,"method":"tools/list"], ownerCall: { _, _ in
            try OwnerReadWire.encode(["tools":[TaobaoTools.statusAction.descriptor]], limit: OwnerReadWire.responseLimit)
        })
        let tools = (catalog["result"] as! [String: Any])["tools"] as! [[String: Any]]
        try validateMioPublishedDescriptors(tools)
        try check(tools.filter { $0["name"] as? String == tool }.count == 1, "single exact descriptor")
        var changed = tools
        let index = changed.firstIndex { $0["name"] as? String == tool }!
        changed[index]["annotations"] = ["readOnlyHint":true]
        do { try validateMioPublishedDescriptors(changed); throw Failure.assertion("changed descriptor accepted") }
        catch is ReviewFault {}
        var calls = 0
        let input: [String: Any] = ["jsonrpc":"2.0","id":2,"method":"tools/call","params":["name":tool,"arguments":["request_id":id]]]
        let response = try MioReadOwnerAdapter.respond(input, ownerCall: { name, bytes in
            calls += 1
            let args = try OwnerReadJSON.object(bytes, limit: OwnerReadWire.requestLimit)
            try check(name == tool && Set(args.keys) == ["request_id"] && args["request_id"] as? String == id, "exact forwarding")
            return try OwnerReadWire.encode(["state":"verified","request_id":id,"readback_verified":true,
                "automatic_replay":false,"new_submission_allowed":false], limit: OwnerReadWire.responseLimit)
        })
        try check((response["result"] as! [String: Any])["isError"] as? Bool == false && calls == 1, "verified success")
        let invalid: [[String: Any]] = [["request_id":id,"song_id":"no"],["request_id":"invalid"],["request_id":id,"reconcile_only":true]]
        for args in invalid {
            _ = try MioReadOwnerAdapter.respond(["jsonrpc":"2.0","id":3,"method":"tools/call","params":["name":tool,"arguments":args]],
                ownerCall: { _, _ in calls += 1; throw Failure.assertion("invalid forwarded") })
        }
        try check(calls == 1, "invalid calls never forward")
        let lost = try MioReadOwnerAdapter.respond(input, ownerCall: { _, _ in throw OwnerReadFault.deadline })
        let v = (lost["result"] as! [String: Any])["structuredContent"] as! [String: Any]
        try check(v["state"] as? String == "outcome_unknown" && v["request_id"] as? String == id &&
                  v["automatic_replay"] as? Bool == false && v["reconcile_only"] as? Bool == true, "lost reply preserves ID; readback only")
        print("{\"status\":\"PASS\",\"groups\":[\"exact_descriptor_and_effect_classification\",\"original_UUID_only\",\"no_target_override\",\"lost_reply_readback_only\"],\"real_owner_calls\":0}")
    }
}
