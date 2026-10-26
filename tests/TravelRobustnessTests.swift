import Foundation

// Four decisive groups only, same module as production SDK. Prepared for a
// later writer-assigned native slot; this source/light task never executes it.
private enum RobustnessFailure: Error { case check(String) }
private struct RobustnessGate: DeploymentGate { func verify() throws {} }
private func check(_ value: Bool, _ name: String) throws {
    guard value else { throw RobustnessFailure.check(name) }
}
private func json(_ object: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}
private func response(_ object: [String: Any]) throws -> ProbeResponse {
    .init(status: 200, contentType: "application/json", body: try json(object))
}
private func rpc(_ inner: [String: Any], id: Int = 1, isError: Bool = false, display: Bool = false) throws -> [String: Any] {
    var content: [[String: Any]] = []
    if display { content.append(["type": "text", "text": "Read-only fixture explanation."]) }
    content.append(["type": "text", "text": String(decoding: try json(inner), as: UTF8.self)])
    return ["jsonrpc": "2.0", "id": id, "result": ["isError": isError, "content": content]]
}
private func bytes(_ payload: TravelReadPayload) throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(payload)
}
private func rejected(_ body: () throws -> Void) -> Bool {
    do { try body(); return false } catch { return true }
}
private func hotelRequest() throws -> TravelReadRequest {
    try .init(toolName: "mio_flyai_search_hotel", argumentsJSON: json([
        "dest_name": "杭州", "check_in_date": "2026-10-20", "check_out_date": "2026-10-21"]))
}
private func profile() throws -> FlyAIGatewayProfile {
    try .init(signingSecret: Data("SYNTHETIC-SIGNING-MATERIAL".utf8),
              approvedContext: "SYNTHETIC-CONTEXT", clientTag: "SYNTHETIC-CLIENT")
}
private actor Responses: ProbeTransport {
    private var values: [ProbeResponse]
    private var sent = 0
    init(_ values: [ProbeResponse]) { self.values = values }
    func send(_ probe: ProbeRequest) async throws -> ProbeResponse {
        guard TravelReadWirePolicy.allows(probe), !values.isEmpty else { throw RobustnessFailure.check("known_read_request_required") }
        sent += 1; return values.removeFirst()
    }
    func count() -> Int { sent }
}
private final class StreamState: @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [Data] = []
    private var stopped = false
    func configure(_ chunks: [Data]) { lock.withLock { self.chunks = chunks; stopped = false } }
    func body() -> [Data] { lock.withLock { chunks } }
    func stop() { lock.withLock { stopped = true } }
    func wasStopped() -> Bool { lock.withLock { stopped } }
}
private final class HeldSSE: URLProtocol, @unchecked Sendable {
    static let state = StreamState()
    override class func canInit(with request: URLRequest) -> Bool { true } // Every request is intercepted; no socket/provider.
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: 200,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"]) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in Self.state.body() { client?.urlProtocol(self, didLoad: chunk) }
        // Deliberately omit didFinishLoading: the production transaction must
        // terminate and cancel as soon as its unique matching result arrives.
    }
    override func stopLoading() { Self.state.stop() }
}

@main enum TravelRobustnessTests {
    static func main() async throws {
        try r08(); try r09(); try await r10(); try await r11()
        print(String(decoding: try json(["status": "PASS", "cases": ["R08", "R09", "R10", "R11"],
            "real_provider_calls": 0, "real_credentials_read": 0, "keychain_calls": 0]), as: UTF8.self))
    }
    private static func r08() throws {
        let request = try TravelReadRequest(toolName: "mio_maps_weather", argumentsJSON: json(["adcode": "110101"]))
        let projection = TravelReadProjection(secret: "SYNTHETIC-KEY-NOT-A-REAL-KEY")
        var row: [String: Any] = ["adcode": "110101", "city": "东城", "province": "北京", "reporttime": "2026-10-10 08:00:00",
            "weather": "晴", "winddirection": "南", "windpower": "2", "temperature": "21.12345", "humidity": "60.12345"]
        let baseline = try response(["status": "1", "infocode": "10000", "lives": [row]])
        row["temperature"] = 21.12345; row["humidity"] = 60.12345
        let numeric = try response(["status": 1, "infocode": 10000, "lives": [row]])
        try check(try bytes(projection.parse(baseline, request: request)) != bytes(projection.parse(numeric, request: request)), "R08_original_numeric_types_preserved")
        try check(VendorValidator.parse(numeric, purpose: .amapMapsWeather).state == .verified &&
            VendorValidator.parse(try response(["status": 0, "infocode": 10001]), purpose: .amapMapsWeather).state == .invalidOrExpired,
            "R08_known_status_success_and_error")
        row["temperature"] = true
        try check(!rejected { _ = try projection.parse(response(["status": 1, "infocode": 10000, "lives": [row]]), request: request) } &&
            TravelProviderValue.integer("10000.00000000000000001", range: 0...99999) == nil,
            "R08_boolean_and_unknown_fractional_code_rejected")
    }
    private static func r09() throws {
        let request = try hotelRequest(), projection = TravelReadProjection(secret: "SYNTHETIC-PRIVATE-KEY")
        var row: [String: Any] = ["shId": "fixture-hotel-id", "name": "Fixture Hotel", "address": NSNull(),
            "brandName": ["display": "new shape"], "scoreDesc": ["unused": "SYNTHETIC-PRIVATE-KEY"], "price": 123.456]
        let projected = try projection.project(response(rpc(["status": 0, "data": ["itemList": [row]]])), request: request)
        let object = try JSONSerialization.jsonObject(with: bytes(projected.payload)) as! [String: Any]
        let first = ((object["data"] as! [String: Any])["itemList"] as! [[String: Any]])[0]
        try check(first["shId"] as? String == "fixture-hotel-id" && first["address"] is NSNull && first["brandName"] is [String: Any], "R09_original_optional_shapes_preserved")
        try check(projected.omittedAuthenticationFields.contains("known_credential_material"), "R09_known_secret_omission_reported")
        row["shId"] = NSNull()
        try check(!rejected { _ = try projection.parse(response(rpc(["status": 0, "data": ["itemList": [row]]])), request: request) }, "R09_optional_identity_evolution_preserved")
        row["name"] = "SYNTHETIC-PRIVATE-KEY"
        let filtered = try projection.project(response(rpc(["status":0,"data":["itemList":[row]]])),request:request)
        try check(!String(decoding:try bytes(filtered.payload),as:UTF8.self).contains("SYNTHETIC-PRIVATE-KEY"),"R09_known_secret_not_returned")
    }
    private static func r10() async throws {
        let inner: [String: Any] = ["status": "0", "data": ["itemList": []], "description": "display B"]
        var root = try rpc(inner, display: true)
        var repeated = root["result"] as! [String: Any]
        repeated["structuredContent"] = ["status": 0, "data": ["itemList": []], "description": "display A"]
        root["result"] = repeated
        let notice = Data("data: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\",\"params\":{}}\n\n".utf8)
        let result = Data("data: ".utf8) + (try json(root)) + Data("\n\n".utf8)
        HeldSSE.state.configure([notice, result + Data("data: ".utf8) + Data([0xe4])])
        let transport = BoundedHTTPS(gate: RobustnessGate(), configuration: {
            let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [HeldSSE.self]; return config
        })
        var probe = try VendorValidator.flyAIRequest(key: "SYNTHETIC-KEY", profile: profile(), tool: .hotel, arguments: ["limit": 10])
        probe.remainingSeconds = 2
        let start = ContinuousClock.now
        let streamed = try await transport.send(probe)
        let request = try hotelRequest(), projection = TravelReadProjection(secret: "SYNTHETIC-KEY")
        try check(try bytes(projection.parse(streamed, request: request)) == bytes(projection.parse(response(root), request: request)) &&
                  start.duration(to: .now) < .seconds(2), "R10_held_stream_returns_typed_result_before_eof")
        for _ in 0..<20 where !HeldSSE.state.wasStopped() { try await Task.sleep(for: .milliseconds(5)) }
        try check(HeldSSE.state.wasStopped(), "R10_transaction_cancelled")
        try check(rejected { _ = try FlyAIMCPResponse.matchingFrame(result + result, requestID: 1, complete: true) } &&
            rejected { _ = try FlyAIMCPResponse.envelope(response(rpc(inner, id: 2)), requestID: 1) },
            "R10_duplicate_and_wrong_id_rejected")
        for conflicting in [["status": 0, "data": ["itemList": [["shId": "different-id", "name": "Different Hotel"]]]],
                            ["status": 0, "data": ["itemList": []], "success": false]] as [[String: Any]] {
            var conflict = root, result = repeated
            result["structuredContent"] = conflicting; conflict["result"] = result
            let rejectedConflict = VendorValidator.parse(try response(conflict), purpose: .fliggyTravelReadOnly)
            try check(rejectedConflict.state == .protocolFailure && rejectedConflict.diagnostic == .ambiguousMCPResult,
                      "R10_consumed_data_or_error_semantics_conflict_rejected")
        }
    }
    private static func r11() async throws {
        let positive = try response(rpc(["status": 0, "data": ["itemList": []]]))
        let negative = try response(rpc(["status": 401], isError: true))
        let transport = Responses([negative, positive])
        let validator = VendorValidator(transport: transport, flyAIProfile: try profile())
        let key = try CredentialInput(purpose: .fliggyTravelReadOnly, value: "SYNTHETIC-KEY-1234abcd5678efgh")
        let result = await validator.validate(key, purpose: .fliggyTravelReadOnly, deadline: .now.advanced(by: .seconds(2)))
        let calls = await transport.count()
        try check(result.state == .verified && result.evidence == .flyaiDifferentialReadOnlyResponse && calls == 2,
                  "R11_http200_business_auth_negative_then_positive")
        for control in [try response(rpc(["status": 91823], isError: true)), positive] {
            let unknown = Responses([control, positive])
            let input = try CredentialInput(purpose: .fliggyTravelReadOnly, value: "SYNTHETIC-KEY-1234abcd5678efgh")
            let unconfirmed = await VendorValidator(transport: unknown, flyAIProfile: try profile()).validate(input, purpose: .fliggyTravelReadOnly,
                                                                                  deadline: .now.advanced(by: .seconds(2)))
            let count = await unknown.count()
            try check(unconfirmed.state == .credentialUnconfirmed && count == 1, "R11_unknown_or_successful_control_never_confirms")
        }
        var incompatible = try rpc(["status": 0, "data": ["itemList": []]])
        incompatible["jsonrpc"] = "3.0"
        let protocolResult = VendorValidator.parse(try response(incompatible), purpose: .fliggyTravelReadOnly)
        try check(protocolResult.state == .protocolFailure && protocolResult.diagnostic == .unsupportedProtocolVersion, "R11_finite_version_reason")
        // Same group verifies old optional-diagnostic DTO decoding; no Keychain.
        let legacyTest = try JSONDecoder().decode(ConnectionTestResult.self, from: json([
            "state": "protocolFailure", "checkedAt": 0, "evidence": "none", "expiryKnowledge": "unknown", "httpStatus": 200]))
        let legacyRead = try JSONDecoder().decode(TravelReadResult.self, from: json([
            "schemaVersion": 1, "toolName": "mio_flyai_search_hotel", "state": "succeeded", "fetchedAtMilliseconds": 0, "notices": []]))
        try check(legacyTest.diagnostic == nil && legacyRead.diagnostic == nil, "R11_legacy_missing_optional_diagnostic_decodes")
    }
}
