import Foundation
import CoreFoundation
private enum TravelFixtureError: Error { case failed(String) }
private func require(_ ok: Bool, _ message: String) throws { if !ok { throw TravelFixtureError.failed(message) } }
private func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]) }
private func response(_ value: Any, status: Int = 200) throws -> ProbeResponse { .init(status: status, contentType: "application/json", body: try json(value)) }
private func object(_ value: MusicProviderValue) throws -> [String: Any] { try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as! [String: Any] }
private func request(_ name: String, _ args: [String: Any]) throws -> TravelReadRequest { try .init(toolName: name, argumentsJSON: json(args)) }
private func rpc(_ value: [String: Any]) throws -> [String: Any] { ["jsonrpc":"2.0", "id":1, "result":["structuredContent": value, "content":[["type":"text", "text":String(decoding: try json(value), as: UTF8.self)]]]] }
private actor TravelFixtureTransport: ProbeTransport {
    let response: ProbeResponse
    private var calls = 0
    init(_ response: ProbeResponse) { self.response = response }
    func send(_ probe: ProbeRequest) async throws -> ProbeResponse { guard TravelReadWirePolicy.allows(probe) else { throw TravelFixtureError.failed("wire_policy") }; calls += 1; return response }
    func count() -> Int { calls }
}
@main enum TravelTransparentTests {
    static func main() async throws {
        let key = "SYNTHETIC-TRAVEL-PRIVATE-KEY-1234567890", projection = TravelReadProjection(secret: "SYNTHETIC-TRAVEL-PRIVATE-KEY-1234567890")
        var mio: [[String: Any]] = []
        let weather = try request("mio_maps_weather", ["adcode":"110101"])
        let rawWeather: [String: Any] = ["status":"1", "infocode":"10000", "future": ["empty":[], "nullable":NSNull()], "lives":[["adcode":"different", "humidity":333, "temperature":true, "reporttime":"provider future time format", "description":String(repeating:"x", count:5000)]]]
        let w = try projection.project(response(rawWeather), request: weather)
        try require(w.state == .succeeded && NSDictionary(dictionary: object(w.payload)).isEqual(to: rawWeather), "raw_weather_optional_fields_or_types_changed")
        let bigInteger = try MusicStrictJSON.object(Data("{\"status\":\"1\",\"infocode\":\"10000\",\"id\":9007199254740993,\"unsigned\":18446744073709551615}".utf8), limit: 1000)
        let number = try projection.project(response(bigInteger), request: weather)
        let numberResult = TravelReadResult(request:weather,state:number.state,payload:number.payload,httpStatus:number.httpStatus)
        mio.append(["tool":"mio_maps_weather", "arguments":["adcode":"110101"], "result":try JSONSerialization.jsonObject(with:JSONEncoder().encode(numberResult))])
        let numbers = try object(number.payload)
        try require((numbers["id"] as! NSNumber).stringValue == "9007199254740993" && (numbers["unsigned"] as! NSNumber).stringValue == "18446744073709551615", "native_integer_precision_lost")
        let bike = try request("mio_maps_bicycling", ["origin":"120,30", "destination":"121,31"])
        let bikeError: [String: Any] = ["errcode":49237, "errmsg":"provider explanation", "extension":["empty":[]]]
        let b = try projection.project(response(bikeError), request: bike)
        try require(b.state == .providerRejected && b.httpStatus == 200 && NSDictionary(dictionary: object(b.payload)).isEqual(to: bikeError), "safe_bike_error_lost")
        let http = try projection.project(response(["code":"RATE_LIMITED", "message":"safe explanation", "retry_after":30], status:429), request: weather)
        try require(http.state == .rateLimited && http.httpStatus == 429 && (try object(http.payload))["code"] as? String == "RATE_LIMITED", "http_error_lost")
        let hotel = try request("mio_flyai_search_hotel", ["dest_name":"Example city"])
        let rawHotel: [String: Any] = ["status":0, "message":"success", "total":37, "pageInfo":["cursor":"provider-business-cursor"], "data":["itemList":(0..<12).map { ["shId":$0, "name":NSNull(), "address":[], "roomTypes":[["future":true]], "price":123.25] as [String: Any] }]]
        let h = try projection.project(response(rpc(rawHotel)), request: hotel)
        var evolved = try rpc(rawHotel), evolvedResult = evolved["result"] as! [String: Any]
        evolvedResult["content"] = Array(repeating: ["type":"text","text":"Provider display notice"], count:17); evolved["result"] = evolvedResult
        let manyBlocks = try projection.project(response(evolved),request:hotel)
        try require(manyBlocks.state == .succeeded && NSDictionary(dictionary:object(manyBlocks.payload)).isEqual(to:rawHotel),"optional_display_blocks_rejected_business")
        let primitive = try projection.project(.init(status:429,contentType:"application/problem+json",body:Data("[1,\"2\",null,false]".utf8)),request:weather)
        try require(primitive.state == .rateLimited && primitive.payload == .array([.integer(1),.text("2"),.null,.boolean(false)]),"error_json_root_type_lost")
        try require(h.state == .succeeded && NSDictionary(dictionary: object(h.payload)).isEqual(to: rawHotel), "fly_business_fields_total_or_types_lost")
        let clean = try projection.project(response(["status":"1", "infocode":"10000", "recording":["session":["studio":"Example"]], "artist":["signature":"Public bio"], "nested":["authToken":"UNFAMILIAR-UPSTREAM-TOKEN", "redirect":"https://example.invalid/#id_token=UNFAMILIAR-UPSTREAM-TOKEN", "echo":key]]), request: weather)
        let cleanText = String(decoding:try JSONEncoder().encode(clean.payload),as:UTF8.self)
        try require(!cleanText.contains("UNFAMILIAR-UPSTREAM") && !cleanText.contains(key) && cleanText.contains("Public bio") && cleanText.contains("studio"), "auth_context_or_business_preservation")
        let secret = try CredentialInput(purpose:.amapMapsWeather, value:key)
        let params = try request("mio_maps_text_search", ["types":"050000", "citylimit":"true", "page":"2", "offset":"25", "extensions":"all"])
        let transport = TravelFixtureTransport(try response(rawWeather))
        let client = TravelReadClient(transport:transport, flyAIProfile:nil, allowedPurposes:[.amapMapsWeather], pages:TravelResponsePages())
        let wire = try client.makeRequest(secret, request:params)
        let query = Dictionary(uniqueKeysWithValues:URLComponents(url:wire.request.url!, resolvingAgainstBaseURL:false)!.queryItems!.map { ($0.name,$0.value!) })
        try require(query["types"] == "050000" && query["page"] == "2" && query["citylimit"] == "true" && query["output"] == "JSON" && query["source"] == nil, "amap_parameters_or_defaults_rewritten")
        let around = try client.makeRequest(secret, request: request("mio_maps_around_search", ["location":"120,30"]))
        try require(!around.request.url!.absoluteString.contains("radius="), "hidden_radius_default")
        let profile = try FlyAIGatewayProfile(signingSecret:Data("SYNTHETIC-PROFILE".utf8), approvedContext:"SYNTHETIC-CONTEXT", clientTag:"SYNTHETIC-CLIENT")
        let fly = TravelReadClient(transport:transport, flyAIProfile:profile, allowedPurposes:[.fliggyTravelReadOnly])
        let flySecret = try CredentialInput(purpose:.fliggyTravelReadOnly, value:key)
        let f = try fly.makeRequest(flySecret, request:request("mio_flyai_search_flight", ["origin":"Example", "dep_date_start":"2026-11-01", "dep_hour_start":7, "total_duration_hour":5, "journey_type":"1"]))
        let args = ((try JSONSerialization.jsonObject(with:f.request.httpBody!) as! [String:Any])["params"] as! [String:Any])["arguments"] as! [String:Any]
        try require(args["depDateStart"] as? String == "2026-11-01" && args["depHourStart"] as? Int == 7 && args["limit"] == nil, "fly_parameters_or_hidden_limit")
        let rows = (0..<60).map { ["id":"id-\($0)", "tel":["000"], "extra":String(repeating:"v",count:8000), "empty":[], "flag":false] as [String:Any] }
        let full: [String: Any] = ["status":"1", "infocode":"10000", "count":"60", "suggestion":["cities":[]], "pois":rows]
        let pagedTransport = TravelFixtureTransport(try response(full))
        let paged = TravelReadClient(transport:pagedTransport, flyAIProfile:nil, allowedPurposes:[.amapMapsWeather], pages:TravelResponsePages())
        var q = try request("mio_maps_text_search", ["keywords":"Example"]), result = await paged.sendRead(secret, request:q), all:[[String:Any]] = [], rounds=0
        let generation = UUID()
        // Direct fixture scope is intentional; production sets its leased generation.
        repeat {
            try require(result.state == .succeeded && (try JSONEncoder().encode(result)).count <= TravelReadLimits.payloadBytes, "page_failed_or_exceeds_wire")
            let body = try object(result.payload!); all += body["pois"] as! [[String:Any]]
            if rounds == 0 {
                mio.append(["tool":"mio_maps_text_search", "arguments":["keywords":"Example"], "result":try JSONSerialization.jsonObject(with:JSONEncoder().encode(result))])
                if let cursor = result.adaptation?.nextCursor {
                    let changed = try request("mio_maps_text_search", ["keywords":"Changed", "cursor":cursor])
                    let denied = await paged.sendRead(secret, request:changed); try require(denied.state == .invalidArguments, "cursor_query_binding")
                    let same = try request("mio_maps_text_search", ["keywords":"Example", "cursor":cursor])
                    let deniedGeneration = await TravelReadAuthorization.$generation.withValue(generation) { await paged.sendRead(secret, request:same) }
                    try require(deniedGeneration.state == .invalidArguments, "cursor_generation_binding")
                }
            }
            rounds += 1; try require(rounds < 10, "page_loop")
            guard let cursor = result.adaptation?.nextCursor else { break }
            q = try request("mio_maps_text_search", ["keywords":"Example", "cursor":cursor]); result = await paged.sendRead(secret, request:q)
        } while true
        try require(NSArray(array:all).isEqual(to:rows) && rounds > 1, "whole_item_continuation_lost_or_reordered")
        try require(await pagedTransport.count() == 1, "cursor_repeated_provider_read")
        let oversized = try projection.project(response(["status":"1", "infocode":"10000", "pois":[["name":String(repeating:"L",count:300000)]]]), request:q)
        let tooBig = try await TravelResponsePages().start(oversized, scope:"synthetic", request:q)
        try require(tooBig.state == .responseTooLarge && tooBig.adaptation?.nextCursor == nil && tooBig.adaptation?.failureReason != nil, "untransmittable_item_not_explicit")
        let hotelResult = TravelReadResult(request:hotel,state:h.state,payload:h.payload,httpStatus:h.httpStatus)
        mio.append(["tool":"mio_flyai_search_hotel", "arguments":["dest_name":"Example city"], "result":try JSONSerialization.jsonObject(with:JSONEncoder().encode(hotelResult))])
        try json(["cases":mio]).write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
        print("{\"status\":\"PASS\",\"raw_types_and_optional_evolution\":true,\"parameters_and_errors\":true,\"whole_item_pages\":\(rounds),\"provider_calls_for_all_pages\":1,\"real_credentials\":false,\"network\":false}")
    }
}
