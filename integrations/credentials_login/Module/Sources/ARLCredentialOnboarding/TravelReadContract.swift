import Foundation
import CoreFoundation

/// The complete public Mio travel read surface. No caller-selected URL, method, headers or credentials.
public enum TravelReadOperation: String, Codable, CaseIterable, Sendable {
    case geo = "mio_maps_geo", regeocode = "mio_maps_regeocode"
    case textSearch = "mio_maps_text_search", aroundSearch = "mio_maps_around_search"
    case detail = "mio_maps_search_detail", driving = "mio_maps_direction_driving"
    case walking = "mio_maps_direction_walking", bicycling = "mio_maps_bicycling"
    case transit = "mio_maps_direction_transit_integrated", distance = "mio_maps_distance"
    case weather = "mio_maps_weather", flight = "mio_flyai_search_flight", hotel = "mio_flyai_search_hotel"
    case keywordSearch = "mio_flyai_keyword_search", aiSearch = "mio_flyai_ai_search"
    case train = "mio_flyai_search_train", poi = "mio_flyai_search_poi"
    public var purpose: CredentialPurpose {
        switch self {
        case .flight, .hotel, .keywordSearch, .aiSearch, .train, .poi: .fliggyTravelReadOnly
        default: .amapMapsWeather
        }
    }
}

public enum TravelReadError: String, Error, Codable, Sendable {
    case invalidArguments, unsupportedTool
}

/// Immutable, validated request. JSON is an input adapter for the existing public schema, not a transport escape hatch.
public struct TravelReadRequest: Sendable {
    public let operation: TravelReadOperation
    public var toolName: String { operation.rawValue }
    public var purpose: CredentialPurpose { operation.purpose }
    let strings: [String: String]
    let maximumPrice: Double?
    let parameters: [String: MusicProviderValue]
    let cursor: UUID?
    static let flyNames = ["origin":"origin", "destination":"destination", "dep_date":"depDate", "dep_date_start":"depDateStart", "dep_date_end":"depDateEnd", "back_date":"backDate", "back_date_start":"backDateStart", "back_date_end":"backDateEnd", "seat_class_name":"seatClassName", "transport_no":"transportNo", "transfer_city":"transferCity", "journey_type":"journeyType", "sort_type":"sortType", "dep_hour_start":"depHourStart", "dep_hour_end":"depHourEnd", "arr_hour_start":"arrHourStart", "arr_hour_end":"arrHourEnd", "total_duration_hour":"totalDurationHour", "max_price":"maxPrice", "limit":"limit", "dest_name":"destName", "key_words":"keyWords", "poi_name":"poiName", "hotel_types":"hotelTypes", "hotel_stars":"hotelStars", "hotel_bed_types":"hotelBedTypes", "sort":"sort", "check_in_date":"checkInDate", "check_out_date":"checkOutDate", "query":"query", "city_name":"cityName", "poi_level":"poiLevel", "keyword":"keyword", "category":"category"]
    static func fields(_ operation: TravelReadOperation) -> (Set<String>, Set<String>) {
        switch operation {
        case .geo: (["address"], ["city","batch"])
        case .regeocode: (["location"], ["poitype","radius","extensions","batch","roadlevel","homeorcorp"])
        case .textSearch: ([], ["keywords","types","city","citylimit","children","offset","page","extensions","langCode"])
        case .aroundSearch: (["location"], ["keywords","types","city","radius","sortrule","offset","page","extensions","langCode"])
        case .detail: (["id"], [])
        case .driving: (["origin","destination"], ["originid","destinationid","strategy","waypoints","avoidpolygons","avoidroad","province","number","cartype","ferry","roadaggregation","nosteps","extensions"])
        case .walking, .bicycling: (["origin","destination"], [])
        case .transit: (["origin","destination","city"], ["cityd","strategy","nightflag","date","time","extensions"])
        case .distance: (["origins","destination"], ["type"])
        case .weather: ([], ["adcode","mode","city","extensions"])
        case .flight: (["origin"], ["destination","dep_date","dep_date_start","dep_date_end","back_date","back_date_start","back_date_end","seat_class_name","transport_no","transfer_city","journey_type","sort_type","dep_hour_start","dep_hour_end","arr_hour_start","arr_hour_end","total_duration_hour","max_price","limit"])
        case .keywordSearch, .aiSearch: (["query"], [])
        case .train: (["origin"], ["destination","dep_date","dep_date_start","dep_date_end","back_date","back_date_start","back_date_end","seat_class_name","transport_no","transfer_city","journey_type","sort_type","dep_hour_start","dep_hour_end","arr_hour_start","arr_hour_end","total_duration_hour","max_price"])
        case .poi: (["city_name"], ["keyword","poi_level","category"])
        case .hotel: (["dest_name"], ["check_in_date","check_out_date","key_words","poi_name","hotel_types","hotel_stars","hotel_bed_types","sort","max_price","limit"])
        }
    }
    public init(toolName: String, argumentsJSON: Data) throws {
        guard let operation = TravelReadOperation(rawValue: toolName) else { throw TravelReadError.unsupportedTool }
        guard var object = try? MusicStrictJSON.object(argumentsJSON, limit: 65536) else { throw TravelReadError.invalidArguments }
        let (required, optional) = Self.fields(operation)
        guard required.isSubset(of: Set(object.keys)), Set(object.keys).isSubset(of: required.union(optional).union(["cursor"])) else { throw TravelReadError.invalidArguments }
        if let value = object.removeValue(forKey: "cursor") {
            guard let text = value as? String, text.count == 36, let cursor = UUID(uuidString: text) else { throw TravelReadError.invalidArguments }
            self.cursor = cursor
        } else { cursor = nil }
        let typed = try JSONDecoder().decode([String: MusicProviderValue].self, from: argumentsJSON)
        func queryText(_ value: MusicProviderValue) throws -> String {
            switch value {
            case .text(let v): v
            case .integer(let v): String(v)
            case .unsigned(let v): String(v)
            case .decimal(let v): NSDecimalNumber(decimal: v).stringValue
            case .number(let v): String(v)
            case .boolean(let v): v ? "true" : "false"
            default: throw TravelReadError.invalidArguments
            }
        }
        var strings: [String: String] = [:]
        for (key, value) in object {
            if let text = value as? String {
                guard !text.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw TravelReadError.invalidArguments }; strings[key] = text
            }
            else if let number = value as? NSNumber, number.doubleValue.isFinite {
                strings[key] = try queryText(typed[key]!)
            } else { throw TravelReadError.invalidArguments }
        }
        guard required.allSatisfy({ strings[$0]?.isEmpty == false }) else { throw TravelReadError.invalidArguments }
        if operation == .textSearch { guard strings["keywords"]?.isEmpty == false || strings["types"]?.isEmpty == false else { throw TravelReadError.invalidArguments } }
        if operation == .weather {
            guard strings["adcode"]?.isEmpty == false || strings["city"]?.isEmpty == false,
                  strings["adcode"] == nil || strings["city"] == nil || strings["adcode"] == strings["city"],
                  strings["mode"] == nil || ["current","forecast"].contains(strings["mode"]!),
                  strings["mode"] == nil || strings["extensions"] == nil || strings["extensions"] == (strings["mode"] == "forecast" ? "all" : "base") else { throw TravelReadError.invalidArguments }
        }
        var parameters: [String: MusicProviderValue] = [:]
        let numeric: Set<String> = ["journey_type","sort_type","dep_hour_start","dep_hour_end","arr_hour_start","arr_hour_end","total_duration_hour","max_price","limit","poi_level"]
        for (key, value) in object {
            if operation.purpose == .fliggyTravelReadOnly {
                guard let target = Self.flyNames[key] else { throw TravelReadError.invalidArguments }
                if numeric.contains(key) {
                    let scalar: MusicProviderValue
                    if let text = value as? String {
                        guard let decoded = try? JSONDecoder().decode(MusicProviderValue.self, from: Data(text.utf8)) else { throw TravelReadError.invalidArguments }; scalar = decoded
                    } else { scalar = typed[key]! }
                    switch scalar {
                    case .integer, .unsigned, .decimal, .number: parameters[target] = scalar
                    default: throw TravelReadError.invalidArguments
                    }
                } else { guard let text = value as? String else { throw TravelReadError.invalidArguments }; parameters[target] = .text(text) }
            } else if key != "adcode" && key != "mode" { parameters[key] = .text(strings[key]!) }
        }
        if operation == .weather {
            parameters["city"] = .text(strings["city"] ?? strings["adcode"]!)
            if let mode = strings["mode"] { parameters["extensions"] = .text(mode == "forecast" ? "all" : "base") }
        }
        if operation == .poi, let level = parameters["poiLevel"] {
            guard let encoded = try? JSONEncoder().encode(level),
                  let number = String(data: encoded, encoding: .utf8).flatMap(Int.init), (1...5).contains(number)
            else { throw TravelReadError.invalidArguments }
        }
        self.operation = operation; self.strings = strings; self.parameters = parameters
        maximumPrice = TravelProviderValue.number(object["max_price"])
    }
    var binding: Data {
        get throws { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return try encoder.encode(parameters) }
    }
    static func matches(_ value: String, _ pattern: String) -> Bool { value.range(of: pattern, options: .regularExpression) != nil }
    static func validDate(_ value: String) -> Bool {
        guard matches(value, "^[0-9]{4}-[0-9]{2}-[0-9]{2}$") else { return false }
        let pieces = value.split(separator: "-").compactMap { Int($0) }
        guard pieces.count == 3, pieces[0] >= 1 else { return false }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(year: pieces[0], month: pieces[1], day: pieces[2])
        guard let date = calendar.date(from: components) else { return false }
        let result = calendar.dateComponents([.year, .month, .day], from: date)
        return result.year == pieces[0] && result.month == pieces[1] && result.day == pieces[2]
    }
}

public enum TravelReadState: String, Codable, Sendable {
    case succeeded, setupRequired, invalidOrExpired, permissionDenied, quotaExceeded, rateLimited
    case serviceExpired, vendorUnavailable, networkUnavailable, timedOut, cancelled, protocolFailure
    case noData, locationMismatch, responseTooLarge, invalidArguments, providerRejected
    static func fromConnection(_ state: ConnectionState) -> TravelReadState {
        switch state {
        case .invalidOrExpired: .invalidOrExpired
        case .permissionDenied: .permissionDenied
        case .quotaExceeded: .quotaExceeded
        case .rateLimited: .rateLimited
        case .serviceExpired: .serviceExpired
        case .vendorUnavailable: .vendorUnavailable
        default: .protocolFailure
        }
    }
}
public enum TravelReadNotice: String, Codable, Sendable {
    case poiTypesNotAppliedBySourceContract, displayedPriceIsNotFinalPayablePrice, forecastHorizonIsProviderSupplied
}
// Native owner supplies this scope after leasing the selected credential.
enum TravelReadAuthorization {
    @TaskLocal static var generation: UUID?
}
public struct TravelReadAdaptation: Codable, Sendable {
    public let forwardedParameters: [String: MusicProviderValue]
    public let injectedDefaults: [String: MusicProviderValue]
    public let responseKind: String
    public let omittedAuthenticationFields: [String]
    public var partial = false
    public var itemPath: [String]? = nil
    public var sourceItemCount: Int? = nil
    public var returnedItemOffset: Int? = nil
    public var returnedItemCount: Int? = nil
    public var nextCursor: String? = nil
    public var localContinuationEnd = true
    public var failureReason: String? = nil
    public var snapshotAgeSeconds: Int? = nil
    enum CodingKeys: String, CodingKey {
        case forwardedParameters = "forwarded_parameters", injectedDefaults = "injected_defaults", responseKind = "response_kind", omittedAuthenticationFields = "omitted_authentication_fields"
        case partial, itemPath = "item_path", sourceItemCount = "source_item_count", returnedItemOffset = "returned_item_offset", returnedItemCount = "returned_item_count", nextCursor = "next_cursor", localContinuationEnd = "local_continuation_end", failureReason = "failure_reason", snapshotAgeSeconds = "snapshot_age_seconds"
    }
}
public struct TravelReadResult: Codable, Sendable {
    public let schemaVersion: Int
    public let toolName: String
    public let state: TravelReadState
    public let fetchedAtMilliseconds: Int64
    public let notices: [TravelReadNotice]
    public let payload: TravelReadPayload?
    public let diagnostic: TravelProviderDiagnostic?
    public let httpStatus: Int?
    public let adaptation: TravelReadAdaptation?
    init(request: TravelReadRequest, state: TravelReadState, payload: TravelReadPayload? = nil, diagnostic: TravelProviderDiagnostic? = nil,
         httpStatus: Int? = nil, adaptation: TravelReadAdaptation? = nil, fetchedAtMilliseconds: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) {
        schemaVersion = 2; toolName = request.toolName; self.state = state; self.payload = payload; self.diagnostic = diagnostic; self.httpStatus = httpStatus; self.adaptation = adaptation
        self.fetchedAtMilliseconds = fetchedAtMilliseconds
        notices = [] // Compatibility key; raw provider fields decide price and travel semantics.
    }
    enum CodingKeys: String, CodingKey {
        case schemaVersion, toolName, state, fetchedAtMilliseconds, notices, payload, diagnostic, httpStatus = "http_status", adaptation
    }
}
/// The provider business object itself; no fixed DTO field/type projection.
public typealias TravelReadPayload = MusicProviderValue
