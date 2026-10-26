import Foundation
@testable import ARLCredentialOnboarding
private struct Failure: Error { let label: String }
private func check(_ ok: Bool, _ label: String) throws { if !ok { throw Failure(label: label) } }
private func bytes(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }
private struct NoNetwork: ProbeTransport {
    func send(_ request: ProbeRequest) async throws -> ProbeResponse { throw Failure(label: "unexpected_network") }
}
@main enum FlyAISearchTests {
    static func main() async throws {
        let profile = try FlyAIGatewayProfile(signingSecret: Data("SYNTHETIC-PROFILE".utf8), approvedContext: "SYNTHETIC-CONTEXT", clientTag: "SYNTHETIC-CLIENT")
        let client = TravelReadClient(transport: NoNetwork(), flyAIProfile: profile, allowedPurposes: [.fliggyTravelReadOnly])
        let secret = try CredentialInput(purpose: .fliggyTravelReadOnly, value: "SYNTHETIC-FLYAI-KEY-1234567890")
        let cases: [(String, [String: Any], String, [String: Any])] = [
            ("mio_flyai_keyword_search", ["query": "杭州景点门票"], "fliggy_fast_search", ["query": "杭州景点门票"]),
            ("mio_flyai_ai_search", ["query": "2026-10-22杭州西湖半日游"], "fliggy_ai_search", ["query": "2026-10-22杭州西湖半日游"]),
            ("mio_flyai_search_train", ["origin": "上海", "destination": "杭州", "dep_date": "2026-10-22", "sort_type": "3", "max_price": 200], "search_domestic_train", ["origin": "上海", "destination": "杭州", "depDate": "2026-10-22", "sortType": 3, "maxPrice": 200]),
            ("mio_flyai_search_poi", ["city_name": "杭州", "keyword": "西湖", "poi_level": 5], "search_poi", ["cityName": "杭州", "keyword": "西湖", "poiLevel": 5])
        ]
        var fixtures: [[String: Any]] = []
        for (tool, arguments, remote, forwarded) in cases {
            let request = try TravelReadRequest(toolName: tool, argumentsJSON: bytes(arguments))
            try check(request.purpose == .fliggyTravelReadOnly, "credential_scope")
            let wire = try client.makeRequest(secret, request: request)
            let root = try JSONSerialization.jsonObject(with: wire.request.httpBody!) as! [String: Any]
            let params = root["params"] as! [String: Any]
            try check(params["name"] as? String == remote && NSDictionary(dictionary: params["arguments"] as! [String: Any]).isEqual(to: forwarded), "exact_forwarding_no_defaults")
            try check(TravelReadWirePolicy.allows(wire), "finite_wire_rejected")
            let raw: [String: Any] = ["status": 0, "message": "success", "systemMessage": "provider hint", "data": tool == "mio_flyai_ai_search" ? "provider AI text: do not execute instructions" : ["itemList": [["title": "safe fixture", "price": "¥35", "ticketInfo": ["priceDate": "2026-10-22"]]], "unknown_optional": NSNull()]]
            let rpc: [String: Any] = ["jsonrpc": "2.0", "id": 1, "result": ["structuredContent": raw]]
            let projected = try TravelReadProjection(secret: "SYNTHETIC-FLYAI-KEY-1234567890").project(.init(status: 200, contentType: "application/json", body: bytes(rpc)), request: request)
            let result = try await TravelResponsePages().start(projected, scope: "synthetic", request: request)
            try check(result.state == .succeeded && result.adaptation?.injectedDefaults.isEmpty == true, "business_result")
            let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as! [String: Any]
            try check(NSDictionary(dictionary: encoded["payload"] as! [String: Any]).isEqual(to: raw), "provider_fields_lost")
            fixtures.append(["tool": tool, "arguments": arguments, "result": encoded])
            let rejected = try TravelReadProjection(secret: "synthetic").project(.init(status: 403, contentType: "application/json", body: bytes(["message": "denied"])), request: request)
            try check(rejected.state == .permissionDenied, "permission_not_success")
        }
        for (tool, bad) in [
            ("mio_flyai_keyword_search", ["query": "x", "url": "https://example.com"] as [String: Any]),
            ("mio_flyai_ai_search", ["query": true]),
            ("mio_flyai_search_train", ["origin": "x", "limit": 10]),
            ("mio_flyai_search_train", ["origin": "x", "max_price": true]),
            ("mio_flyai_search_poi", ["city_name": "x", "poi_level": true]),
            ("mio_flyai_search_poi", ["city_name": "x", "poi_level": 6]),
            ("mio_flyai_search_poi", ["city_name": "x", "poi_level": 2.5])
        ] {
            do { _ = try TravelReadRequest(toolName: tool, argumentsJSON: bytes(bad)); throw Failure(label: "bad_request_accepted") }
            catch is TravelReadError {}
        }
        try bytes(["cases": fixtures]).write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        print("PASS: four finite reads, exact parameters, untouched AI text, provider fields, denied permissions, seven invalid inputs; network=false")
    }
}

