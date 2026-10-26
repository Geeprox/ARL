import Foundation

private final class PublicProductFixture: TaobaoHTTPTransport, @unchecked Sendable {
    let catalog: [[String: Any]]
    let fixture: [String: Any]
    let mode: String
    var calls: [String] = []
    var reads = 0
    init(_ catalog: [[String: Any]], _ fixture: [String: Any], _ mode: String = "good") {
        self.catalog = catalog; self.fixture = fixture; self.mode = mode
    }
    func post(_ body: Data, session: String?, version: String?) async throws -> TaobaoHTTPReply {
        let request = try OwnerReadJSON.object(body, limit: 524288)
        let method = request["method"] as! String
        if method == "notifications/initialized" { return .init(status: 202, mediaType: "", session: nil, body: Data()) }
        let result: [String: Any]
        if method == "initialize" {
            result = ["protocolVersion": "2025-03-26", "capabilities": ["tools": [:]], "serverInfo": ["name": "taobao-native-mcp", "version": "1.0.0"]]
        } else if method == "tools/list" { result = ["tools": catalog] }
        else {
            let params = request["params"] as! [String: Any], name = params["name"] as! String, args = params["arguments"] as! [String: Any]
            calls.append(name)
            guard args["sourceApp"] as? String == "ARL" else { throw TaobaoFault.invalidArguments }
            var value: [String: Any] = [:]
            let url = fixture["url"] as! String
            switch name {
            case "navigate_to_url":
                guard Set(args.keys) == ["sourceApp", "url"], args["url"] as? String == url else { throw TaobaoFault.invalidArguments }
                value = ["success": true, "url": url]
            case "get_current_tab":
                guard Set(args.keys) == ["sourceApp"] else { throw TaobaoFault.invalidArguments }
                value = ["url": mode == "wrong_page" ? "https://buyertrade.taobao.com/trade/itemlist/list_bought_items.htm" : mode == "login" ? "https://login.taobao.com/member/login.jhtml" : url]
            case "read_page_content":
                guard Set(args.keys) == ["sourceApp", "scope", "maxLength", "offset"], args["scope"] as? String == Taobao300PublicProduct.titleScope,
                      OwnerReadWire.integer(args["maxLength"], 512), OwnerReadWire.integer(args["offset"], 0) else { throw TaobaoFault.invalidArguments }
                reads += 1
                var text = fixture["raw_title_scope_text"] as! String
                if mode == "wrong_marker" { text = text.replacingOccurrences(of: fixture["product_id"] as! String, with: "1") }
                if mode == "changed_title" && reads == 2 { text += "替换商品" }
                value = ["url": url, "content": text, "offset": 0, "remainingLength": 0, "totalLength": text.utf16.count, "truncated": false, "account": "PRIVATE_ACCOUNT", "title": "PRIVATE_PAGE_TITLE"]
                if mode == "numeric_truncated" { value["truncated"] = 0 }
                if mode == "truncated" { value["truncated"] = true }
                if mode == "wrong_length" { value["totalLength"] = 1 }
                if mode == "wrong_read_url" { value["url"] = "https://detail.tmall.com/item.htm?id=1" }
            default: throw TaobaoFault.unsupported // No clicks, cart, SKU, history or order reads.
            }
            result = ["content": [["type": "text", "text": String(decoding: try OwnerReadWire.encode(value, limit: 16384), as: UTF8.self)]]]
        }
        return .init(status: 200, mediaType: "application/json", session: nil,
                     body: try OwnerReadWire.encode(["jsonrpc": "2.0", "id": request["id"]!, "result": result], limit: 524288))
    }
}

@main enum TaobaoPublicProductTests {
    static func main() async throws {
        let catalog = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [[String: Any]]
        let fixture = try OwnerReadJSON.object(Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])), limit: 16384)
        let url = fixture["url"] as! String
        var passed: [String] = []
        func check(_ value: Bool, _ name: String) throws {
            guard value else { throw NSError(domain: "TaobaoPublicProduct", code: 1, userInfo: [NSLocalizedDescriptionKey: name]) }; passed.append(name)
        }
        func wire(_ value: [String: Any]) throws -> Data { try OwnerReadWire.encode(value, limit: 524288) }
        func runtime(_ transport: PublicProductFixture) -> TaobaoRuntime {
            .init(transport: transport, app: { .verified300Listener }, admission: .init(directory: URL(fileURLWithPath: "/unused-public-read")), diagnosticSink: { _ in })
        }
        let link = Taobao300PublicProduct.Link(url)!
        try check(link.id == fixture["product_id"] as? String && link.url == url, "actual_observed_identity_is_preserved")
        for bad in [url + "&skuId=1", url + "&id=1", url + "#cart", url.replacingOccurrences(of: "https", with: "http"), url.replacingOccurrences(of: "detail.tmall.com", with: "item.taobao.com"), "https://detail.tmall.com@evil.example/item.htm?id=1", "https://detail.tmall.com/item.htm?id=%31"] {
            try check(Taobao300PublicProduct.Link(bad) == nil, "unqualified_or_noncanonical_input_\(passed.count)")
        }
        let good = PublicProductFixture(catalog, fixture)
        let result = try OwnerReadJSON.object(await runtime(good).respond(tool: "taobao_get_product", arguments: wire(["url": url])), limit: 524288)
        try check(result["state"] as? String == "ready" && result["login"] as? String == "not_checked", "completed_public_read_not_account_readiness")
        let product = result["data"] as! [String: Any]
        try check(product["title"] as? String == fixture["expected_title"] as? String && product["product_id"] as? String == link.id && product["url"] as? String == url, "supplier_marker_removed_only_after_matching_identity")
        try check(product["price"] is NSNull && product["skus"] is NSNull && product["selected_sku"] is NSNull, "no_price_or_SKU_invented")
        try check(good.reads == 2 && good.calls.filter { $0 == "navigate_to_url" }.count == 1 && Set(good.calls).isSubset(of: ["navigate_to_url", "get_current_tab", "read_page_content"]), "bounded_reads_and_no_transaction_or_DOM_calls")
        try check(TaobaoPublicProductResult.decode(try wire(result))?.id == link.id && TaobaoConnectionState.decode(try wire(result))?.state == "ready", "actual_App_consumers_accept_named_projection")
        let request: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": "taobao_get_product", "arguments": ["url": url]]]
        let mio = try MioReadOwnerAdapter.respond(request, ownerCall: { _, _ in try wire(result) })["result"] as! [String: Any]
        try check(mio["isError"] as? Bool == false && (mio["structuredContent"] as? [String: Any])?["login"] as? String == "not_checked", "existing_Mio_named_consumer_keeps_projection_and_unknown_account")
        for mode in ["wrong_page", "wrong_marker", "changed_title", "numeric_truncated", "truncated", "wrong_length", "wrong_read_url", "login"] {
            let transport = PublicProductFixture(catalog, fixture, mode)
            let failed = try OwnerReadJSON.object(await runtime(transport).respond(tool: "taobao_get_product", arguments: wire(["url": url])), limit: 524288)
            try check(failed["ready"] as? Bool == false && failed["data"] == nil, "no_partial_product_on_" + mode)
            try check(transport.calls.filter { $0 == "navigate_to_url" }.count == 1, "no_navigation_replay_on_" + mode)
            if mode == "wrong_page" || mode == "login" { try check(transport.reads == 0, "no_account_or_wrong_page_text_read_" + mode) }
        }
        for (field, forged) in [("product_id", "1"), ("price", "99"), ("skus", ["x"]), ("account", "PRIVATE_ACCOUNT")] as [(String, Any)] {
            var row = product; row[field] = forged; var malformed = result; malformed["data"] = row
            try check(TaobaoPublicProductResult.decode(try wire(malformed)) == nil, "App_rejects_forged_field_" + field)
        }
        let invalid = PublicProductFixture(catalog, fixture)
        let rejected = try OwnerReadJSON.object(await runtime(invalid).respond(tool: "taobao_get_product", arguments: wire(["url": url, "scope": "body"])), limit: 524288)
        try check(rejected["state"] as? String == "invalid_arguments" && invalid.calls.isEmpty, "callers_cannot_expand_scope_before_any_business_call")
        print(String(decoding: try wire(["status": "PASS", "checks": passed.count, "passed": passed, "real_business_calls": 0, "fixture_only": true]), as: UTF8.self))
    }
}
