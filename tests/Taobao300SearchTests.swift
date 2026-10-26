import Foundation

private func wire(_ value:[String:Any]) throws -> Data { try OwnerReadWire.encode(value,limit:524_288) }
private func wrap(_ value:[String:Any]) throws -> [String:Any] {
    ["content":[["type":"text","text":String(decoding:try wire(value),as:UTF8.self)]]]
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
                if mode=="numeric_truncated" { payload["truncated"]=0 }
                if mode=="length_mismatch" { payload["totalLength"]=999 }
                if mode=="offset_mismatch" { payload["offset"]=1 }
                if mode=="inner_failure" { payload=["data":["success":false]] }
                if mode=="missing_price" && !isTitle || mode=="missing_first" || mode=="one_card" && rank>1 || mode=="delayed_first" && rank==1 && titleReads[rank,default:0]==1 {
                    payload=["error":"未找到scope容器: "+scope]
                }
            default: throw TaobaoFault.unsupported
            }
            result=try wrap(wrap(payload))
        }
        return .init(status:200,mediaType:"application/json",session:nil,body:try wire(["jsonrpc":"2.0","id":req["id"]!,"result":result]))
    }
}

@main enum Taobao300SearchTests {
    static func main() async throws {
        let catalog=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))) as! [[String:Any]]
        var passed:[String]=[]
        func check(_ value:Bool,_ name:String) throws {
            guard value else { throw NSError(domain:"Taobao300Search",code:1,userInfo:[NSLocalizedDescriptionKey:name]) }
            passed.append(name)
        }
        if CommandLine.arguments.contains("--live-search") {
            let value=try OwnerReadJSON.object(await TaobaoRuntime.shared.respond(tool:"taobao_search_products",arguments:wire(["keyword":"保温杯","limit":3])),limit:524_288)
            guard OwnerReadWire.trueBoolean(value["ready"]),let products=value["data"] as? [[String:Any]],!products.isEmpty,products.count<=3 else {
                print(String(decoding:try wire(["status":"HOLD","state":value["state"] ?? "missing","production_runtime":true]),as:UTF8.self));return
            }
            let summaries=products.map { ["result_rank":$0["result_rank"]!,"title":$0["title"]!,"price":$0["price"]!,"product_id_unknown":$0["product_id"] is NSNull,"url_unknown":$0["url"] is NSNull,"skus_unknown":$0["skus"] is NSNull] as [String:Any] }
            print(String(decoding:try wire(["status":"PASS","production_runtime":true,"app_gate_bypassed":false,"products":summaries,"sourceApp":"ARL","real_cart_writes":0,"credentials_read":0,"installed_writes":0]),as:UTF8.self));return
        }
        func runtime(_ fixture:SearchFixture) -> TaobaoRuntime {
            .init(transport:fixture,app:{.verified300Listener},admission:.init(directory:URL(fileURLWithPath:"/invalid/never-opened")))
        }
        func search(_ fixture:SearchFixture,_ args:[String:Any]=["keyword":"保温杯","limit":3]) async throws -> [String:Any] {
            try OwnerReadJSON.object(await runtime(fixture).respond(tool:"taobao_search_products",arguments:wire(args)),limit:524_288)
        }
        if !Taobao300Search.catalogMatches(catalog) {
            let canonical=try wire(["tools":catalog.sorted { ($0["name"] as! String)<($1["name"] as! String) }])
            try canonical.write(to:URL(fileURLWithPath:CommandLine.arguments[1]).deletingLastPathComponent().appendingPathComponent("catalog-canonical.json"),options:.atomic)
        }
        try check(Taobao300Search.catalogMatches(catalog),"exact_actual_catalog_digest")
        try check(Taobao300Search.catalogMatches(Array(catalog.reversed())),"catalog_order_independent")
        func reordered(_ value:Any) -> Any {
            if let object=value as? [String:Any] {
                return object.keys.sorted(by:>).reduce(into:[String:Any]()) { $0[$1]=reordered(object[$1]!) }
            }
            if let array=value as? [Any] { return array.map(reordered) }
            return value
        }
        try check(Taobao300Search.catalogMatches(reordered(catalog) as! [[String:Any]]),"nested_key_order_independent")
        var drift=catalog;drift[0]["description"]="changed"
        for rows in [drift,Array(catalog.dropLast()),catalog+[catalog[0]]] { try check(!Taobao300Search.catalogMatches(rows),"catalog_drift_\(passed.count)") }
        for (id,version,build,transport,expected) in [
            ("com.taobao.desktop","3.0.0","3.0.0","streamable_http",true),
            ("com.taobao.desktop","3.0.1","3.0.0","streamable_http",false),
            ("com.taobao.desktop","3.0.0","3.0.1","streamable_http",false),
            ("com.taobao.pcdesktop","3.0.0","3.0.0","streamable_http",false),
            ("com.taobao.desktop","3.0.0","3.0.0","stdio",false)] {
            try check(TaobaoBuildIdentity(identifier:id,version:version,build:build).qualifies(transport:transport)==expected,"identity_\(passed.count)")
        }
        let query="杯 & ? # + 中文"
        try check(Taobao300Search.isSearch(Taobao300Search.searchURL(query),keyword:query),"query_encoding")
        for url in ["http://s.taobao.com/search?q=x","https://s.taobao.com.evil/search?q=x","https://u@s.taobao.com/search?q=x","https://s.taobao.com/search?q=x&q=x","https://s.taobao.com/account?q=x"] {
            try check(!Taobao300Search.isSearch(url,keyword:"x"),"url_reject_\(passed.count)")
        }
        for args:[String:Any] in [[:],["keyword":""],["keyword":"\n"],["keyword":String(repeating:"x",count:65)],["keyword":"x","limit":0],["keyword":"x","limit":4],["keyword":"x","limit":true],["keyword":"x","limit":1.5],["keyword":"x","sourceApp":"other"],["keyword":"x","url":"https://example.org"],["keyword":"x","scope":"body"]] {
            let f=SearchFixture(catalog),reply=try await search(f,args)
            try check(reply["state"] as? String=="invalid_arguments" && f.calls.isEmpty,"input_reject_\(passed.count)")
        }
        let good=SearchFixture(catalog),value=try await search(good)
        let products=value["data"] as? [[String:Any]] ?? []
        try check(OwnerReadWire.trueBoolean(value["ready"]) && products.count==3,"three_cards_ready")
        try check(value["login"] as? String == "not_checked", "completed_search_does_not_claim_login")
        try check(TaobaoProductResult.decodeSearch(try wire(value))?.count == 3, "actual_app_consumer_accepts_completed_search")
        try check(TaobaoConnectionState.decode(try wire(value))?.capabilities.count == 5, "actual_app_consumer_decodes_capability_reasons")
        try check(products.enumerated().allSatisfy { i,p in p["title"] as? String=="合成保温杯 \(i+1)" && p["price"] as? String=="29.90" && p["product_id"] is NSNull && p["url"] is NSNull && p["skus"] is NSNull },"title_price_and_unknown_fields")
        try check(!String(decoding:try wire(value),as:UTF8.self).contains("PRIVATE_"),"page_private_metadata_not_projected")
        try check(good.argumentsValid && Set(good.calls)==["navigate_to_url","get_current_tab","read_page_content"] && good.calls.filter{$0=="navigate_to_url"}.count==1,"fixed_three_primitives_and_sourceApp")
        for mode in ["blank_then_ready","delayed_first","one_card","missing_price","ambiguous_price"] {
            let f=SearchFixture(catalog,mode),reply=try await search(f)
            let rows=reply["data"] as? [[String:Any]] ?? []
            try check(OwnerReadWire.trueBoolean(reply["ready"]) && rows.count==(mode=="one_card" ? 1:3),"success_"+mode)
            if mode=="missing_price" || mode=="ambiguous_price" {
                try check(rows.allSatisfy{$0["price"] is NSNull},"unknown_"+mode)
                try check(rows.allSatisfy{ ($0["unknown_fields"] as? [String])?.contains("price")==true },"unknown_price_declared_"+mode)
            }
        }
        for (mode,state) in [("navigation_failed","protocol_error"),("login","not_logged_in"),("wrong_page","privacy_held"),("changed_page","privacy_held"),("read_wrong_url","privacy_held"),("truncated","privacy_held"),("numeric_truncated","privacy_held"),("length_mismatch","privacy_held"),("offset_mismatch","privacy_held"),("inner_failure","protocol_error"),("replaced_title","privacy_held"),("missing_first","privacy_held")] {
            let f=SearchFixture(catalog,mode),reply=try await search(f)
            try check(reply["state"] as? String==state && !OwnerReadWire.trueBoolean(reply["ready"]) && reply["data"]==nil,"hold_"+mode)
        }
        let missing=["error":"未找到scope容器: fixture"]
        for bad in [try wrap(["success":false,"data":missing]),["isError":true,"data":missing],try wrap(["error":"different"])] {
            var rejected=false
            do { _=try TaobaoProjection.payload(bad,missingScope:"fixture") }
            catch let fault as TaobaoFault { rejected=fault != .unsupported }
            try check(rejected,"missing_scope_does_not_hide_failure_\(passed.count)")
        }
        let f=SearchFixture(catalog),r=runtime(f)
        let listed=try OwnerReadJSON.object(await r.respond(tool:TaobaoTools.catalog,arguments:wire([:])),limit:524_288)
        let rows=listed["tools"] as! [[String:Any]]
        try check(rows.count==3 && rows.allSatisfy(TaobaoTools.validPublished),"only_status_search_and_known_public_product_published")
        for name in TaobaoTools.targets where !["search_products", "get_product"].contains(name) {
            let reply=try OwnerReadJSON.object(await r.respond(tool:"taobao_"+name,arguments:wire([:])),limit:524_288)
            try check(reply["state"] as? String=="unsupported" && f.calls.isEmpty,"unbound_"+name)
        }
        var incomplete = value
        incomplete["state"] = "privacy_held"; incomplete["ready"] = false
        try check(TaobaoProductResult.decodeSearch(try wire(incomplete)) == nil, "failed_search_never_displays_partial_results")
        var malformed = products
        malformed[0]["price"] = true; incomplete = value; incomplete["data"] = malformed
        try check(TaobaoProductResult.decodeSearch(try wire(incomplete)) == nil, "app_rejects_boolean_price")
        malformed = products; malformed[0]["result_rank"] = 2; incomplete["data"] = malformed
        try check(TaobaoProductResult.decodeSearch(try wire(incomplete)) == nil, "app_rejects_duplicate_or_wrong_rank")
        malformed = products; malformed[0]["url"] = "https://example.org/forged"; incomplete["data"] = malformed
        try check(TaobaoProductResult.decodeSearch(try wire(incomplete)) == nil, "app_never_displays_fabricated_product_link")
        malformed = products; malformed[0]["unknown_fields"] = []; incomplete["data"] = malformed
        try check(TaobaoProductResult.decodeSearch(try wire(incomplete)) == nil, "app_requires_honest_unknown_fields")
        for mode in ["missing_price", "ambiguous_price"] {
            let reply = try await search(SearchFixture(catalog, mode))
            try check(TaobaoProductResult.decodeSearch(try wire(reply))?.allSatisfy { $0.visiblePrice == nil } == true, "app_preserves_unknown_" + mode)
        }
        let status = try OwnerReadJSON.object(await r.respond(tool: TaobaoTools.status, arguments: wire([:])), limit: 524_288)
        let statusState = TaobaoConnectionState.decode(try wire(status))
        try check(statusState?.state == "protocol_ready" && statusState?.capabilities.filter { $0.supported }.map(\.action) == ["search_products", "get_product"], "protocol_readiness_only_supports_qualified_workflows")
        var falseSupport = status
        var capabilityRows = status["capability_details"] as! [[String: Any]]
        capabilityRows[2]["supported"] = true; falseSupport["capability_details"] = capabilityRows
        try check(TaobaoConnectionState.decode(try wire(falseSupport)) == nil, "app_rejects_invented_SKU_support")
        capabilityRows = status["capability_details"] as! [[String: Any]]
        capabilityRows[1]["reason_code"] = "PRIVATE_RAW_ERROR"; falseSupport["capability_details"] = capabilityRows
        try check(TaobaoConnectionState.decode(try wire(falseSupport)) == nil, "app_rejects_unbounded_diagnostic_text")
        let driftFixture=SearchFixture(drift),unqualified=try await search(driftFixture)
        try check(unqualified["state"] as? String=="unsupported" && driftFixture.calls.isEmpty,"changed_catalog_no_business_calls")
        let legacy=try MioReadCatalog.descriptors()
        let mio=try MioReadOwnerAdapter.respond(["jsonrpc":"2.0","id":1,"method":"tools/list"],ownerCall:{ _,_ in try wire(["tools":rows]) })
        let combined=(mio["result"] as! [String:Any])["tools"] as! [[String:Any]]
        try check(combined.count==23 && (try wire(["tools":Array(combined.prefix(20))]))==(try wire(["tools":legacy])),"existing_twenty_mio_descriptors_preserved")
        print(String(decoding:try wire(["status":"PASS","checks":passed.count,"passed":passed,"official_network_calls":0,"real_credentials_read":0,"real_cart_writes":0]),as:UTF8.self))
    }
}
