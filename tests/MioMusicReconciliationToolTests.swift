import Foundation
import CoreFoundation

private enum Failure: Error { case assertion }
@main enum MioMusicReconciliationToolTests {
    static func check(_ value: Bool) throws { if !value { throw Failure.assertion } }
    static func main() throws {
        let id = UUID().uuidString, tool = OwnerReadWire.musicReconcile
        let descriptor = OwnerReadWire.musicReconcileDescriptor
        let schema = descriptor["inputSchema"] as! [String: Any]
        try check(schema["required"] as? [String] == ["request_id"])
        try check(Set((schema["properties"] as! [String: Any]).keys) == ["request_id"])
        try check((descriptor["annotations"] as! [String: Any])["readOnlyHint"] as? Bool == true)
        let catalog = try MioReadOwnerAdapter.respond(["jsonrpc":"2.0","id":1,"method":"tools/list"], ownerCall: { _, _ in
            try OwnerReadWire.encode(["tools":[TaobaoTools.statusAction.descriptor]], limit: OwnerReadWire.responseLimit)
        })
        let tools = (catalog["result"] as! [String: Any])["tools"] as! [[String: Any]]
        try validateMioPublishedDescriptors(tools)
        try check(tools.last?["name"] as? String == tool)
        var calls = 0
        let response = try MioReadOwnerAdapter.respond(["jsonrpc":"2.0","id":2,"method":"tools/call",
            "params":["name":tool,"arguments":["request_id":id]]], ownerCall: { name, raw in
            calls += 1; try check(name == tool)
            let arguments = try OwnerReadJSON.object(raw, limit: OwnerReadWire.requestLimit)
            try check(Set(arguments.keys) == ["request_id"] && arguments["request_id"] as? String == id)
            return try OwnerReadWire.encode(["state":"record_missing","request_id":id,
                "automatic_replay":false,"new_submission_allowed":false,"readback_verified":false], limit: OwnerReadWire.responseLimit)
        })
        let value = (response["result"] as! [String: Any])["structuredContent"] as! [String: Any]
        try check(value["state"] as? String == "record_missing" && calls == 1)
        try check((response["result"] as! [String: Any])["isError"] as? Bool == false)
        _ = try MioReadOwnerAdapter.respond(["jsonrpc":"2.0","id":3,"method":"tools/call",
            "params":["name":tool,"arguments":["request_id":id,"name":"must not create"]]], ownerCall: { _, _ in
            calls += 1; throw Failure.assertion
        })
        try check(calls == 1)
        print("{\"status\":\"PASS\",\"group\":\"named_readonly_reconcile_tool\",\"exact_id_only\":true,\"descriptor_verified\":true,\"write_invocations\":0}")
    }
}
