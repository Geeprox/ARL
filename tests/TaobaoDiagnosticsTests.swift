import Foundation

private func wire(_ value:[String:Any]) throws -> Data { try OwnerReadWire.encode(value,limit:524_288) }
private func wrap(_ value:[String:Any]) throws -> [String:Any] {
    ["content":[["type":"text","text":String(decoding:try wire(value),as:UTF8.self)]]]
}

private final class DiagnosticCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [TaobaoDiagnostic] = []
    func append(_ value: TaobaoDiagnostic) { lock.withLock { entries.append(value) } }
    var values: [TaobaoDiagnostic] { lock.withLock { entries } }
}
private final class AppSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var index = 0
    let sequence: [TaobaoAppState]
    init(_ sequence: [TaobaoAppState]) { self.sequence = sequence }
    func next() -> TaobaoAppState { lock.withLock { defer { index += 1 }; return sequence[min(index, sequence.count - 1)] } }
}

@main enum TaobaoDiagnosticsTests {
    static func main() async throws {
        let catalog = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [[String: Any]]
        let root = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        var passed: [String] = []
        func check(_ result: Bool, _ name: String) throws {
            guard result else { throw NSError(domain: "TaobaoDiagnostics", code: 1, userInfo: [NSLocalizedDescriptionKey: name]) }
            passed.append(name)
        }
        func consumer(_ name: String, _ value: [String: Any]) throws -> [String: Any] {
            let bytes = try wire(value)
            let request: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": name, "arguments": [:]]]
            return try MioReadOwnerAdapter.respond(request, ownerCall: { _, _ in bytes })["result"] as! [String: Any]
        }
        func runtime(_ fixture: SearchFixture, _ capture: DiagnosticCapture, _ states: [TaobaoAppState] = [.verified300Listener]) -> TaobaoRuntime {
            let app = AppSequence(states)
            return .init(transport: fixture, app: { app.next() }, admission: .init(directory: root.appendingPathComponent("unused")), diagnosticSink: { capture.append($0) })
        }
        let capture = DiagnosticCapture(), statusFixture = SearchFixture(catalog)
        let status = try OwnerReadJSON.object(await runtime(statusFixture, capture).respond(tool: TaobaoTools.status, arguments: wire([:])), limit: 524288)
        let statusReply = try consumer(TaobaoTools.status, status)
        try check(status["state"] as? String == "protocol_ready" && status["ready"] as? Bool == false && status["login"] as? String == "not_checked", "production_status_retains_unready_login_semantics")
        try check(statusReply["isError"] as? Bool == false && (statusReply["structuredContent"] as? [String: Any])?["endpoint_verified"] as? Bool == true, "actual_status_shape_is_successful_query")
        try check(statusFixture.calls.isEmpty && capture.values.isEmpty, "status_has_no_business_or_privacy_event")
        try check(TaobaoConnectionState.decode(try wire(status))?.state == "protocol_ready", "production_UI_accepts_status")
        try check(try consumer("taobao_search_products", status)["isError"] as? Bool == true, "protocol_ready_business_response_not_success")
        try check(try consumer("mio_netease_connection_status", status)["isError"] as? Bool == true, "protocol_ready_exception_not_applied_to_music")
        for (field, bad) in [("ready", true), ("ready", 0), ("endpoint_verified", false), ("endpoint_verified", 1), ("login", "authorized"), ("transport", "stdio")] as [(String, Any)] {
            var malformed = status; malformed[field] = bad
            try check(try consumer(TaobaoTools.status, malformed)["isError"] as? Bool == true, "malformed_status_\(passed.count)")
        }
        let music: [String: Any] = ["state": "requires_setup", "configuration": "configured", "login": "login_required", "ready": false, "writes": "requires_setup"]
        let musicReply = try consumer("mio_netease_connection_status", music)
        try check(musicReply["isError"] as? Bool == true && musicReply["structuredContent"] == nil, "actual_music_shape_and_mapping_unchanged")
        // Original observed failed shape has no invented diagnostic reason.
        let priorFailure: [String: Any] = ["state": "privacy_held", "endpoint_verified": false, "ready": false, "login": "not_checked", "available_actions": []]
        let priorReply = try consumer("taobao_search_products", priorFailure)
        try check(priorReply["isError"] as? Bool == true && (priorReply["structuredContent"] as? [String: Any])?["reason_code"] == nil, "actual_prior_failure_not_relabelled_or_fabricated")

        // Installed Mio observed this shape on 2026-10-10. A verified
        // endpoint is prior evidence; a failed business read is still a failure.
        let businessFailure: [String: Any] = ["state": "unreachable", "ready": false,
            "endpoint_verified": true, "login": "not_checked", "available_actions": ["search_products"],
            "unsupported_actions": ["get_product", "get_product_skus", "get_shop", "get_product_reviews", "get_cart", "add_to_cart"],
            "phase": "business_read", "reason_code": "unreachable"]
        let incomplete = TaobaoConnectionState.decode(try wire(businessFailure))
        try check(incomplete?.endpointVerified == true && incomplete?.businessReadIncomplete == true && incomplete?.title == "商品读取未完成", "observed_verified_business_failure_has_precise_UI_title")
        try check(incomplete?.state == "unreachable" && incomplete?.diagnostic?.reason == "unreachable" && incomplete?.diagnostic?.phase == .business_read, "business_failure_preserves_original_state_and_reason")
        try check(incomplete?.explanation.contains("失败原因尚未确定") == true && incomplete?.explanation.contains("账号登录状态未检查") == true, "business_failure_does_not_invent_cause_or_account_readiness")
        let businessReply = try consumer("taobao_search_products", businessFailure)
        try check(businessReply["isError"] as? Bool == true && (businessReply["structuredContent"] as? [String: Any])?["ready"] as? Bool == false, "business_failure_remains_Mio_error_and_unready")
        for verified in [false, nil] as [Bool?] {
            var value = businessFailure
            if let verified { value["endpoint_verified"] = verified }
            else { value.removeValue(forKey: "endpoint_verified") }
            let model = TaobaoConnectionState.decode(try wire(value))
            try check(model?.endpointVerified == false && model?.businessReadIncomplete == false && model?.title == "本机连接失败", "unverified_failure_has_no_prior_connection_claim_\(verified == nil ? "absent" : "false")")
        }
        var endpointFailure = businessFailure; endpointFailure["phase"] = "endpoint_recheck"
        try check(TaobaoConnectionState.decode(try wire(endpointFailure))?.businessReadIncomplete == false, "endpoint_recheck_failure_not_relabelled_as_business_read")
        for malformed in [1, "true", NSNull()] as [Any] {
            var value = businessFailure; value["endpoint_verified"] = malformed
            try check(TaobaoConnectionState.decode(try wire(value)) == nil, "UI_endpoint_verification_requires_JSON_boolean_\(passed.count)")
        }
        let oldReady: [String: Any] = ["state": "ready", "ready": true]
        try check(TaobaoConnectionState.decode(try wire(oldReady))?.title == "操作完成", "old_ready_shape_without_endpoint_still_accepted")

        let cases: [(String, String, String)] = [
            ("reply_blocks", "navigation", "reply_block_count"),
            ("wrong_page", "navigation_scope", "search_url_scope"),
            ("read_wrong_url", "page_read", "search_url_scope"),
            ("content_type", "page_read", "content_type"),
            ("content_length_limit", "page_read", "content_length_limit"),
            ("offset_mismatch", "page_read", "content_offset"),
            ("remaining_length", "page_read", "content_remaining_length"),
            ("length_mismatch", "page_read", "content_total_length"),
            ("numeric_truncated", "page_read", "truncated_type"),
            ("truncated", "page_read", "content_truncated"),
            ("missing_first", "title_validation", "first_title_missing"),
            ("title_text_invalid", "title_validation", "title_text_invalid"),
            ("replaced_title", "title_recheck", "title_changed")
        ]
        var ids = Set<UUID>()
        for (mode, phase, reason) in cases {
            let f = SearchFixture(catalog, mode), c = DiagnosticCapture()
            let value = try OwnerReadJSON.object(await runtime(f, c).respond(tool: "taobao_search_products", arguments: wire(["keyword": "保温杯", "limit": 3])), limit: 524288)
            try check(value["state"] as? String == "privacy_held" && value["ready"] as? Bool == false && value["data"] == nil, "privacy_still_blocks_" + mode)
            try check(value["phase"] as? String == phase && value["reason_code"] as? String == reason, "precise_safe_reason_" + mode)
            try check(value["endpoint_verified"] as? Bool == true && value["available_actions"] as? [String] == ["search_products", "get_product"], "prior_identity_and_catalog_retained_" + mode)
            try check(c.values.count == 1 && c.values[0].phase.rawValue == phase && c.values[0].reason.rawValue == reason, "one_typed_event_" + mode)
            let event = c.values[0]; ids.insert(event.callID)
            let encoded = try JSONEncoder().encode(event), object = try OwnerReadJSON.object(encoded, limit: 4096)
            try check(Set(object.keys) == ["schema", "call_id", "phase", "reason_code"] && value["diagnostic_id"] as? String == event.callID.uuidString, "closed_correlated_diagnostic_" + mode)
            try check(!String(decoding: encoded, as: UTF8.self).contains("PRIVATE") && !String(decoding: encoded, as: UTF8.self).contains("保温杯") && !String(decoding: encoded, as: UTF8.self).contains("http"), "no_response_values_in_event_" + mode)
            try check(try consumer("taobao_search_products", value)["isError"] as? Bool == true && TaobaoConnectionState.decode(try wire(value))?.state == "privacy_held", "production_consumers_retain_failure_" + mode)
            try check(f.calls.filter { $0 == "navigate_to_url" }.count == 1, "no_navigation_retry_" + mode)
        }
        try check(ids.count == cases.count, "request_diagnostics_do_not_reuse_ids")
        for mode in ["good", "missing_price", "title_contains_secret"] {
            let f = SearchFixture(catalog, mode), c = DiagnosticCapture()
            let value = try OwnerReadJSON.object(await runtime(f, c).respond(tool: "taobao_search_products", arguments: wire(["keyword": "保温杯", "limit": 3])), limit: 524288)
            try check(value["ready"] as? Bool == true && c.values.isEmpty && (try consumer("taobao_search_products", value))["isError"] as? Bool == false, "valid_search_preserved_" + mode)
            try check(!String(decoding: try wire(value), as: UTF8.self).contains("DIAGNOSTIC_SECRET"), "privacy_redaction_preserved_" + mode)
        }
        let loginFixture = SearchFixture(catalog, "login"), loginCapture = DiagnosticCapture()
        let login = try OwnerReadJSON.object(await runtime(loginFixture, loginCapture).respond(tool: "taobao_search_products", arguments: wire(["keyword": "保温杯", "limit": 3])), limit: 524288)
        try check(login["state"] as? String == "not_logged_in" && login["ready"] as? Bool == false && login["endpoint_verified"] as? Bool == true && login["data"] == nil, "login_required_never_promoted_to_ready")
        try check(try consumer("taobao_search_products", login)["isError"] as? Bool == true, "login_required_remains_business_failure")
        let lost = SearchFixture(catalog), lostCapture = DiagnosticCapture()
        let changed = try OwnerReadJSON.object(await runtime(lost, lostCapture, [.verified300Listener, .identityUnknown]).respond(tool: "taobao_search_products", arguments: wire(["keyword": "保温杯", "limit": 3])), limit: 524288)
        try check(changed["endpoint_verified"] as? Bool == false && changed["phase"] as? String == "endpoint_recheck" && (changed["available_actions"] as? [String])?.isEmpty == true && lost.calls.isEmpty, "actual_identity_change_invalidates_evidence_and_prevents_business")
        let absent = SearchFixture(catalog), absentCapture = DiagnosticCapture()
        let unverified = try OwnerReadJSON.object(await runtime(absent, absentCapture, [.identityUnknown]).respond(tool: TaobaoTools.status, arguments: wire([:])), limit: 524288)
        try check(unverified["endpoint_verified"] as? Bool == false && unverified["phase"] as? String == "app_identity" && absent.calls.isEmpty, "unknown_initial_identity_not_claimed_verified")

        // Direct projection boundaries retain the original error enum identity.
        func held(_ expected: TaobaoDiagnostic.Reason, _ body: () throws -> Void) throws {
            let trace = TaobaoDiagnosticTrace()
            var rejected = false
            try TaobaoDiagnostics.$current.withValue(trace) {
                do { try body() } catch let e as TaobaoFault { rejected = e == .privacyHeld }
            }
            try check(rejected && trace.lastFailure?.reason == expected, "projection_" + expected.rawValue)
        }
        try held(.reply_block_type) { _ = try TaobaoProjection.payload(["content": [["type": "image"]]]) }
        try held(.reply_text_type) { _ = try TaobaoProjection.payload(["content": [["type": "text", "text": 1]]]) }
        try held(.reply_json_invalid) { _ = try TaobaoProjection.payload(["content": [["type": "text", "text": "PRIVATE_UNPARSEABLE"]]]) }
        try held(.reply_unwrapped) { _ = try TaobaoProjection.payload(["private": "PRIVATE_RAW"]) }
        try held(.reply_error_marker) { _ = try TaobaoProjection.payload(["isError": true, "data": ["public": 1]]) }
        var deep: [String: Any] = ["public": 1]; for _ in 0..<6 { deep = ["data": deep] }
        try held(.reply_nesting_limit) { _ = try TaobaoProjection.payload(deep) }
        try held(.products_type) { _ = try TaobaoProjection.project(["products": 1], action: "search_products") }
        try held(.products_count) { _ = try TaobaoProjection.project(["products": Array(repeating: ["title": "x"], count: 101)], action: "search_products") }
        try held(.projection_field_missing) { _ = try TaobaoProjection.project([:], action: "get_shop") }
        try held(.product_identity_missing) { _ = try TaobaoProjection.product([:]) }
        var nested: Any = "x"; for _ in 0..<9 { nested = [nested] }
        try held(.value_depth_limit) { _ = try TaobaoProjection.product(["title": nested]) }
        try held(.object_count_limit) { _ = try TaobaoProjection.product(["title": Dictionary(uniqueKeysWithValues: (0..<129).map { ("x\($0)", "x") })]) }
        try held(.array_count_limit) { _ = try TaobaoProjection.product(["title": Array(repeating: "x", count: 129)]) }
        try held(.string_length_limit) { _ = try TaobaoProjection.product(["title": String(repeating: "x", count: 16385)]) }
        try held(.value_type) { _ = try TaobaoProjection.product(["title": Date()]) }
        print(String(decoding: try wire(["status": "PASS", "checks": passed.count, "passed": passed, "production_consumer": true, "real_network_requests": 0, "real_credentials_read": 0, "desktop_operations": 0]), as: UTF8.self))
    }
}
private final class SearchFixture: TaobaoHTTPTransport, @unchecked Sendable {
    let catalog:[[String:Any]]
    let mode:String
    var calls:[String]=[]
    var argumentsValid=true
    var tabs=0
    var titleReads:[Int:Int]=[:]
    init(_ catalog:[[String:Any]],_ mode:String="good") { self.catalog=catalog;self.mode=mode }
    func post(_ body:Data,session:String?,version:String?) async throws -> TaobaoHTTPReply {
        let req=try OwnerReadJSON.object(body,limit:524_288)
        let method=req["method"] as! String
        if method=="notifications/initialized" { return .init(status:202,mediaType:"",session:nil,body:Data()) }
        let result:[String:Any]
        if method=="initialize" {
            let client=((req["params"] as? [String:Any])?["clientInfo"] as? [String:Any])?["name"] as? String
            argumentsValid = argumentsValid && client=="ARL"
            result=["protocolVersion":"2025-03-26","capabilities":["tools":[:]],"serverInfo":["name":"taobao-native-mcp","version":"1.0.0"]]
        } else if method=="tools/list" { result=["tools":catalog] }
        else {
            let params=req["params"] as! [String:Any], name=params["name"] as! String, args=params["arguments"] as! [String:Any]
            calls.append(name)
            argumentsValid = argumentsValid && args["sourceApp"] as? String=="ARL"
            let url=Taobao300Search.searchURL("保温杯")
            var payload:[String:Any]
            switch name {
            case "navigate_to_url":
                argumentsValid = argumentsValid && Set(args.keys)==["sourceApp","url"] && args["url"] as? String==url
                payload=["success":true,"url":url]
                if mode=="navigation_failed" { payload["success"]=false }
            case "get_current_tab":
                argumentsValid = argumentsValid && Set(args.keys)==["sourceApp"]
                tabs+=1
                payload=["url":mode=="blank_then_ready" && tabs==1 ? "about:blank":url]
                if mode=="login" { payload["url"]="https://login.taobao.com/member/login.jhtml" }
                if mode=="wrong_page" || (mode=="changed_page" && tabs>3) { payload["url"]="https://buyertrade.taobao.com/trade/itemlist/list_bought_items.htm" }
            case "read_page_content":
                let scope=args["scope"] as! String
                let isTitle=scope.hasSuffix(" [class*=title--] span")
                let rank=(1...3).first { scope.contains(":nth-of-type(\($0))") } ?? 0
                let expected=Taobao300Search.cardSelector+":nth-of-type(\(rank))"+(isTitle ? " [class*=title--] span":" [class*=innerPriceWrapper--]")
                argumentsValid = argumentsValid && rank>0 && scope==expected && Set(args.keys)==["sourceApp","scope","maxLength","offset"]
                    && OwnerReadWire.integer(args["offset"],0) && OwnerReadWire.integer(args["maxLength"],isTitle ? 512:128)
                titleReads[rank,default:0] += isTitle ? 1:0
                var text=isTitle ? "合成保温杯 \(rank)" : "29.90"
                if mode=="ambiguous_price" && !isTitle { text="券后 29.9 起" }
                if mode=="replaced_title" && isTitle && titleReads[rank,default:0]>1 { text="替换商品" }
                payload=["url":url,"title":"PRIVATE_BROWSER_TITLE","content":text,"offset":0,"remainingLength":0,"totalLength":text.utf16.count,"truncated":false,"account":"PRIVATE_ACCOUNT"]
                if mode=="read_wrong_url" { payload["url"]="https://i.taobao.com/" }
                if mode=="truncated" { payload["truncated"]=true }
                if mode=="content_type" { payload["content"]=7 }
                if mode=="content_length_limit" { payload["content"]=String(repeating:"x",count:513) }
                if mode=="remaining_length" { payload["remainingLength"]=1 }
                if mode=="title_text_invalid" { let invalid=String(repeating:"杯",count:180);payload["content"]=invalid;payload["totalLength"]=invalid.utf16.count }
                if mode=="title_contains_secret" && isTitle { payload["content"]="合成 token=DIAGNOSTIC_SECRET";payload["totalLength"]=(payload["content"] as! String).utf16.count }
                if mode=="numeric_truncated" { payload["truncated"]=0 }
                if mode=="length_mismatch" { payload["totalLength"]=999 }
                if mode=="offset_mismatch" { payload["offset"]=1 }
                if mode=="inner_failure" { payload=["data":["success":false]] }
                if mode=="missing_price" && !isTitle || mode=="missing_first" || mode=="one_card" && rank>1 || mode=="delayed_first" && rank==1 && titleReads[rank,default:0]==1 {
                    payload=["error":"未找到scope容器: "+scope]
                }
            default: throw TaobaoFault.unsupported
            }
            if mode=="reply_blocks" { result=["content":[]] }
            else { result=try wrap(wrap(payload)) }
        }
        return .init(status:200,mediaType:"application/json",session:nil,body:try wire(["jsonrpc":"2.0","id":req["id"]!,"result":result]))
    }
}

