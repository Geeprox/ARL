// Directed r2 regression: real production boundaries, synthetic inputs only.
import Foundation

final class TaobaoNeverHTTP: TaobaoHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var calls: Int { lock.withLock { count } }
    func post(_ body: Data, session: String?, version: String?) async throws -> TaobaoHTTPReply {
        lock.withLock { count += 1 }
        throw TaobaoFault.unreachable
    }
}

@main enum TaobaoReviewBoundaryTests {
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        var passed: [String] = []
        func check(_ value: Bool, _ name: String) throws {
            guard value else { throw NSError(domain: "TaobaoR2", code: 1, userInfo: [NSLocalizedDescriptionKey: name]) }
            passed.append(name)
        }
        func bytes(_ value: [String: Any]) throws -> Data { try OwnerReadWire.encode(value, limit: OwnerReadWire.responseLimit) }
        func structured(_ reply: [String: Any]) -> [String: Any] {
            (reply["result"] as! [String: Any])["structuredContent"] as! [String: Any]
        }
        let intentID = "abcdefab-cdef-4abc-8def-abcdefabcdef"
        let args: [String: Any] = ["itemId": "12345", "sku": ["synthetic-white", "1L"], "quantity": 1,
                                   "request_id": intentID, "confirmed": true]
        func request(_ arguments: [String: Any], name: String = "taobao_add_to_cart") -> [String: Any] {
            ["jsonrpc": "2.0", "id": 7, "method": "tools/call", "params": ["name": name, "arguments": arguments]]
        }
        // Model a completed upstream write followed by loss of the owner's reply.
        for fault in [OwnerReadFault.unavailable, .deadline, .cancelled, .limit, .cleanupUnproven] {
            var committed = false, calls = 0
            let reply = try MioReadOwnerAdapter.respond(request(args), ownerCall: { name, data in
                calls += 1; committed = true
                guard name == "taobao_add_to_cart",
                      try OwnerReadJSON.object(data, limit: 16384)["request_id"] as? String == intentID else { fatalError("changed intent") }
                throw fault
            })
            let value = structured(reply)
            try check(committed && calls == 1 && value["state"] as? String == "outcome_unknown"
                && value["request_id"] as? String == intentID && value["automatic_replay"] as? Bool == false,
                "lost_owner_reply_" + fault.rawValue)
            try check((reply["result"] as! [String: Any])["isError"] as? Bool == true
                && (value["next_step"] as? String)?.contains("禁止自动重放") == true, "unknown_guidance_" + fault.rawValue)
        }
        for fault in [OwnerReadFault.invalid, .identity] {
            let reply = try MioReadOwnerAdapter.respond(request(args), ownerCall: { _, _ in
                try OwnerReadClient.receiveAfterPossibleSend(tool: "taobao_add_to_cart") { throw fault }
            })
            try check(structured(reply)["state"] as? String == "outcome_unknown", "post_send_" + fault.rawValue + "_unknown")
        }
        let malformed = try MioReadOwnerAdapter.respond(request(args), ownerCall: { _, _ in Data("{broken".utf8) })
        try check(structured(malformed)["state"] as? String == "outcome_unknown", "malformed_owner_payload_unknown")
        for fault in [OwnerReadFault.invalid, .identity, .held, .unconfigured, .busy] {
            let reply = try MioReadOwnerAdapter.respond(request(args), ownerCall: { _, _ in throw fault })
            try check(structured(reply)["state"] as? String == fault.rawValue, "definite_rejection_" + fault.rawValue)
        }
        let wireRequest = OwnerReadRequest(generation: UUID().uuidString, callID: UUID().uuidString,
            tool: "taobao_add_to_cart", argumentsJSON: try bytes(args))
        let rejected = try OwnerReadWire.response(wireRequest, payload: nil, error: .invalid)
        let explicit = try MioReadOwnerAdapter.respond(request(args), ownerCall: { _, _ in
            try OwnerReadClient.receiveAfterPossibleSend(tool: "taobao_add_to_cart") {
                try OwnerReadWire.payload(rejected, request: wireRequest, distinguishRejection: true)
            }
        })
        try check(structured(explicit)["state"] as? String == "invalid_arguments", "authenticated_wire_rejection_retained")
        var invalidArgs = args; invalidArgs["request_id"] = "not-an-id"
        var invalidCalls = 0
        let invalid = try MioReadOwnerAdapter.respond(request(invalidArgs), ownerCall: { _, _ in invalidCalls += 1; throw OwnerReadFault.unavailable })
        try check(invalidCalls == 0 && structured(invalid)["state"] as? String == "invalid_arguments", "invalid_intent_never_dispatched")
        let readError = try MioReadOwnerAdapter.respond(request(["keyword": "fixture"], name: "taobao_search_products"), ownerCall: { _, _ in throw OwnerReadFault.unavailable })
        try check(structured(readError)["state"] as? String == "owner_unavailable", "read_error_not_cart_unknown")

        let cartSchema = TaobaoTools.schema(["itemId": ["type": "string"],
            "sku": ["type": "array", "items": ["type": "string"]]])
        let small = TaobaoBinding.discover([["name": "add_to_cart", "inputSchema": cartSchema]])[0].action.descriptor
        try check(TaobaoTools.validPublished(small), "small_descriptor_still_valid")
        var hugeSchema = cartSchema, props = cartSchema["properties"] as! [String: Any]
        props["itemId"] = ["type": "string", "description": String(repeating: "x", count: 70000)]
        hugeSchema["properties"] = props
        let huge = TaobaoBinding.discover([["name": "add_to_cart", "inputSchema": hugeSchema]])[0].action.descriptor
        var tampered = huge; tampered["annotations"] = ["readOnlyHint": true]
        try check(try bytes(huge).count > 65536 && bytes(tampered).count > 65536, "both_descriptor_encodings_exceed_bound")
        try check(!TaobaoTools.validPublished(huge) && !TaobaoTools.validPublished(tampered), "oversize_descriptors_rejected")
        let listRequest: [String: Any] = ["jsonrpc": "2.0", "id": 8, "method": "tools/list"]
        let rejectedCatalog = try MioReadOwnerAdapter.respond(listRequest, ownerCall: { _, _ in
            try bytes(["tools": [TaobaoTools.statusAction.descriptor, tampered]])
        })
        let rows = (rejectedCatalog["result"] as! [String: Any])["tools"] as! [[String: Any]]
        try check(rows.count == 21 && rows.last?["name"] as? String == TaobaoTools.status, "actual_catalog_receiver_rejects_oversize_suffix")
        try check(try bytes(["tools": Array(rows.prefix(20))]) == bytes(["tools": MioReadCatalog.descriptors()]), "legacy_twenty_descriptors_exact")

        let privateFields: [String: Any] = ["email": "synthetic@example.invalid", "e_mail": "alias@example.invalid",
            "user_name": "SyntheticPrivateUser", "author": "SyntheticPrivateAuthor", "nickName": "SyntheticPrivateNick",
            "account": ["name": "SyntheticPrivateAccount"], "arbitrary": "SyntheticPrivateUnknown"]
        var review = privateFields; review["text"] = "Works well. Contact synthetic@example.invalid"; review["rating"] = 5
        review["attributes"] = ["material": "steel", "user_name": "SyntheticPrivateNested"]
        let reviews = try TaobaoProjection.project(["reviews": [review]], action: "get_product_reviews") as! [String: Any]
        let reviewText = String(decoding: try bytes(reviews), as: UTF8.self)
        try check(!reviewText.contains("@") && !reviewText.contains("SyntheticPrivate"), "nested_review_contact_account_aliases_omitted")
        try check(reviewText.contains("Works well") && reviewText.contains("steel") && reviewText.contains("rating"), "commercial_review_fields_retained")
        var attributes = privateFields; attributes["capacity"] = "1L"; attributes["material"] = "steel"
        attributes["items"] = [["name": "user_name", "value": "SyntheticPrivateLabelled"], ["name": "容量", "value": "1L"]]
        let product = try TaobaoProjection.product(["itemId": "12345", "title": "Synthetic kettle",
            "attributes": attributes, "skuList": [["color": "white", "capacity": "1L", "author": "SyntheticPrivateSKU"]],
            "promotions": ["label": "Save 10", "amount": 10, "email": "promo@example.invalid"], "reviews": [review]])
        let productText = String(decoding: try bytes(product), as: UTF8.self)
        try check(!productText.contains("SyntheticPrivate") && !productText.contains("@"), "product_nested_private_values_removed")
        try check(product["price"] is NSNull && product["original_price"] is NSNull
            && productText.contains("1L") && productText.contains("white") && productText.contains("Save 10"), "nullable_prices_specs_promotions_retained")
        let shop = try TaobaoProjection.project(["shop": ["shop_name": "Synthetic shop", "rating": 4.8,
            "email": "shop@example.invalid", "author": "SyntheticPrivateShop"]], action: "get_shop") as! [String: Any]
        let shopText = String(decoding: try bytes(shop), as: UTF8.self)
        try check(shopText.contains("Synthetic shop") && !shopText.contains("@") && !shopText.contains("SyntheticPrivate"), "shop_commercial_projection")

        for identity in [TaobaoBuildIdentity(identifier: "com.taobao.pcdesktop", version: "2.4.5", build: "15"),
                         .init(identifier: "com.taobao.desktop", version: "2.5.1", build: "2.5.1"),
                         .init(identifier: "com.taobao.desktop", version: "3.0.0", build: "3.0.0"),
                         .init(identifier: "unknown", version: "99.0.0", build: "1")] {
            let http = TaobaoNeverHTTP(), journal = root.appendingPathComponent(UUID().uuidString)
            let runtime = TaobaoRuntime(transport: http, app: { .versionUnqualified(identity) }, admission: .init(directory: journal))
            try check(!identity.qualifies(transport: "streamable_http") && !identity.qualifies(transport: "cli"), "no_semver_authority_" + identity.version)
            for tool in [TaobaoTools.status, TaobaoTools.catalog, "taobao_add_to_cart"] {
                let result = try await runtime.respond(tool: tool, arguments: tool == "taobao_add_to_cart" ? bytes(args) : Data("{}".utf8))
                let value = try OwnerReadJSON.object(result, limit: 262144)
                try check(value["state"] as? String == "version_unqualified" && value["ready"] as? Bool == false
                    && http.calls == 0 && !FileManager.default.fileExists(atPath: journal.path), "unqualified_no_io_" + identity.version + "_" + tool)
                if tool == TaobaoTools.catalog {
                    try check((value["tools"] as? [[String: Any]])?.count == 1, "unqualified_status_only_" + identity.version)
                } else {
                    try check(TaobaoConnectionState.decode(result)?.title == "此版本与官方接入方式尚未核验", "unqualified_ui_" + identity.version + "_" + tool)
                }
            }
        }
        print(String(decoding: try bytes(["status": "PASS", "checks": passed.count, "passed": passed,
            "official_network_calls": 0, "real_cart_writes": 0, "real_credentials_read": 0]), as: UTF8.self))
    }
}
