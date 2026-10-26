import Foundation

/// Four decisive fixture scenarios only; no official App probe or provider call.
private final class RobustnessFixture: TaobaoHTTPTransport, @unchecked Sendable {
    let rows: [[String: Any]]
    let mode: String
    var tools: [String] = []
    var initializes = 0
    var reads = 0
    var tabs = 0
    let url = "https://detail.tmall.com/item.htm?id=954227509625"
    init(_ rows: [[String: Any]], _ mode: String = "good") { self.rows = rows; self.mode = mode }
    func post(_ body: Data, session: String?, version: String?) async throws -> TaobaoHTTPReply {
        try await post(body, session: session, version: version, timeout: 4)
    }
    func post(_ body: Data, session: String?, version: String?, timeout: TimeInterval) async throws -> TaobaoHTTPReply {
        guard timeout > 0 else { throw TaobaoFault.unreachable }
        let request = try OwnerReadJSON.object(body, limit: 16384)
        let method = request["method"] as! String
        if method == "notifications/initialized" { return .init(status: 202, mediaType: "", session: nil, body: Data()) }
        var result: [String: Any]
        if method == "initialize" {
            initializes += 1
            if mode == "late" { try await Task.sleep(for: .milliseconds(100)) }
            result = ["protocolVersion": "2025-03-26", "capabilities": ["tools": [:]], "serverInfo": ["name": "fixture"]]
        } else if method == "tools/list" { result = ["tools": rows] }
        else {
            let params = request["params"] as! [String: Any], name = params["name"] as! String
            let args = params["arguments"] as! [String: Any]; tools.append(name)
            guard args["sourceApp"] as? String == "ARL", Taobao300Search.pageTools.contains(name) else { throw TaobaoFault.unsupported }
            let value: [String: Any]
            if name == "navigate_to_url" { value = ["success": true, "url": url] }
            else if name == "get_current_tab" {
                tabs += 1
                value = ["url": mode == "slow" && tabs <= 10 ? "about:blank" : url]
            } else {
                guard args["scope"] as? String == Taobao300PublicProduct.titleScope,
                      OwnerReadWire.integer(args["maxLength"], 512), OwnerReadWire.integer(args["offset"], 0)
                else { throw TaobaoFault.invalidArguments }
                reads += 1
                let text = mode == "slow" && reads == 1 ? "" : "[商品id] 954227509625\n公开测试商品"
                // Explicit complete markers; totalLength is informational and absent.
                value = ["url": mode == "wrong_identity" ? "https://detail.tmall.com/item.htm?id=1" : url,
                         "content": text, "offset": 0, "remainingLength": 0, "truncated": mode == "truncated"]
            }
            result = ["content": [["type": "text", "text": String(decoding: try OwnerReadWire.encode(value, limit: 16384), as: UTF8.self)]]]
        }
        return .init(status: 200, mediaType: "application/json", session: nil,
                     body: try OwnerReadWire.encode(["jsonrpc": "2.0", "id": request["id"]!, "result": result], limit: 524288))
    }
}

@main enum TaobaoRobustnessTests {
    static func main() async throws {
        let catalog = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [[String: Any]]
        var passed: [String] = []
        func check(_ value: Bool, _ name: String) throws {
            guard value else { throw NSError(domain: "TaobaoRobustness", code: 1, userInfo: [NSLocalizedDescriptionKey: name]) }
            passed.append(name)
        }
        let identity = TaobaoBuildIdentity(identifier: "com.taobao.desktop", version: "3.0.1", build: "301")
        @Sendable func generation(_ birth: UInt64) -> TaobaoAppState {
            .verifiedOfficialListener(.init(identity: identity, generation: .init(pid: 101,
                birthSeconds: birth, birthMicroseconds: 1, listener: birth, endpoint: TaobaoLoopbackHTTP.candidateEndpoint)))
        }
        func runtime(_ fixture: RobustnessFixture, app: @escaping @Sendable () async -> TaobaoAppState) -> TaobaoRuntime {
            .init(transport: fixture, app: app, admission: .init(directory: URL(fileURLWithPath: "/unused-robustness")), diagnosticSink: { _ in })
        }
        func product(_ runtime: TaobaoRuntime) async throws -> [String: Any] {
            try OwnerReadJSON.object(await runtime.respond(tool: "taobao_get_product",
                arguments: OwnerReadWire.encode(["url": "https://detail.tmall.com/item.htm?id=954227509625"], limit: 16384)), limit: 524288)
        }

        // R04: same consumed contract plus unrelated tool/description changes.
        var additive = catalog
        for index in additive.indices { additive[index]["description"] = "changed display text" }
        additive.append(["name": "unused_supplier_feature", "inputSchema": ["type": "object", "properties": ["irrelevant": ["oneOf": []]]]])
        var constrained = additive
        let index = constrained.firstIndex { $0["name"] as? String == "read_page_content" }!
        var schema = constrained[index]["inputSchema"] as! [String: Any]
        var fields = schema["properties"] as! [String: Any], length = fields["maxLength"] as! [String: Any]
        length["minimum"] = 256; fields["maxLength"] = length; schema["properties"] = fields; constrained[index]["inputSchema"] = schema
        var required = additive; schema = required[index]["inputSchema"] as! [String: Any]
        schema["required"] = ["sourceApp", "new_required_behavior"]; required[index]["inputSchema"] = schema
        try check(Taobao300Search.catalogMatches(additive)
                  && Taobao300Search.compatibility(constrained, action: "search_products") == .tool_contract_arguments
                  && Taobao300Search.compatibility(constrained, action: "get_product") == nil
                  && Taobao300Search.compatibility(required, action: "get_product") == .tool_contract_required,
                  "R04_additive_catalog_and_only_consumed_contract_incompatibility")

        // R05: upgrade metadata is admissible only after the trusted probe state.
        let upgraded = RobustnessFixture(additive), wrongOwner = RobustnessFixture(additive), noPort = RobustnessFixture(additive)
        let upgradeResult = try await product(runtime(upgraded, app: { generation(1) }))
        let publisherRejected = try await product(runtime(wrongOwner, app: { .identityUnknown }))
        let portRejected = try await product(runtime(noPort, app: { .noListener }))
        let writeRejected = try OwnerReadJSON.object(await runtime(upgraded, app: { generation(1) }).respond(tool: "taobao_add_to_cart",
            arguments: OwnerReadWire.encode([:], limit: 16384)), limit: 524288)
        try check(identity.qualifies(transport: "streamable_http") && upgradeResult["ready"] as? Bool == true
                  && publisherRejected["ready"] as? Bool == false && portRejected["ready"] as? Bool == false
                  && wrongOwner.initializes == 0 && noPort.initializes == 0
                  && writeRejected["state"] as? String == "unsupported" && !upgraded.tools.contains("add_to_cart"),
                  "R05_signed_probe_upgrade_with_identity_endpoint_and_write_rejection")

        // R06: same PID but different birth/socket invalidates the old result.
        let restarted = RobustnessFixture(additive)
        let first = try await product(runtime(restarted, app: { generation(restarted.reads == 0 ? 1 : 2) }))
        let second = try await product(runtime(restarted, app: { generation(2) }))
        try check(first["ready"] as? Bool == false && first["data"] == nil
                  && first["reason_code"] as? String == "process_generation_changed"
                  && second["ready"] as? Bool == true && restarted.initializes == 2
                  && restarted.tools.filter { $0 == "navigate_to_url" }.count == 2,
                  "R06_old_generation_not_published_next_explicit_read_rediscovers")

        // R07: render exceeds the old 8-poll window; one budget, same scope/id.
        let slow = RobustnessFixture(additive, "slow"), truncated = RobustnessFixture(additive, "truncated")
        let wrongID = RobustnessFixture(additive, "wrong_identity"), late = RobustnessFixture(additive, "late")
        let rendered = try await product(runtime(slow, app: { generation(1) }))
        let truncatedResult = try await product(runtime(truncated, app: { generation(1) }))
        let wrongResult = try await product(runtime(wrongID, app: { generation(1) }))
        var short = TaobaoMCPSession(transport: late, deadline: ProcessInfo.processInfo.systemUptime + 0.05)
        var lateRejected = false
        do { _ = try await short.discover() } catch TaobaoFault.unreachable { lateRejected = true }
        try check(rendered["ready"] as? Bool == true && slow.tools.filter { $0 == "navigate_to_url" }.count == 1
                  && slow.reads == 3 && truncatedResult["data"] == nil && wrongResult["data"] == nil
                  && lateRejected && late.tools.isEmpty,
                  "R07_slow_complete_scope_with_truncation_identity_and_late_reply_rejection")
        print(String(decoding: try OwnerReadWire.encode(["status": "PASS", "checks": passed.count, "passed": passed,
            "fixture_only": true, "real_business_calls": 0, "native_permissions": 0], limit: 16384), as: UTF8.self))
    }
}
