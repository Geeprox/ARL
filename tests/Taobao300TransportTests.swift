import Foundation

@main enum Taobao300TransportTests {
    static func main() async throws {
        var passed: [String] = []
        func check(_ value: Bool, _ name: String) throws {
            guard value else { throw NSError(domain: "Taobao300", code: 1, userInfo: [NSLocalizedDescriptionKey: name]) }
            passed.append(name)
        }
        func bytes(_ value: [String: Any]) throws -> Data { try OwnerReadWire.encode(value, limit: 524_288) }
        func wrap(_ value: [String: Any]) throws -> [String: Any] {
            ["content": [["type": "text", "text": String(decoding: try bytes(value), as: UTF8.self)]]]
        }
        if CommandLine.arguments.contains("--official-pages") {
            var session = TaobaoMCPSession(transport: TaobaoLoopbackHTTP())
            let tools = try await session.discover()
            guard tools.count == 20, tools.contains(where: { $0["name"] as? String == "list_available_pages" }) else { throw TaobaoFault.unsupported }
            let raw = try await session.tool("list_available_pages", arguments: ["sourceApp": "ARL"])
            let payload = try TaobaoProjection.payload(raw)
            guard OwnerReadWire.trueBoolean(payload["success"]), let pages = payload["pages"] as? [[String: Any]],
                  pages.count <= 64, pages.contains(where: { $0["name"] as? String == "home" }) else { throw TaobaoFault.protocolError }
            print(String(decoding: try bytes(["status":"PASS", "production_transport":true, "double_envelope_decoder":true,
                "actual_tool_count":tools.count, "public_preset_count":pages.count, "sourceApp":"ARL",
                "business_writes":0, "raw_response_saved":false, "session_logged":false]), as: UTF8.self))
            return
        }
        let object: [String: Any] = ["jsonrpc":"2.0", "id":7, "result":["text":"商品"]]
        let json = try bytes(object)
        let notification = "data: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\",\"params\":{}}\r\n\r\n"
        let frame = Data((": keepalive\r\n" + notification + "event: message\r\ndata: " + String(decoding: json, as: UTF8.self) + "\r\n\r\n").utf8)
        for size in [1,2,3,7,31,frame.count] {
            var parser = TaobaoSSEResponse(expectedID: 7), result: Data?
            for offset in stride(from: 0, to: frame.count, by: size) {
                let next = try parser.append(frame.subdata(in: offset..<min(offset + size, frame.count)))
                if let next { result = next }
            }
            try check(result == json, "sse_utf8_crlf_fragments_" + String(size))
        }
        var multi = TaobaoSSEResponse(expectedID: 7)
        let multiline = Data("data: {\"jsonrpc\":\"2.0\",\ndata: \"id\":7,\"result\":{}}\n\n".utf8)
        try check(try multi.append(multiline) != nil, "sse_multiline_data")
        var incomplete = TaobaoSSEResponse(expectedID: 7)
        try check(try incomplete.append(Data(("data: " + String(decoding: json, as: UTF8.self) + "\n").utf8)) == nil, "incomplete_event_not_accepted")
        for (name, value) in [
            ("wrong_id", "{\"jsonrpc\":\"2.0\",\"id\":8,\"result\":{}}"),
            ("bool_id", "{\"jsonrpc\":\"2.0\",\"id\":true,\"result\":{}}"),
            ("duplicate_id", "{\"jsonrpc\":\"2.0\",\"id\":7,\"id\":7,\"result\":{}}"),
            ("missing_id", "{\"jsonrpc\":\"2.0\",\"result\":{}}"),
            ("response_and_error", "{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{},\"error\":{}}"),
            ("server_request", "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"credentials\"}")
        ] {
            var parser = TaobaoSSEResponse(expectedID: 7), rejected = false
            do { _ = try parser.append(Data(("data: " + value + "\n\n").utf8)) } catch { rejected = true }
            try check(rejected, "reject_" + name)
        }
        var oversized = TaobaoSSEResponse(expectedID: 7), sizeRejected = false
        do { _ = try oversized.append(Data(repeating: 32, count: 524_289)) } catch { sizeRejected = true }
        try check(sizeRejected, "bounded_incomplete_stream")
        var noisy = TaobaoSSEResponse(expectedID: 7), noiseRejected = false
        do { _ = try noisy.append(Data(String(repeating: notification, count: 129).utf8)) } catch { noiseRejected = true }
        try check(noiseRejected, "bounded_notification_count")
        let products: [String: Any] = ["products":[["title":"Synthetic kettle", "cookie":"synthetic-secret"]]]
        for count in 1...4 {
            var wrapped = products
            for _ in 0..<count { wrapped = try wrap(wrapped) }
            let decoded = try TaobaoProjection.payload(wrapped)
            try check(decoded["products"] is [[String: Any]], "bounded_envelope_" + String(count))
        }
        var tooDeep = products
        for _ in 0..<5 { tooDeep = try wrap(tooDeep) }
        do { _ = try TaobaoProjection.payload(tooDeep); try check(false, "depth_limit") }
        catch is TaobaoFault { try check(true, "depth_limit") }
        var failure = try wrap(try wrap(products)); failure["isError"] = true
        do { _ = try TaobaoProjection.payload(failure); try check(false, "outer_error_retained") }
        catch is TaobaoFault { try check(true, "outer_error_retained") }
        let innerFailure = try wrap(["content":try wrap(products)["content"]!, "isError":true])
        do { _ = try TaobaoProjection.payload(innerFailure); try check(false, "inner_error_retained") }
        catch is TaobaoFault { try check(true, "inner_error_retained") }
        let login = try wrap(["isError":true, "structuredContent":["error":["code":"LOGIN_REQUIRED"]]])
        do { _ = try TaobaoProjection.payload(login); try check(false, "nested_login_marker") }
        catch let error as TaobaoFault { try check(error == .notLoggedIn, "nested_login_marker") }
        let badMarker = try wrap(["isError":"false", "structuredContent":products])
        do { _ = try TaobaoProjection.payload(badMarker); try check(false, "invalid_inner_error_marker") }
        catch let error as TaobaoFault { try check(error == .protocolError, "invalid_inner_error_marker") }
        let projected = try TaobaoProjection.project(TaobaoProjection.payload(wrap(wrap(products))), action:"search_products")
        let projectedText = String(decoding: try bytes(["data":projected]), as: UTF8.self)
        try check(!projectedText.contains("synthetic-secret") && projectedText.contains("Synthetic kettle"), "existing_projection_preserved")
        let page = try TaobaoProjection.payload(wrap(wrap(["url":"https://s.taobao.com/search?q=fixture", "content":"Public title", "totalLength":12])))
        try check(page["content"] as? String == "Public title", "page_text_is_leaf_not_an_envelope")
        let legacy = try MioReadCatalog.descriptors()
        let listed = try MioReadOwnerAdapter.respond(["jsonrpc":"2.0","id":1,"method":"tools/list"], ownerCall: { _,_ in
            try bytes(["tools":[TaobaoTools.statusAction.descriptor]])
        })
        let rows = (listed["result"] as! [String:Any])["tools"] as! [[String:Any]]
        try check(rows.count == 21 && (try bytes(["tools":Array(rows.prefix(20))])) == (try bytes(["tools":legacy])), "amap_fliggy_netease_twenty_descriptors_unchanged")
        for row in legacy {
            let name = row["name"] as! String
            var calls = 0
            let reply = try MioReadOwnerAdapter.respond(["jsonrpc":"2.0","id":2,"method":"tools/call","params":["name":name,"arguments":[:]]], ownerCall: { forwarded,_ in
                guard forwarded == name else { throw OwnerReadFault.invalid }; calls += 1
                return try bytes(["state":"ready"])
            })
            try check(calls == (name == "mio_tunnel_ping" ? 0 : 1)
                && (reply["result"] as! [String:Any])["isError"] as? Bool == false, "legacy_routing_" + name)
        }
        guard let port = UInt16(CommandLine.arguments[1]) else { throw TaobaoFault.invalidArguments }
        let transport = TaobaoLoopbackHTTP.fixture(port: port)
        var session = TaobaoMCPSession(transport: transport)
        let start = ProcessInfo.processInfo.systemUptime
        let actual = try await session.discover()
        try check(actual.count == 20 && ProcessInfo.processInfo.systemUptime - start < 3, "production_transport_does_not_wait_for_sse_eof")
        let raw = try await session.tool("list_available_pages", arguments:["sourceApp":"ARL"])
        try check((try TaobaoProjection.payload(raw))["pages"] is [[String:Any]], "production_transport_double_envelope")
        let redirect = try await transport.post(bytes(["jsonrpc":"2.0","id":1,"method":"fixture_redirect"]), session:nil, version:nil)
        try check(redirect.status == 302, "redirect_not_followed")
        let hold = try bytes(["jsonrpc":"2.0","id":1,"method":"fixture_hold"])
        let task = Task { try await transport.post(hold, session:nil, version:nil) }
        try await Task.sleep(for:.milliseconds(100)); task.cancel()
        do { _ = try await task.value; try check(false, "network_cancellation") }
        catch is CancellationError { try check(true, "network_cancellation") }
        print(String(decoding: try bytes(["status":"PASS","checks":passed.count,"passed":passed,
            "real_cart_writes":0,"official_network_calls":0,"real_credentials_read":0]), as: UTF8.self))
    }
}
