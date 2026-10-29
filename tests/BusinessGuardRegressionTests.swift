import Foundation

// One same-module SDK fixture, awaiting the coordinator's native slot.
// URLProtocol intercepts every request; all credentials and response rows are synthetic.
private enum GuardCheck: Error { case failed(String) }
private struct GuardGate: DeploymentGate { func verify() throws {} }
private func check(_ value: Bool, _ label: String) throws {
    guard value else { throw GuardCheck.failed(label) }
}
private func json(_ object: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}
private func rejects(_ body: () throws -> Void) -> Bool {
    do { try body(); return false } catch { return true }
}
private final class ResponseState: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    private var mediaType = "application/json"
    private var length: Int?
    private var finish = true
    func configure(_ bytes: Data, mediaType: String = "application/json", length: Int? = nil, finish: Bool = true) {
        lock.withLock { self.bytes = bytes; self.mediaType = mediaType; self.length = length; self.finish = finish }
    }
    func read() -> (Data, String, Int?, Bool) { lock.withLock { (bytes, mediaType, length, finish) } }
}
private final class SyntheticHTTP: URLProtocol, @unchecked Sendable {
    static let state = ResponseState()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (data, type, length, finish) = Self.state.read()
        var headers = ["Content-Type": type]
        if let length { headers["Content-Length"] = String(length) }
        guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: 200,
            httpVersion: "HTTP/1.1", headerFields: headers) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for start in stride(from: 0, to: data.count, by: 16384) {
            client?.urlProtocol(self, didLoad: data.subdata(in: start..<min(start + 16384, data.count)))
        }
        if finish { client?.urlProtocolDidFinishLoading(self) }
    }
    override func stopLoading() {}
}

@main enum BusinessGuardRegressionTests {
    static func main() async throws {
        try await travelBudgets()
        try await flyAIBudgets()
        try structuredArguments()
        try musicContinuation()
        try literalNASPaths()
        print("{\"status\":\"PASS\",\"groups\":[\"travel_resource_layers\",\"flyai_sse_budget\",\"structured_arguments\",\"music_continuation_contract\",\"literal_nas_paths\"],\"real_network\":false,\"real_credentials\":false,\"keychain\":false,\"native_permissions\":false}")
    }
    private static func transport() -> BoundedHTTPS {
        BoundedHTTPS(gate: GuardGate(), configuration: {
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [SyntheticHTTP.self]
            return config
        })
    }
    private static func route(_ steps: Int, instruction: Int, polyline: Int) throws -> Data {
        let step: [String: Any] = ["instruction": String(repeating: "R", count: instruction), "distance": "120",
                                   "duration": "50", "polyline": String(repeating: "P", count: polyline)]
        let path: [String: Any] = ["distance": "18000", "duration": "3200", "steps": Array(repeating: step, count: steps)]
        return try json(["status": "1", "infocode": "10000", "route": ["origin": "120.1,30.2", "destination": "120.3,30.4",
                            "paths": [path, path]]])
    }
    private static func travelBudgets() async throws {
        let request = try TravelReadRequest(toolName: "mio_maps_direction_driving", argumentsJSON: json([
            "origin": "120.1,30.2", "destination": "120.3,30.4"]))
        let secret = try CredentialInput(purpose: .amapMapsWeather, value: "SYNTHETIC-GUARD-KEY-1234567890")
        let client = TravelReadClient(transport: transport(), flyAIProfile: nil, allowedPurposes: [.amapMapsWeather])
        let body = try route(80, instruction: 920, polyline: 2100)
        try check(body.count > 65536 && body.count < TravelReadLimits.providerBytes, "normal_route_raw_shape")
        SyntheticHTTP.state.configure(body, length: body.count)
        let result = await client.sendRead(secret, request: request)
        let projected = try JSONEncoder().encode(result)
        try check(result.state == .succeeded && projected.count > 65536 && projected.count <= TravelReadLimits.payloadBytes,
                  "normal_route_transport_projection_and_public_dto")
        // Credential probes still use 64KiB, including the same transport's chunk gate.
        let probe = try client.makeRequest(secret, request: request)
        try check(probe.responseByteLimit == 65536, "credential_default_unchanged")
        SyntheticHTTP.state.configure(body)
        do { _ = try await transport().send(probe); throw GuardCheck.failed("probe_64k_gate") }
        catch TransportFailure.responseLimit {}
        let tooRaw = Data(repeating: 32, count: TravelReadLimits.providerBytes + 1)
        for declared in [true, false] {
            SyntheticHTTP.state.configure(tooRaw, length: declared ? tooRaw.count : nil)
            let oversized = await client.sendRead(secret, request: request)
            try check(oversized.state == .responseTooLarge, "raw_gate_\(declared ? "header" : "chunks")")
        }
        let tooDTO = try route(150, instruction: 1200, polyline: 0)
        try check(tooDTO.count < TravelReadLimits.providerBytes, "dto_counterexample_fits_raw")
        SyntheticHTTP.state.configure(tooDTO)
        let oversizedDTO = await client.sendRead(secret, request: request)
        try check(oversizedDTO.state == .succeeded && oversizedDTO.adaptation?.partial == true && oversizedDTO.adaptation?.nextCursor != nil, "owner_capacity_retained_via_whole_item_pages")
    }
    private static func flyAIBudgets() async throws {
        let profile = try FlyAIGatewayProfile(signingSecret: Data("SYNTHETIC-SIGNING".utf8),
                                              approvedContext: "SYNTHETIC-CONTEXT", clientTag: "SYNTHETIC-CLIENT")
        let inner = try json(["status": 0, "data": ["itemList": []], "description": String(repeating: "D", count: 70000)])
        let object: [String: Any] = ["jsonrpc": "2.0", "id": 1, "result": ["isError": false,
            "content": [["type": "text", "text": String(decoding: inner, as: UTF8.self)]]]]
        let body = try json(object)
        let sse = Data("data: ".utf8) + body + Data("\n\n".utf8)
        let matched = try FlyAIMCPResponse.matchingFrame(sse, requestID: 1, complete: false, byteLimit: TravelReadLimits.providerBytes)
        try check(matched == body, "matching_sse_keeps_validated_wire_bytes")
        try check(rejects { _ = try FlyAIMCPResponse.matchingFrame(sse, requestID: 1, complete: true) }, "probe_sse_default_still_64k")
        try check(rejects { _ = try FlyAIMCPResponse.matchingFrame(sse + sse, requestID: 1, complete: true,
            byteLimit: TravelReadLimits.providerBytes) }, "duplicate_result_still_rejected")
        var wrongID = object; wrongID["id"] = 2
        try check(rejects { _ = try FlyAIMCPResponse.envelope(.init(status: 200, contentType: "application/json", body: json(wrongID)),
            requestID: 1, byteLimit: TravelReadLimits.providerBytes) }, "wrong_id_still_rejected")
        SyntheticHTTP.state.configure(sse, mediaType: "text/event-stream", finish: false)
        let request = try TravelReadRequest(toolName: "mio_flyai_search_hotel", argumentsJSON: json([
            "dest_name": "杭州", "check_in_date": "2026-10-20", "check_out_date": "2026-10-21"]))
        let secret = try CredentialInput(purpose: .fliggyTravelReadOnly, value: "SYNTHETIC-FLYAI-KEY-1234567890")
        let result = await TravelReadClient(transport: transport(), flyAIProfile: profile,
            allowedPurposes: [.fliggyTravelReadOnly]).sendRead(secret, request: request)
        try check(result.state == .succeeded, "held_sse_nested_business_above_64k")
    }
    private static func structuredArguments() throws {
        let secret = try CredentialInput(purpose: .amapMapsWeather, value: "SYNTHETIC-GUARD-KEY-1234567890")
        let client = TravelReadClient(transport: transport(), flyAIProfile: nil, allowedPurposes: [.amapMapsWeather])
        let request = try TravelReadRequest(toolName: "mio_maps_text_search", argumentsJSON: json([
            "keywords": "-1楼餐厅", "city": "杭州", "types": "050000|060000"]))
        let wire = try client.makeRequest(secret, request: request)
        let components = URLComponents(url: wire.request.url!, resolvingAgainstBaseURL: false)!
        let items = components.queryItems!
        try check(TravelReadWirePolicy.allows(wire) && items.first(where: { $0.name == "types" })?.value == "050000|060000"
            && items.first(where: { $0.name == "keywords" })?.value == "-1楼餐厅", "types_and_leading_minus_reach_provider_query")
        try check(!TravelReadResult(request: request, state: .succeeded).notices.contains(.poiTypesNotAppliedBySourceContract),
                  "no_obsolete_ignored_types_notice")
        for extra in [URLQueryItem(name: "url", value: "https://synthetic.invalid"), URLQueryItem(name: "key", value: "extra")] {
            var changed = components; changed.queryItems = items + [extra]
            var urlRequest = wire.request; urlRequest.url = changed.url
            try check(!TravelReadWirePolicy.allows(.init(purpose: .amapMapsWeather, request: urlRequest)), "unknown_or_duplicate_query_rejected")
        }
        let coordinate = try TravelReadRequest(toolName: "mio_maps_regeocode", argumentsJSON: json(["location": "-73.9857,40.7484"]))
        try check(TravelReadWirePolicy.allows(try client.makeRequest(secret, request: coordinate)), "negative_longitude_is_value")
        try check(rejects { _ = try TravelReadRequest(toolName: "mio_maps_text_search", argumentsJSON: json(["keywords": "a\nb"])) },
                  "control_character_still_rejected")
    }
    private static func musicContinuation() throws {
        guard CommandLine.arguments.count == 2 else { throw GuardCheck.failed("public_fixture_path") }
        let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [String: Any]
        let first = fixture["first"] as! [String: Any], second = fixture["second"] as! [String: Any]
        let id = "11111111111111111111111111111111"
        let a = try MusicReadProtocol.decode(first, for: .playlistDetail(playlistID: id))
        let b = try MusicReadProtocol.decode(second, for: .playlistDetailPage(playlistID: id, offset: 50))
        try check(a.payload?.songs?.count == 100 && a.payload?.pagination?.nextOffset == nil && a.payload?.complete == true,
                  "rich_snapshot_crosses_legacy_frame_budget_without_losing_completeness")
        try check(b.payload?.songs?.count == 50 && b.payload?.pagination?.nextOffset == nil && b.payload?.pagination?.state == .continuationEnd
            && b.payload?.complete == false, "last_continuation_never_claims_full_snapshot")
        try check(rejects { _ = try MusicReadProtocol.decode(second, for: .playlistDetailPage(playlistID: id, offset: 49)) },
                  "wrong_request_offset_rejected")
        var claimed = second, payload = second["payload"] as! [String: Any]
        payload["complete"] = true; claimed["payload"] = payload
        try check(rejects { _ = try MusicReadProtocol.decode(claimed, for: .playlistDetailPage(playlistID: id, offset: 50)) },
                  "continuation_cannot_be_write_preflight_complete")
        var skipped = first, firstPayload = first["payload"] as! [String: Any], pagination = firstPayload["pagination"] as! [String: Any]
        pagination["next_offset"] = 70; firstPayload["pagination"] = pagination; skipped["payload"] = firstPayload
        try check(rejects { _ = try MusicReadProtocol.decode(skipped, for: .playlistDetail(playlistID: id)) }, "skipped_item_rejected")
        guard let largeFirst = fixture["large_first"] as? [String: Any], let largeSecond = fixture["large_second"] as? [String: Any]
        else { throw GuardCheck.failed("large_frame_public_fixture") }
        let c = try MusicReadProtocol.decode(largeFirst, for: .playlistDetail(playlistID: id))
        let next = 50
        let d = try MusicReadProtocol.decode(largeSecond, for: .playlistDetailPage(playlistID: id, offset: next))
        try check(c.payload?.songs?.count == 100 && d.payload?.songs?.count == 50 &&
                  c.payload?.complete == true && d.payload?.complete == false && d.payload?.pagination?.nextOffset == nil,
                  "credential_inclusive_private_parts_preserve_complete_snapshot")
    }
    private static func literalNASPaths() throws {
        let page = try NASDirectoryPage(path: "", directories: ["100%完成", "%2e%2e"], nextCursor: nil)
        try check(page.directories.count == 2, "literal_percent_directory_dto")
        _ = try NASConnectionConfiguration(sourceRef: "fixture", host: "synthetic.invalid", share: "100%share", root: "100%完成")
        for path in ["../private", "a/../private", "a\\b", "a:b", "/private", "a//b", "a/./b", String(repeating: "a", count: 256)] {
            try check(rejects { try NASDirectoryPage.validatePath(path) }, "unsafe_nas_path_rejected")
        }
    }
}
