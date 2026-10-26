import Foundation

private enum PublicationFixtureFailure: Error { case failed(String) }
@main enum MioPublicationEvidenceTests {
    static func require(_ value: Bool, _ label: String) throws {
        if !value { throw PublicationFixtureFailure.failed(label) }
    }
    static func main() throws {
        let state = MioCatalogPublicationEvidence()
        let list: [String: Any] = ["jsonrpc": "2.0", "id": "request-id-must-not-be-retained", "method": "tools/list"]
        let ping: [String: Any] = ["method": "tools/call", "params": ["name": "mio_tunnel_ping", "arguments": [:]]]
        let pong: [String: Any] = ["jsonrpc": "2.0", "id": 8, "result": ["isError": false, "content": [["type": "text", "text": "pong from mac-mini"]]]]
        let catalog: [[String: Any]] = [["name": "mio_tunnel_ping", "description": "not exported", "inputSchema": ["type": "object"]],
                                      ["name": "mio_netease_playlist_reconcile", "inputSchema": ["type": "object"]]]
        let reply: [String: Any] = ["jsonrpc": "2.0", "id": "request-id-must-not-be-retained", "result": ["tools": catalog]]
        try require(state.snapshot()["tools_list_replies_sent"] as? Int == 0, "no_fabricated_observation")
        _ = state.decoratePing(pong, request: ping)
        try require(state.snapshot()["tools_list_replies_sent"] as? Int == 0, "ping_never_invokes_catalog")
        state.recordSent(request: ping, response: reply)
        try require(state.snapshot()["tools_list_replies_sent"] as? Int == 0, "non_catalog_not_recorded")
        state.recordSent(request: list, response: reply)
        let snapshot = state.snapshot()
        let last = snapshot["last_tools_list_reply"] as! [String: Any]
        try require(last["tool_count"] as? Int == 2, "actual_count")
        try require(last["sorted_json_tools_sha256"] as? String == digest(try jsonBytes(catalog)), "exact_descriptor_hash")
        try require(snapshot["connector_schema_acceptance_verified"] as? Bool == false, "no_cloud_claim")
        let encoded = String(decoding: try jsonBytes(snapshot), as: UTF8.self)
        try require(!encoded.contains("request-id-must-not-be-retained") && !encoded.contains("not exported"), "no_ids_or_descriptions_retained")
        let decorated = state.decoratePing(pong, request: ping)
        let content = (decorated["result"] as! [String: Any])["content"] as! [[String: Any]]
        try require(content.count == 2 && content[0]["text"] as? String == "pong from mac-mini", "existing_ping_preserved")
        let business: [String: Any] = ["method": "tools/call", "params": ["name": "mio_netease_playlist_create", "arguments": [:]]]
        try require(try jsonBytes(state.decoratePing(pong, request: business)) == jsonBytes(pong), "business_response_unchanged")
        let failed: [String: Any] = ["error": ["code": -32602, "message": "private error must not escape", "data": "private body"]]
        state.recordSent(request: list, response: failed)
        let error = state.snapshot()["last_tools_list_reply"] as! [String: Any]
        try require(error["jsonrpc_error_code"] as? Int == -32602 && error["message"] == nil && error["data"] == nil, "bounded_error_projection")
        state.recordSent(request: list, response: ["result": ["tools": [["name": "unsafe\nname"]]]])
        try require((state.snapshot()["last_tools_list_reply"] as! [String: Any])["state"] as? String == "metadata_unavailable", "invalid_names_closed")
        let fresh = MioCatalogPublicationEvidence()
        try require(fresh.snapshot()["tools_list_replies_sent"] as? Int == 0, "generation_reset")
        print("{\"status\":\"PASS\",\"scope\":\"synthetic_publication_metadata_only\",\"live_catalog_verified\":false}")
    }
}
