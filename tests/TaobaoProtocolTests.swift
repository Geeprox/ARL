// Explicit synthetic protocol regression. No production accounts or cart calls.
import Foundation
import CryptoKit
import Darwin

final class TaobaoFixtureHTTP: TaobaoHTTPTransport, @unchecked Sendable {
    let behavior: String
    let descriptors: [[String: Any]]
    private let lock = NSLock()
    private var calls: [String] = []
    init(_ behavior: String = "valid", descriptors: [[String: Any]] = TaobaoTestData.tools) {
        self.behavior = behavior; self.descriptors = descriptors
    }
    var toolCalls: Int { lock.withLock { calls.filter { $0 == "tools/call" }.count } }
    var allCalls: [String] { lock.withLock { calls } }
    func post(_ body: Data, session: String?, version: String?) async throws -> TaobaoHTTPReply {
        let request = try OwnerReadJSON.object(body, limit: 16384)
        let method = request["method"] as! String
        lock.withLock { calls.append(method) }
        if behavior == "http401" { return .init(status: 401, mediaType: "application/json", session: nil, body: Data()) }
        if behavior == "unreachable" || behavior == "writeTimeout" && method == "tools/call" { throw TaobaoFault.unreachable }
        if method == "notifications/initialized" { return .init(status: 202, mediaType: "", session: nil, body: Data()) }
        let result: [String: Any]
        switch method {
        case "initialize":
            result = ["protocolVersion": behavior == "badVersion" ? "unreviewed" : "2025-03-26",
                      "capabilities": ["tools": [:]], "serverInfo": ["name": "synthetic-taobao", "version": "1"]]
        case "tools/list":
            result = behavior == "cursorLoop" ? ["tools": [], "nextCursor": "same"] : ["tools": descriptors]
        default:
            if behavior == "loginRequired" { result = ["isError": true, "structuredContent": ["error": ["code": "NOT_LOGGED_IN"]]] }
            else if behavior == "unstructured" { result = ["content": [["type": "text", "text": "Synthetic private page 13800000000"]]] }
            else if (request["params"] as? [String: Any])?["name"] as? String == "add_to_cart" { result = ["structuredContent": ["success": true]] }
            else { result = ["structuredContent": ["products": [TaobaoTestData.product]]] }
        }
        let reply: [String: Any] = ["jsonrpc": "2.0", "id": behavior == "wrongID" ? 999 : request["id"]!, "result": result]
        let json = try OwnerReadWire.encode(reply, limit: 262144)
        if behavior == "sse" {
            return .init(status: 200, mediaType: "text/event-stream", session: "fixture-protocol-id",
                         body: Data(("event: message\r\ndata: " + String(decoding: json, as: UTF8.self) + "\r\n\r\n").utf8))
        }
        return .init(status: 200, mediaType: "application/json", session: "fixture-protocol-id", body: json)
    }
}
enum TaobaoTestData {
    static var tools: [[String: Any]] { [
        ["name": "search_products", "inputSchema": TaobaoTools.schema(["keyword": ["type": "string"]], required: ["keyword"])],
        ["name": "add_to_cart", "inputSchema": TaobaoTools.schema(["itemId": ["type": "string"], "sku": ["type": "array", "items": ["type": "string"]]])],
        ["name": "navigate_to_url", "inputSchema": TaobaoTools.schema(["url": ["type": "string"]], required: ["url"])],
        ["name": "pay", "inputSchema": TaobaoTools.schema([:])]
    ] }
    static var product: [String: Any] { ["itemId": "12345", "title": "Synthetic kettle", "attributes": ["capacity": "1L", "phone": "13800000000"],
        "skuList": [["color": "white", "capacity": "1L"]], "promotions": ["label": "Synthetic offer"], "cookie": "fixture-secret"] }
}
final class TaobaoNoAppleEffects: AppleEffects {
    var calls = 0
    func authorization(_ operation: AppleOperation) -> String { calls += 1; return "not_determined" }
    func lockState() -> String { calls += 1; return "unknown" }
    func resolve(_ binding: TargetBinding) throws -> ResolvedTarget { calls += 1; throw ReviewFault("fixture_forbidden") }
    func save(_ proposal: AppleProposal, target: ResolvedTarget) throws -> String { calls += 1; throw ReviewFault("fixture_forbidden") }
}

@main enum TaobaoProtocolTests {
    static func main() async throws {
        if CommandLine.arguments.contains("--probe") {
            let raw = try await TaobaoRuntime.shared.respond(tool: TaobaoTools.status, arguments: Data("{}".utf8))
            print(String(decoding: raw, as: UTF8.self)); return
        }
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        var passed: [String] = []
        func check(_ condition: Bool, _ label: String) throws {
            guard condition else { throw NSError(domain: "TaobaoTests", code: 1, userInfo: [NSLocalizedDescriptionKey: label]) }; passed.append(label)
        }
        func state(_ raw: Data) throws -> String { try OwnerReadJSON.object(raw, limit: 262144)["state"] as! String }
        func runtime(_ http: TaobaoFixtureHTTP, app: TaobaoAppState = .verifiedListener, journal: String = UUID().uuidString) -> TaobaoRuntime {
            .init(transport: http, app: { app }, admission: .init(directory: root.appendingPathComponent(journal)))
        }
        let bindings = TaobaoBinding.discover(TaobaoTestData.tools)
        try check(bindings.map(\.upstream) == ["search_products", "add_to_cart"], "only_discovered_narrow_tools")
        try check(bindings.allSatisfy { TaobaoTools.validPublished($0.action.descriptor) }, "registry_roundtrip_descriptors")
        let optionalReadTools: [[String: Any]] = ["get_product", "get_product_skus", "get_shop", "get_product_reviews", "get_cart"].map { name in
            let key = name == "get_shop" ? "shopId" : "itemId"
            return ["name": name, "inputSchema": name == "get_cart" ? TaobaoTools.schema([:]) : TaobaoTools.schema([key: ["type":"string"]], required:[key])]
        }
        let conditional = TaobaoBinding.discover(optionalReadTools)
        try check(conditional.count == 5 && conditional.allSatisfy { TaobaoTools.validPublished($0.action.descriptor) }, "optional_dedicated_reads_require_matching_discovered_schema")
        try check((try TaobaoProjection.project(["product":TaobaoTestData.product], action:"get_product") as? [String:Any])?["price"] is NSNull, "detail_nullable_price")
        for (action, field) in [("get_product_skus", "skus"), ("get_product_reviews", "reviews"), ("get_shop", "shop")] {
            let value = try TaobaoProjection.project([field:[["label":"synthetic", "phone":"13800000000"]]], action:action)
            try check(!String(decoding:try jsonBytes(value),as:UTF8.self).contains("13800000000"), "conditional_projection_" + action)
        }
        let cart = bindings[1]
        let id = UUID().uuidString
        let args: [String: Any] = ["itemId": "12345", "sku": ["white", "1L"], "quantity": 1, "request_id": id, "confirmed": true]
        try check(try cart.arguments(args)["quantity"] == nil, "quantity_one_not_forwarded_when_unsupported")
        for (key, value) in [("sku", [] as [String]), ("confirmed", false), ("quantity", 2), ("itemId", "https://evil.invalid"), ("request_id", "bad-id")] as [(String, Any)] {
            var invalid = args; invalid[key] = value
            var rejected = false
            do { _ = try cart.arguments(invalid) } catch { rejected = true }
            try check(rejected, "invalid_cart_" + key + "_rejected")
        }
        var additional = args; additional["url"] = "https://evil.invalid"
        try check(!TaobaoSchema.validate(additional, cart.action.inputSchema), "no_arbitrary_navigation_input")
        let malformed: [[String: Any]] = [["name": "search_products", "inputSchema": ["type": "object", "properties": ["keyword": ["$ref": "unsafe"]]]]]
        try check(TaobaoBinding.discover(malformed).isEmpty, "unknown_schema_not_admitted")
        for app in [TaobaoAppState.absent, .noListener, .identityUnknown] {
            let http = TaobaoFixtureHTTP()
            let raw = try await runtime(http, app: app).respond(tool: TaobaoTools.status, arguments: Data("{}".utf8))
            let expected = app == .absent ? "app_not_running" : app == .noListener ? "unreachable" : "protocol_error"
            try check(try state(raw) == expected && http.allCalls.isEmpty, "app_gate_" + expected)
            try check(TaobaoConnectionState.decode(raw)?.state == expected, "ui_" + expected)
        }
        for (behavior, expected) in [("valid", "protocol_ready"), ("sse", "protocol_ready"), ("http401", "authorization_required"), ("wrongID", "protocol_error"), ("badVersion", "protocol_error"), ("cursorLoop", "protocol_error"), ("unreachable", "unreachable")] {
            let http = TaobaoFixtureHTTP(behavior)
            let raw = try await runtime(http).respond(tool: TaobaoTools.status, arguments: Data("{}".utf8))
            try check(try state(raw) == expected && http.toolCalls == 0, "protocol_" + behavior)
            try check(TaobaoConnectionState.decode(raw)?.state == expected, "ui_protocol_" + behavior)
        }
        let search = try OwnerReadWire.encode(["keyword": "synthetic kettle"], limit: 16384)
        let http = TaobaoFixtureHTTP()
        let result = try await runtime(http).respond(tool: "taobao_search_products", arguments: search)
        let product = (try OwnerReadJSON.object(result, limit: 262144)["data"] as! [[String: Any]])[0]
        try check(try state(result) == "ready" && http.toolCalls == 1, "semantic_search_success")
        try check(product["price"] is NSNull && product["original_price"] is NSNull, "missing_prices_stay_null")
        try check(product["attributes"] != nil && product["skus"] != nil && product["promotion"] != nil, "attributes_skus_promotions_preserved")
        let text = String(decoding: result, as: UTF8.self)
        try check(!text.contains("fixture-secret") && !text.contains("13800000000"), "private_fields_removed")
        for (behavior, expected) in [("loginRequired", "not_logged_in"), ("unstructured", "privacy_held")] {
            let raw = try await runtime(TaobaoFixtureHTTP(behavior)).respond(tool: "taobao_search_products", arguments: search)
            try check(try state(raw) == expected, "semantic_" + behavior)
            try check(TaobaoConnectionState.decode(raw)?.state == expected, "ui_" + behavior)
        }
        let missing = TaobaoFixtureHTTP(descriptors: [])
        let unavailable = try await runtime(missing).respond(tool: "taobao_get_product", arguments: Data("{}".utf8))
        try check(try state(unavailable) == "unsupported" && missing.toolCalls == 0, "missing_tool_never_faked")
        let writeHTTP = TaobaoFixtureHTTP(), writeRuntime = runtime(writeHTTP, journal: "durable-cart")
        let writeArgs = try OwnerReadWire.encode(args, limit: 16384)
        let first = try await writeRuntime.respond(tool: "taobao_add_to_cart", arguments: writeArgs)
        let repeatCall = try await runtime(writeHTTP, journal: "durable-cart").respond(tool: "taobao_add_to_cart", arguments: writeArgs)
        try check(try state(first) == "ready" && state(repeatCall) == "outcome_unknown" && writeHTTP.toolCalls == 1, "cart_restart_does_not_replay")
        var timeoutArgs = args; timeoutArgs["request_id"] = UUID().uuidString
        let timeoutHTTP = TaobaoFixtureHTTP("writeTimeout"), timeoutRuntime = runtime(timeoutHTTP)
        let timeout = try await timeoutRuntime.respond(tool: "taobao_add_to_cart", arguments: OwnerReadWire.encode(timeoutArgs, limit: 16384))
        try check(try state(timeout) == "outcome_unknown" && timeoutHTTP.toolCalls == 1, "cart_timeout_no_retry")
        let catalogue = try await runtime(TaobaoFixtureHTTP()).respond(tool: TaobaoTools.catalog, arguments: Data("{}".utf8))
        let listRequest: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": [:]]
        let mio = try MioReadOwnerAdapter.respond(listRequest, ownerCall: { name, _ in
            guard name == TaobaoTools.catalog else { throw OwnerReadFault.unsupported }; return catalogue
        })
        let published = (mio["result"] as! [String: Any])["tools"] as! [[String: Any]]
        try validateMioPublishedDescriptors(published)
        try check(published.count == 23, "real_mio_adapter_expands_registry")
        let old = try MioReadCatalog.descriptors()
        try check(try jsonBytes(Array(published.prefix(20))) == jsonBytes(old), "travel14_music6_unchanged")
        let noOwner = try MioReadOwnerAdapter.respond(listRequest, ownerCall: { _, _ in throw OwnerReadFault.unavailable })
        try check(((noOwner["result"] as! [String: Any])["tools"] as! [[String: Any]]).count == 21, "owner_unavailable_preserves_legacy_and_status")
        for tool in old {
            let name = tool["name"] as! String
            let reply = try MioReadOwnerAdapter.respond(["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": name, "arguments": [:]]], ownerCall: { forwarded, _ in
                guard forwarded == name else { throw OwnerReadFault.unsupported }
                return try OwnerReadWire.encode(["state": "ready"], limit: 16384)
            })
            try check((reply["result"] as! [String: Any])["isError"] as? Bool == false, "legacy_routing_" + name)
        }
        let privateCall = try MioReadOwnerAdapter.respond(["jsonrpc":"2.0", "id":3, "method":"tools/call", "params":["name":TaobaoTools.catalog, "arguments":[:]]], ownerCall: { _, _ in fatalError("private registry escaped") })
        try check((privateCall["result"] as! [String: Any])["isError"] as? Bool == true, "registry_not_public_execute")
        let effects = TaobaoNoAppleEffects()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("calendar-fixture"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let consumer = MioCalendarConsumer(engine: .init(journal: try ConsumptionJournal(home: root.appendingPathComponent("calendar-fixture").path)), effects: effects, policy: { nil })
        let wrapped = try consumer.respond(listRequest, caller: .fixture(mioSubject), legacy: { _ in mio })
        try check(((wrapped["result"] as! [String: Any])["tools"] as! [[String: Any]]).count == 23 && effects.calls == 0, "calendar_consumer_accepts_exact_registry_suffix_without_effects")
        var tampered = published; tampered[0]["description"] = "changed"
        do { try validateMioPublishedDescriptors(tampered); throw NSError(domain: "should_reject", code: 1) } catch let error as ReviewFault { try check(error.code == "legacy_schema_changed", "legacy_schema_tamper_rejected") }
        var badTool = cart.action.descriptor; badTool["annotations"] = ["readOnlyHint": true]
        try check(!TaobaoTools.validPublished(badTool), "write_risk_tamper_rejected")
        let toolReply = try MioReadOwnerAdapter.respond(["jsonrpc":"2.0", "id":5, "method":"tools/call", "params":["name":"taobao_search_products", "arguments":["keyword":"synthetic"]]], ownerCall: { _, _ in result })
        let toolResult = toolReply["result"] as! [String: Any]
        try check((toolResult["structuredContent"] as? [String: Any])?["state"] as? String == "ready", "new_output_schema_has_structured_content")
        try check(!TaobaoSchema.supported(["type":"string", "maxLength":false]), "invalid_schema_keyword_type_rejected")
        do {
            _ = try TaobaoProjection.payload(["isError":"false", "structuredContent":["products":[]]])
            try check(false, "invalid_error_marker_rejected")
        } catch let fault as TaobaoFault { try check(fault == .protocolError, "invalid_error_marker_rejected") }
        let initReply = try MioReadOwnerAdapter.respond(["jsonrpc":"2.0", "id":4, "method":"initialize", "params":[:]], ownerCall: { _, _ in fatalError("initialize should not contact owner") })
        try check(initReply["result"] != nil, "initialize_health_preserved")
        let catalogBytes = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
        try check(ServiceConnectionCatalog.decode(catalogBytes)?.services.map(\.id) == ["amap", "fliggy", "netease", "taobao"], "actual_swift_service_catalog_has_taobao")
        if CommandLine.arguments.count > 3, let port = UInt16(CommandLine.arguments[3]) {
            let transport = TaobaoLoopbackHTTP.fixture(port: port)
            var realSession = TaobaoMCPSession(transport: transport)
            let realTools = try await realSession.discover()
            try check(realTools.count == 2, "real_loopback_streamable_http_discovery")
            let real = try await realSession.tool("search_products", arguments: ["keyword":"synthetic"])
            try check(try TaobaoProjection.project(TaobaoProjection.payload(real), action: "search_products") is [[String: Any]], "real_loopback_http_projection")
        }
        print(String(decoding: try jsonBytes(["status":"PASS", "checks":passed.count, "passed":passed, "official_network_calls":0, "real_cart_writes":0, "real_credentials_read":0]), as: UTF8.self))
    }
}
