import Foundation
import CryptoKit

protocol TravelReadTransport: Sendable {
    func sendRead(_ secret: CredentialInput, request: TravelReadRequest) async -> TravelReadResult
}

enum FlyAIReadTool: String {
    case credentialProbe = "fliggy_fast_search", flight = "search_flight", hotel = "search_hotels"
    case aiSearch = "fliggy_ai_search", train = "search_domestic_train", poi = "search_poi"
    static func tool(for operation: TravelReadOperation) throws -> FlyAIReadTool {
        switch operation {
        case .keywordSearch: .credentialProbe
        case .aiSearch: .aiSearch
        case .flight: .flight
        case .hotel: .hotel
        case .train: .train
        case .poi: .poi
        default: throw TravelReadError.unsupportedTool
        }
    }
}

/// Source-derived requests only. Transport ownership stays inside the credential SDK.
struct TravelReadClient: TravelReadTransport {
    let transport: any ProbeTransport
    let flyAIProfile: FlyAIGatewayProfile?
    let allowedPurposes: Set<CredentialPurpose>
    var pages: TravelResponsePages = .shared

    func sendRead(_ secret: CredentialInput, request: TravelReadRequest) async -> TravelReadResult {
        guard allowedPurposes.contains(request.purpose), secret.purpose == request.purpose,
              request.purpose != .fliggyTravelReadOnly || flyAIProfile != nil else {
            return .init(request: request, state: .setupRequired)
        }
        var observedHTTPStatus: Int?
        do {
            try Task.checkCancellation()
            if let bounded = transport as? BoundedHTTPS { try bounded.gate.verify() }
            var bytes = try secret.copyBytes(for: request.purpose)
            defer { bytes.resetBytes(in: 0..<bytes.count) }
            guard let key = String(data: bytes, encoding: .utf8) else { return .init(request: request, state: .protocolFailure) }
            let scope = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() + ":" + (TravelReadAuthorization.generation?.uuidString ?? "direct-sdk")
            if let cursor = request.cursor { return try await pages.resume(cursor, scope: scope, request: request) }
            var wire = try makeRequest(secret, request: request)
            wire.responseByteLimit = TravelReadLimits.providerBytes
            let response = try await transport.send(wire)
            observedHTTPStatus = response.status
            try Task.checkCancellation()
            let authentication = ["Authorization", "x-ff-ctx", "x-flyai-sign"].compactMap { wire.request.value(forHTTPHeaderField: $0) }
            let projected = try TravelReadProjection(secret: key, additionalSecrets: authentication).project(response, request: request)
            return try await pages.start(projected, scope: scope, request: request)
        } catch let failure as TravelReadProjectionFailure { return .init(request: request, state: failure.state, diagnostic: failure.diagnostic, httpStatus: observedHTTPStatus) }
        catch let failure as FlyAIResponseFailure { return .init(request: request, state: .fromConnection(failure.state), diagnostic: failure.diagnostic, httpStatus: observedHTTPStatus) }
        catch is CancellationError { return .init(request: request, state: .cancelled) }
        catch let failure as TransportFailure {
            let state: TravelReadState
            switch failure {
            case .network: state = .networkUnavailable
            case .timeout: state = .timedOut
            case .cancelled: state = .cancelled
            case .responseLimit: state = .responseTooLarge
            case .redirect, .protocolFailure: state = .protocolFailure
            }
            return .init(request: request, state: state)
        } catch { return .init(request: request, state: .protocolFailure) }
    }

    func makeRequest(_ input: CredentialInput, request: TravelReadRequest) throws -> ProbeRequest {
        guard input.purpose == request.purpose else { throw CredentialError.wrongPurpose }
        var bytes = try input.copyBytes(for: request.purpose)
        defer { bytes.resetBytes(in: 0..<bytes.count) }
        guard let key = String(data: bytes, encoding: .utf8) else { throw CredentialError.invalidInput }
        if request.purpose == .fliggyTravelReadOnly {
            guard let profile = flyAIProfile else { throw CredentialError.deploymentNotApproved }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            var wire = try VendorValidator.flyAIRequest(key: key, profile: profile,
                tool: FlyAIReadTool.tool(for: request.operation), argumentsJSON: encoder.encode(request.parameters))
            // Semantic AI search may wait for the provider's generation; credential
            // probes and the other reads retain their existing short budgets.
            if request.operation == .aiSearch {
                wire.remainingSeconds = TravelReadLimits.aiSearchSeconds
                wire.requestTimeoutSeconds = TravelReadLimits.aiSearchSeconds
            }
            return wire
        }
        let path = Self.path(request.operation)
        var query: [String: String] = [:]
        for (key, value) in request.parameters { if case .text(let text) = value { query[key] = text } }
        query["output"] = "JSON" // Transport representation, explicitly disclosed in adaptation.
        query["key"] = key
        var components = URLComponents(); components.scheme = "https"; components.host = "restapi.amap.com"; components.path = path
        components.queryItems = query.keys.sorted().map { URLQueryItem(name: $0, value: query[$0]) }
        guard let url = components.url else { throw CredentialError.invalidInput }
        var wire = URLRequest(url: url); wire.httpMethod = "GET"; wire.setValue("application/json", forHTTPHeaderField: "Accept")
        return .init(purpose: request.purpose, request: wire)
    }
    static func path(_ operation: TravelReadOperation) -> String {
        switch operation {
        case .geo: "/v3/geocode/geo"
        case .regeocode: "/v3/geocode/regeo"
        case .textSearch: "/v3/place/text"
        case .aroundSearch: "/v3/place/around"
        case .detail: "/v3/place/detail"
        case .driving: "/v3/direction/driving"
        case .walking: "/v3/direction/walking"
        case .bicycling: "/v4/direction/bicycling"
        case .transit: "/v3/direction/transit/integrated"
        case .distance: "/v3/distance"
        case .weather: "/v3/weather/weatherInfo"
        case .flight, .hotel, .keywordSearch, .aiSearch, .train, .poi: "/mcp"
        }
    }

}

/// Defense in depth for every SDK probe/read request, including injected transports in tests.
enum TravelReadWirePolicy {
    static func allows(_ probe: ProbeRequest) -> Bool {
        guard let url = probe.request.url, url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil, url.fragment == nil else { return false }
        if probe.purpose == .amapMapsWeather {
            guard let operation = TravelReadOperation.allCases.first(where: { $0.purpose == .amapMapsWeather && TravelReadClient.path($0) == url.path }),
                  url.host == "restapi.amap.com", probe.request.httpMethod == "GET", probe.request.httpBody == nil,
                  let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
                  Set(items.map(\.name)).count == items.count else { return false }
            let (required, optional) = TravelReadRequest.fields(operation)
            let names = Set(items.map(\.name))
            let allowed = required.union(optional).subtracting(["adcode","mode"]).union(["key","output","source"])
            guard names.contains("key"), required.isSubset(of: names), names.isSubset(of: allowed) else { return false }
            return true
        }
        guard probe.purpose == .fliggyTravelReadOnly, url.host == "flyai.open.fliggy.com", url.path == "/mcp",
              url.query == nil, probe.request.httpMethod == "POST", let body = probe.request.httpBody,
              let object = try? MusicStrictJSON.object(body, limit: 32768),
              object["jsonrpc"] as? String == "2.0", FlyAIMCPResponse.matchesRequestID(object["id"], expected: 1), object["method"] as? String == "tools/call",
              let params = object["params"] as? [String: Any], let name = params["name"] as? String,
              FlyAIReadTool(rawValue: name) != nil, params["arguments"] is [String: Any] else { return false }
        return true
    }
}

/// Bounded read-response snapshots only, in memory. No new disk or credential custody.
/// Cursors bind exact provider arguments, operation, leased credential and generation.
actor TravelResponsePages {
    static let shared = TravelResponsePages()
    private struct Snapshot: Sendable {
        let response: TravelProjectedResponse
        let path: [String]
        let rows: [MusicProviderValue]
        let createdAt: TimeInterval
        let fetchedAt: Int64
    }
    private struct Entry: Sendable {
        let snapshot: Snapshot
        let scope: String
        let binding: Data
        let tool: String
        let offset: Int
        let bytes: Int
    }
    private var entries: [UUID: Entry] = [:]
    private var replies: [UUID: TravelReadResult] = [:]
    private let ttl: TimeInterval = 300
    private let maximumEntries = 8, maximumBytes = 4_194_304
    private func prune(_ now: TimeInterval) {
        entries = entries.filter { now >= $0.value.snapshot.createdAt && now - $0.value.snapshot.createdAt < ttl }
        replies = replies.filter { entries[$0.key] != nil }
    }
    private func encoded(_ result: TravelReadResult) throws -> Int {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(result).count
    }
    private func value(_ root: MusicProviderValue, path: ArraySlice<String>) -> MusicProviderValue? {
        guard let key = path.first else { return root }
        guard case .object(let object) = root, let child = object[key] else { return nil }
        return value(child, path: path.dropFirst())
    }
    private func replace(_ root: MusicProviderValue, path: ArraySlice<String>, rows: [MusicProviderValue]) -> MusicProviderValue {
        guard let key = path.first else { return .array(rows) }
        guard case .object(var object) = root, let child = object[key] else { return root }
        object[key] = replace(child, path: path.dropFirst(), rows: rows); return .object(object)
    }
    private func itemPath(_ operation: TravelReadOperation, payload: MusicProviderValue) -> [String]? {
        let path: [String]
        switch operation {
        case .geo: path = ["geocodes"]
        case .textSearch, .aroundSearch, .detail: path = ["pois"]
        case .driving, .walking: path = ["route", "paths"]
        case .bicycling: path = ["data", "paths"]
        case .transit: path = ["route", "transits"]
        case .distance: path = ["results"]
        case .flight, .hotel, .keywordSearch, .train, .poi: path = ["data", "itemList"]
        case .weather: path = value(payload, path: ["lives"][...]) != nil ? ["lives"] : ["forecasts"]
        case .regeocode, .aiSearch: return nil
        }
        guard case .array = value(payload, path: path[...]) else { return nil }; return path
    }
    private func adaptation(_ response: TravelProjectedResponse, request: TravelReadRequest) -> TravelReadAdaptation {
        .init(forwardedParameters: request.parameters, injectedDefaults: request.purpose == .amapMapsWeather ? ["output": .text("JSON")] : [:], responseKind: response.responseKind, omittedAuthenticationFields: response.omittedAuthenticationFields)
    }
    func start(_ response: TravelProjectedResponse, scope: String, request: TravelReadRequest) throws -> TravelReadResult {
        let now = ProcessInfo.processInfo.systemUptime; prune(now)
        let full = TravelReadResult(request: request, state: response.state, payload: response.payload, diagnostic: response.diagnostic, httpStatus: response.httpStatus, adaptation: adaptation(response, request: request))
        if try encoded(full) <= TravelReadLimits.payloadBytes { return full }
        guard let path = itemPath(request.operation, payload: response.payload), case .array(let rows) = value(response.payload, path: path[...]) else {
            var a = adaptation(response, request: request); a.partial = true; a.failureReason = "provider_object_exceeds_owner_frame"
            return .init(request: request, state: .responseTooLarge, diagnostic: response.diagnostic, httpStatus: response.httpStatus, adaptation: a)
        }
        let snapshot = Snapshot(response: response, path: path, rows: rows, createdAt: now, fetchedAt: full.fetchedAtMilliseconds)
        return try deliver(snapshot, offset: 0, scope: scope, request: request, now: now)
    }
    func resume(_ cursor: UUID, scope: String, request: TravelReadRequest) throws -> TravelReadResult {
        let now = ProcessInfo.processInfo.systemUptime; prune(now)
        guard let entry = entries[cursor], entry.scope == scope, entry.tool == request.toolName, entry.binding == (try request.binding) else {
            var a = TravelReadAdaptation(forwardedParameters: request.parameters, injectedDefaults: [:], responseKind: "local_cursor", omittedAuthenticationFields: [])
            a.partial = true; a.failureReason = "cursor_expired_or_query_or_authorization_changed"
            return .init(request: request, state: .invalidArguments, adaptation: a)
        }
        if let reply=replies[cursor] { return reply }
        let reply=try deliver(entry.snapshot, offset: entry.offset, scope: scope, request: request, now: now)
        replies[cursor]=reply;return reply
    }
    private func deliver(_ snapshot: Snapshot, offset: Int, scope: String, request: TravelReadRequest, now: TimeInterval) throws -> TravelReadResult {
        let token = UUID(), total = snapshot.rows.count
        func result(_ count: Int, failure: String? = nil) -> TravelReadResult {
            let end = offset + count
            var a = adaptation(snapshot.response, request: request)
            a.partial = offset > 0 || end < total || failure != nil; a.itemPath = snapshot.path; a.sourceItemCount = total
            a.returnedItemOffset = offset; a.returnedItemCount = count; a.localContinuationEnd = end == total
            a.nextCursor = end < total && failure == nil ? token.uuidString : nil; a.failureReason = failure
            a.snapshotAgeSeconds = max(0, Int(now - snapshot.createdAt))
            let payload = replace(snapshot.response.payload, path: snapshot.path[...], rows: Array(snapshot.rows[offset..<end]))
            return .init(request: request, state: failure == nil ? snapshot.response.state : .responseTooLarge, payload: payload,
                         diagnostic: snapshot.response.diagnostic, httpStatus: snapshot.response.httpStatus, adaptation: a, fetchedAtMilliseconds: snapshot.fetchedAt)
        }
        var low = 0, high = total - offset, best = -1
        while low <= high {
            let count = (low + high) / 2
            if try encoded(result(count)) <= TravelReadLimits.payloadBytes { best = count; low = count + 1 } else { high = count - 1 }
        }
        guard best > 0 else {
            let failure = result(0, failure: "single_item_or_metadata_exceeds_owner_frame")
            if try encoded(failure) <= TravelReadLimits.payloadBytes { return failure }
            var a = adaptation(snapshot.response, request: request); a.partial = true; a.failureReason = "single_item_or_metadata_exceeds_owner_frame"
            return .init(request: request, state: .responseTooLarge, httpStatus: snapshot.response.httpStatus, adaptation: a)
        }
        let delivered = result(best)
        if offset + best < total {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let size = try encoder.encode(snapshot.response.payload).count
            guard size <= maximumBytes else { return result(best, failure: "snapshot_exceeds_local_capacity") }
            entries[token] = .init(snapshot: snapshot, scope: scope, binding: try request.binding, tool: request.toolName, offset: offset + best, bytes: size)
        }
        return delivered
    }
}
