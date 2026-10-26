import Foundation
import CoreFoundation

/// Only the owner write/recovery path selects compact membership verification.
enum MusicReadPurpose {
    @TaskLocal static var verification = false
}

/// The signed owner accepts only these bounded reads. No command, URL, HOME,
/// account token or arbitrary provider parameters are accepted from callers.
public enum MusicReadRequest: Sendable, Equatable {
    case search(keyword: String, offset: Int = 0)
    case library(MusicLibraryReadRequest)
    // Used only by the owner aggregator; no separate public RPC or source selector.
    case cloudSongs(cursor: String?, limit: Int = 50)
    case userPlaylists
    case playlistDetail(playlistID: String)
    case userPlaylistsPage(offset: Int)
    case playlistDetailPage(playlistID: String, offset: Int)

    var paginationOffset: Int {
        switch self {
        case .userPlaylistsPage(let offset), .playlistDetailPage(_, let offset): offset
        default: 0
        }
    }

    var operation: String {
        switch self {
        case .library(let request): request.operation.rawValue
        case .search: "search"
        case .cloudSongs: "cloud_songs"
        case .userPlaylists, .userPlaylistsPage: "user_playlists"
        case .playlistDetail, .playlistDetailPage: "playlist_detail"
        }
    }
    var arguments: [String: String] {
        switch self {
        case .library(let request): request.parameters
        case .search(let keyword, let offset): ["keyword": keyword, "offset": String(offset)]
        case .cloudSongs(let cursor, let limit): (cursor.map { ["cursor": $0] } ?? [:]).merging(["limit": String(limit)]) { _, value in value }
        case .userPlaylists: [:]
        case .userPlaylistsPage(let offset): ["offset": String(offset)]
        case .playlistDetailPage(let id, let offset): ["playlist_id": id.lowercased(), "offset": String(offset)]
        case .playlistDetail(let id): ["playlist_id": id.lowercased()]
        }
    }
    func validate() throws {
        guard (0...99999).contains(paginationOffset) else { throw CredentialError.invalidInput }
        switch self {
        case .library(let request): try request.validate()
        case .search(let keyword, let offset):
            guard offset>=0, keyword.count <= 100, MusicReadProtocol.validText(keyword, limit: 400), !keyword.hasPrefix("-") else { throw CredentialError.invalidInput }
        case .cloudSongs(let cursor, let limit):
            guard (1...50).contains(limit), cursor == nil || MusicReadProtocol.validCursor(cursor!) else { throw CredentialError.invalidInput }
        case .userPlaylists, .userPlaylistsPage: break
        case .playlistDetail(let id), .playlistDetailPage(let id, _):
            guard MusicReadProtocol.validID(id) else { throw CredentialError.invalidInput }
        }
    }
}

public enum MusicReadState: String, Codable, Sendable {
    case authorizedRead = "authorized_read"
    case loginRequired = "login_required"
    case refreshRejected = "refresh_rejected"
    case providerRejected = "provider_rejected"
    case contractRejected = "contract_rejected"
    case providerUnavailable = "provider_unavailable"
}
public enum MusicReadSession: String, Codable, Sendable {
    case present, refreshed, missing, rejected, unconfirmed
}
/// JSON business values retain strings, numbers, booleans, arrays, objects and null.
public indirect enum MusicProviderValue: Codable, Sendable, Equatable {
    case null, boolean(Bool), integer(Int64), unsigned(UInt64), decimal(Decimal), number(Double), text(String), array([Self]), object([String: Self])
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .boolean(v) }
        else if let v = try? c.decode(Int64.self) { self = .integer(v) }
        else if let v = try? c.decode(UInt64.self) { self = .unsigned(v) }
        else if let v = try? c.decode(Decimal.self) { self = .decimal(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .text(v) }
        else if let v = try? c.decode([Self].self) { self = .array(v) }
        else { self = .object(try c.decode([String: Self].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .boolean(let v): try c.encode(v)
        case .integer(let v): try c.encode(v)
        case .unsigned(let v): try c.encode(v)
        case .decimal(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .text(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
}
// Explicit authentication keys and contexts, not substring guesses about business names.
// Unknown arbitrary data cannot be proved secret-free by a key-name policy alone.
enum ProviderBusinessPolicy {
    static let authenticationKeys: Set<String> = ["accesstoken","refreshtoken","authtoken","idtoken","sessionkey","namedtoken","namedrefreshtoken","token","privatekey","apikey","clientsecret","password","authorization","proxyauthorization","cookie","setcookie","xflyaisign","xffctx"]
    static let authenticationContexts: Set<String> = ["auth","authentication","oauth","credentials","credential","headers","requestheaders"]
    static let contextKeys: Set<String> = ["session","sessionid","secret","key","signature","deviceid","appid"]
    static func normalized(_ key: String) -> String { key.replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "-", with: "").lowercased() }
    static func isAuthenticationKey(_ key: String, context: Bool) -> Bool {
        authenticationKeys.contains(normalized(key)) || context && contextKeys.contains(normalized(key))
    }
    static func authenticationURL(_ text: String) -> Bool {
        guard let url = URLComponents(string: text), url.scheme != nil else { return false }
        let apiHost = ["restapi.amap.com","flyai.open.fliggy.com","openncm.music.163.com"].contains(url.host?.lowercased() ?? "")
        let urlKeys = authenticationKeys.union(["xamzcredential","xamzsignature","xamzsecuritytoken"]).union(apiHost ? ["sign","sig","signature","key","session","sessionid"] : [])
        if url.user != nil || url.password != nil || (url.queryItems ?? []).contains(where: { urlKeys.contains(normalized($0.name)) }) { return true }
        let fragment = url.percentEncodedFragment?.removingPercentEncoding ?? url.fragment ?? ""
        return fragment.split(whereSeparator: { "?&;".contains($0) }).contains { part in
            guard let split = part.firstIndex(of: "=") else { return false }
            return urlKeys.contains(normalized(String(part[..<split])))
        }
    }
    static func validate(_ raw: Any, context: Bool = false) throws {
        if let fields = raw as? [String: Any] {
            for (key, item) in fields {
                guard !isAuthenticationKey(key, context: context) else { throw CredentialError.uncertainLocalState }
                try validate(item, context: context || authenticationContexts.contains(normalized(key)))
            }
        } else if let rows = raw as? [Any] { for row in rows { try validate(row, context: context) } }
        else if let text = raw as? String, authenticationURL(text) { throw CredentialError.uncertainLocalState }
    }
}
public struct MusicProviderRecord: Codable, Sendable, Equatable {
    public let fields: [String: MusicProviderValue]
    public let omittedAuthenticationFields: [String]
    enum CodingKeys: String, CodingKey { case fields, omittedAuthenticationFields = "omitted_authentication_fields" }
}
public struct MusicReadSong: Codable, Sendable, Equatable {
    public let songID: String
    public let name: String
    public let url: URL?
    public let visible: Bool?
    public let metadata: MusicReadSongMetadata
    public let privateCloudSong: Bool?
    public let playFlag: Bool?
    public let providerRecord: MusicProviderRecord?
    init(songID: String, name: String, url: URL?, visible: Bool?, metadata: MusicReadSongMetadata = .unknown,
         privateCloudSong: Bool? = nil, playFlag: Bool? = nil, providerRecord: MusicProviderRecord? = nil) {
        self.providerRecord = providerRecord
        self.privateCloudSong = privateCloudSong; self.playFlag = playFlag
        self.songID = songID; self.name = name; self.url = url; self.visible = visible; self.metadata = metadata
    }
    enum CodingKeys: String, CodingKey { case songID = "song_id", name, url, visible, metadata, privateCloudSong = "private_cloud_song", playFlag = "play_flag", providerRecord = "provider_record" }
}
/// Provider business fields only. IDs retain their source type; unknown units
/// and recording editions are never inferred from origin/cover classification.
public enum MusicBusinessScalar: Codable, Sendable, Equatable {
    case boolean(Bool), integer(Int64), text(String)
    public init(from decoder: Decoder) throws {
        let c=try decoder.singleValueContainer()
        if let v=try? c.decode(Bool.self){self = .boolean(v)}
        else if let v=try? c.decode(Int64.self){self = .integer(v)}
        else {self = .text(try c.decode(String.self))}
    }
    public func encode(to encoder: Encoder) throws {
        var c=encoder.singleValueContainer()
        switch self {case .boolean(let v):try c.encode(v);case .integer(let v):try c.encode(v);case .text(let v):try c.encode(v)}
    }
}
public struct MusicBusinessEntity: Codable, Sendable, Equatable {
    public let id: String?
    public let idSourceType: String?
    public let name: String?
    enum CodingKeys:String,CodingKey {case id,name,idSourceType="id_source_type"}
    public func encode(to encoder:Encoder)throws {
        var c=encoder.container(keyedBy:CodingKeys.self);try c.encode(id,forKey:.id);try c.encode(idSourceType,forKey:.idSourceType);try c.encode(name,forKey:.name)
    }
}
public struct MusicSongBusinessInfo: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let sourceOperation: String
    public let artists: [MusicBusinessEntity]?
    public let artistsSourceField: String?
    public let album: MusicBusinessEntity?
    public let albumSourceField: String?
    public let durationRaw: Int64?
    public let durationUnit: String?
    public let durationSourceField: String
    public let originCoverCategory: String
    public let recordingEdition: String?
    public let legacyRecordingVersionSemantics: String
    public let availabilitySemantics: String
    public let providerFlags: [String: MusicBusinessScalar]
    public let unknownReasons: [String: String]
    enum CodingKeys:String,CodingKey {
        case schemaVersion="schema_version",sourceOperation="source_operation",artists,artistsSourceField="artists_source_field",album,albumSourceField="album_source_field"
        case durationRaw="duration_raw",durationUnit="duration_unit",durationSourceField="duration_source_field",originCoverCategory="origin_cover_category",recordingEdition="recording_edition"
        case legacyRecordingVersionSemantics="legacy_recording_version_semantics",availabilitySemantics="availability_semantics",providerFlags="provider_flags",unknownReasons="unknown_reasons"
    }
    public func encode(to encoder:Encoder)throws {
        var c=encoder.container(keyedBy:CodingKeys.self)
        try c.encode(schemaVersion,forKey:.schemaVersion);try c.encode(sourceOperation,forKey:.sourceOperation)
        try c.encode(artists,forKey:.artists);try c.encode(artistsSourceField,forKey:.artistsSourceField);try c.encode(album,forKey:.album);try c.encode(albumSourceField,forKey:.albumSourceField)
        try c.encode(durationRaw,forKey:.durationRaw);try c.encode(durationUnit,forKey:.durationUnit);try c.encode(durationSourceField,forKey:.durationSourceField)
        try c.encode(originCoverCategory,forKey:.originCoverCategory);try c.encode(recordingEdition,forKey:.recordingEdition)
        try c.encode(legacyRecordingVersionSemantics,forKey:.legacyRecordingVersionSemantics);try c.encode(availabilitySemantics,forKey:.availabilitySemantics)
        try c.encode(providerFlags,forKey:.providerFlags);try c.encode(unknownReasons,forKey:.unknownReasons)
    }
}
public struct MusicProviderBusinessStatus: Codable, Sendable, Equatable {
    public let code: MusicBusinessScalar?
    public let subCode: MusicBusinessScalar?
    public let classification: String
    enum CodingKeys:String,CodingKey {case code,subCode="sub_code",classification}
}
public struct MusicReadSongMetadata: Codable, Sendable, Equatable {
    public let artists: [String]?
    public let album: String?
    public let recordingVersion: String?
    public let durationMS: Int?
    public var originCoverType: Int? = nil
    public let unknownFields: [String]
    public var businessInfo: MusicSongBusinessInfo? = nil
    static let unknown = MusicReadSongMetadata(artists: nil, album: nil, recordingVersion: nil, durationMS: nil,
        unknownFields: ["artists", "album", "recording_version", "duration_ms"])
    enum CodingKeys: String, CodingKey {
        case artists, album, recordingVersion = "recording_version", durationMS = "duration_ms", unknownFields = "unknown_fields", originCoverType = "origin_cover_type",businessInfo="business_info"
    }
}
public struct MusicReadPagination: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable {
        case stableObserved = "stable_observed", consistencyUnknown = "consistency_unknown"
        case budgetExhausted = "budget_exhausted", drift, unprovenEnd = "unproven_end"
        case continuationEnd = "continuation_end"
    }
    public let state: State
    public let pages: Int
    public let items: Int
    public let total: Int?
    public let offset: Int
    public let nextOffset: Int?
    public var terminalObservations: [MusicProviderRecord]? = nil
    enum CodingKeys: String, CodingKey { case state, pages, items, total, offset, nextOffset = "next_offset", terminalObservations = "terminal_observations" }
    init(state: State, pages: Int, items: Int, total: Int?, offset: Int = 0, nextOffset: Int? = nil, terminalObservations: [MusicProviderRecord]? = nil) {
        self.state = state; self.pages = pages; self.items = items; self.total = total
        self.offset = offset; self.nextOffset = nextOffset; self.terminalObservations = terminalObservations
    }
}
public struct MusicReadPlaylist: Codable, Sendable, Equatable {
    public let playlistID: String
    public let name: String
    public let url: URL?
    public let trackCount: Int?
    public let providerRecord: MusicProviderRecord?
    public init(playlistID: String, name: String, url: URL?, trackCount: Int?, providerRecord: MusicProviderRecord? = nil) {
        self.playlistID = playlistID; self.name = name; self.url = url; self.trackCount = trackCount; self.providerRecord = providerRecord
    }
    enum CodingKeys: String, CodingKey { case playlistID = "playlist_id", name, url, trackCount = "track_count", providerRecord = "provider_record" }
}
public struct MusicSearchPage: Codable, Sendable, Equatable {
    public let offset: Int
    public let limit: Int
    public let total: Int?
    public let continuationSupported: Bool
    public let nextOffset: Int?
    public var coverage:String? = nil
    enum CodingKeys: String, CodingKey { case offset, limit, total, continuationSupported = "continuation_supported", nextOffset = "next_offset",coverage }
}
public struct MusicCloudPage: Codable, Sendable, Equatable {
    public let limit: Int
    public let total: Int?
    public let hasMore: Bool?
    public let nextCursor: String?
    enum CodingKeys: String, CodingKey { case limit, total, hasMore = "has_more", nextCursor = "next_cursor" }
}
public struct MusicReadPayload: Codable, Sendable, Equatable {
    public let songs: [MusicReadSong]?
    public var library: MusicLibraryReadPayload? = nil
    public let playlists: [MusicReadPlaylist]?
    public let playlist: MusicReadPlaylist?
    /// Two identical bounded list sweeps reached explicit ends. This is
    /// observed coverage, not a snapshot or a guarantee against concurrent edits.
    public let complete: Bool
    public let pagination: MusicReadPagination?
    public let searchPage: MusicSearchPage?
    public let cloudPage: MusicCloudPage?
    enum CodingKeys: String, CodingKey { case songs, library, playlists, playlist, complete, pagination, searchPage = "search_page", cloudPage = "cloud_page" }
    init(songs: [MusicReadSong]?, playlists: [MusicReadPlaylist]?, playlist: MusicReadPlaylist?, complete: Bool,
         pagination: MusicReadPagination? = nil, searchPage: MusicSearchPage? = nil, cloudPage: MusicCloudPage? = nil) {
        self.cloudPage = cloudPage
        self.songs = songs; self.playlists = playlists; self.playlist = playlist
        self.complete = complete; self.pagination = pagination; self.searchPage = searchPage
    }
}
/// Only fixed categories and the runtime's own correlation ID cross the owner boundary.
/// A retryable read is a manual read retry; this never authorizes a write replay.
public struct MusicReadFailure: Codable, Sendable, Equatable {
    public enum Reason: String, Codable, Sendable {
        case runtimeOutputMissing = "runtime_output_missing", providerRejected = "provider_rejected", providerResourceMissing="provider_resource_missing"
        case providerUnavailable = "provider_unavailable", loginRequired = "login_required", refreshRejected = "refresh_rejected"
        case manifestContractRejected = "manifest_contract_rejected", cliOutputMissing = "cli_output_missing"
        case cliOutputTooLarge = "cli_output_too_large", cliOutputInvalid = "cli_output_invalid"
        case resultSchemaInvalid = "result_schema_invalid", providerResponseInvalid = "provider_response_invalid"
        case sessionStateInvalid = "session_state_invalid", responseTooLarge = "response_too_large"
    }
    public enum Stage: String, Codable, Sendable {
        case runtime, providerResponse = "provider_response", session, manifest, cliOutput = "cli_output", projection
    }
    public enum NextStep: String, Codable, Sendable {
        case refineSearchKeywords = "refine_search_keywords", retryReadManually = "retry_read_manually"
        case checkLoginInARL = "check_login_in_arl", inspectProviderResponse = "inspect_provider_response", inspectAdapter = "inspect_adapter"
    }
    public let reason: Reason
    public let stage: Stage
    public let retryable: Bool
    public let automaticRetry: Bool
    public let correlationID: UUID
    public let httpStatus: Int?
    public let localCode: Int?
    public let nextStep: NextStep
    public let outputBytes: Int?
    public let outputLimitBytes: Int?
    public var providerStatus: MusicProviderBusinessStatus? = nil
    public var providerResult: MusicProviderRecord? = nil
    enum CodingKeys: String, CodingKey {
        case reason, stage, retryable, automaticRetry = "automatic_retry", correlationID = "correlation_id"
        case httpStatus = "http_status", localCode = "local_code", nextStep = "next_step", outputBytes = "output_bytes", outputLimitBytes = "output_limit_bytes",providerStatus="provider_status",providerResult="provider_result"
    }
}
public struct MusicReadResult: Codable, Sendable, Equatable {
    public let state: MusicReadState
    public let session: MusicReadSession
    public let payload: MusicReadPayload?
    public let failure: MusicReadFailure?
    public var providerResult: MusicProviderRecord? = nil
    enum CodingKeys: String, CodingKey { case state, session, payload, failure, providerResult = "provider_result" }
    init(state: MusicReadState, session: MusicReadSession, payload: MusicReadPayload?, failure: MusicReadFailure? = nil, providerResult: MusicProviderRecord? = nil) {
        self.providerResult=providerResult
        self.state=state;self.session=session;self.payload=payload;self.failure=failure
    }

    // Read evidence is returned to the requester. No generic .verified claim
    // is recorded against a credential without a dedicated evidence contract.
    var connectionState: ConnectionState {
        switch state {
        case .authorizedRead: .sessionPresentUnverified
        case .loginRequired, .refreshRejected: .loginRequired
        case .providerRejected: failure?.reason == .providerResourceMissing ? .sessionPresentUnverified : .credentialUnconfirmed
        case .contractRejected: .protocolFailure
        case .providerUnavailable: .networkUnavailable
        }
    }
}
struct MusicReadRuntimeResult: Sendable {
    let result: MusicReadResult
    let credential: CredentialInput
}
protocol MusicReadTransport: Sendable {
    func sendRead(_ owned: CredentialInput, request: MusicReadRequest) async throws -> MusicReadRuntimeResult
}

/// Independent native validation of the secret-free bridge projection.
/// Raw provider text and unknown fields never become public DTO properties.
enum MusicReadProtocol {
    static func validID(_ value: String) -> Bool {
        value.utf8.count == 32 && value.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }
    }
    static func validCursor(_ value: String) -> Bool {
        validText(value, limit: 1024) && !value.hasPrefix("-")
    }
    static func validText(_ value: String, limit: Int) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.utf8.count <= limit &&
        !value.unicodeScalars.contains { $0.value < 32 || $0.value == 127 }
    }
    private static func require(_ condition: Bool) throws {
        if !condition { throw CredentialError.uncertainLocalState }
    }
    private static func bool(_ value: Any?) -> Bool? {
        guard let value = value as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return value.boolValue
    }
    private static func integer(_ value: Any?) -> Int? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
              value.doubleValue >= 0, value.doubleValue <= 9_007_199_254_740_991, value.doubleValue.rounded() == value.doubleValue else { return nil }
        return value.intValue
    }
    private static func url(_ value: Any?, kind: String) throws -> URL? {
        guard let value else { return nil }
        guard let raw = value as? String, raw.utf8.count <= 100,
              raw.hasPrefix("https://music.163.com/#/\(kind)?id=") else { throw CredentialError.uncertainLocalState }
        let suffix = raw.dropFirst("https://music.163.com/#/\(kind)?id=".count)
        try require((1...20).contains(suffix.count) && suffix.first != "0" && suffix.utf8.allSatisfy { (48...57).contains($0) })
        guard let url = URL(string: raw) else { throw CredentialError.uncertainLocalState }
        return url
    }
    private static func business(_ value:Any,origin:Int?)throws -> MusicSongBusinessInfo {
        let bools:Set<String>=["playFlag","privateCloudSong","downloadFlag","payPlayFlag","payDownloadFlag","vipFlag","vipPlayFlag","freeTrailFlag","freeTrialFlag","vocalFlag","songFtFlag","accompanyFlag","freeTrialPrivilege.resConsumable","freeTrialPrivilege.userConsumable"]
        let ints:Set<String>=["songFee","songMaxBr","userMaxBr","playMaxbr","freeTrialPrivilege.cannotListenReason"]
        let levels:Set<String>=["maxBrLevel","plLevel","dlLevel"]
        func safeInteger(_ v:Any?) -> Bool {guard let n=v as? NSNumber,CFGetTypeID(n) != CFBooleanGetTypeID() else{return false};return n.doubleValue>=0 && n.doubleValue<=9_007_199_254_740_991 && n.doubleValue.rounded()==n.doubleValue}
        func entity(_ v:Any,limit:Int)throws {
            guard let e=v as? [String:Any],Set(e.keys)==["id","id_source_type","name"] else{throw CredentialError.uncertainLocalState}
            if e["id"] is NSNull {try require(e["id_source_type"] is NSNull)}
            else {
                guard let id=e["id"] as? String,let kind=e["id_source_type"] as? String else{throw CredentialError.uncertainLocalState}
                let decimal=id.range(of:"^[1-9][0-9]{0,19}$",options:.regularExpression) != nil
                try require(kind=="string" ? validID(id)||decimal : kind=="integer" && decimal && Int64(id).map{$0<=9_007_199_254_740_991}==true)
            }
            try require(e["name"] is NSNull || (e["name"] as? String).map{validText($0,limit:limit)}==true)
        }
        guard let r=value as? [String:Any],Set(r.keys)==["schema_version","source_operation","artists","artists_source_field","album","album_source_field","duration_raw","duration_unit","duration_source_field","origin_cover_category","recording_edition","legacy_recording_version_semantics","availability_semantics","provider_flags","unknown_reasons"],integer(r["schema_version"])==1,
              ["search","tracks","cloud_songs"].contains(r["source_operation"] as? String ?? ""),r["duration_unit"] is NSNull,r["recording_edition"] is NSNull,r["duration_source_field"] as? String=="duration",r["legacy_recording_version_semantics"] as? String=="origin_cover_classification",r["availability_semantics"] as? String=="provider_flags_only",
              let flags=r["provider_flags"] as? [String:Any],let unknown=r["unknown_reasons"] as? [String:String]
        else{throw CredentialError.uncertainLocalState}
        try require(r["origin_cover_category"] as? String == (origin==1 ? "original_performer":origin==2 ? "cover":"unknown"))
        try require(r["duration_raw"] is NSNull || safeInteger(r["duration_raw"]))
        try require(r["artists_source_field"] is NSNull || ["fullArtists","ar","artists"].contains(r["artists_source_field"] as? String ?? ""))
        try require(r["album_source_field"] is NSNull || ["al","album"].contains(r["album_source_field"] as? String ?? ""))
        if !(r["artists"] is NSNull){guard let list=r["artists"] as? [Any],(1...20).contains(list.count) else{throw CredentialError.uncertainLocalState};for row in list{try entity(row,limit:200)}}
        if !(r["album"] is NSNull){try entity(r["album"]!,limit:400)}
        for (key,v) in flags {
            if bools.contains(key){try require(bool(v) != nil)}
            else if ints.contains(key){try require(safeInteger(v))}
            else {try require(levels.contains(key) && (v as? String)?.range(of:"^[a-z][a-z0-9_]{0,31}$",options:.regularExpression) != nil)}
        }
        let reasons:Set<String>=["not_in_response","upstream_null","empty_value","invalid_shape","local_limit","not_requested","unit_unconfirmed","not_mapped"]
        let fields:Set<String>=["artists","album","album.id","album.name","duration_raw","duration_unit","origin_cover_type","recording_edition","qualities","songTag","emotionTag"]
        try require(unknown.count<=80 && unknown["duration_unit"]=="unit_unconfirmed" && unknown["recording_edition"]=="not_requested")
        for (key,reason) in unknown {
            let artist=key.range(of:"^artists\\[(?:[0-9]|1[0-9])\\]\\.(?:id|name)$",options:.regularExpression) != nil
            let provider=key.hasPrefix("provider_flags.") && bools.union(ints).union(levels).contains(String(key.dropFirst(15)))
            try require((fields.contains(key)||artist||provider) && reasons.contains(reason))
        }
        return try JSONDecoder().decode(MusicSongBusinessInfo.self,from:JSONSerialization.data(withJSONObject:r))
    }
    private static func providerStatus(_ value:Any,resourceMissing:Bool)throws -> MusicProviderBusinessStatus {
        guard let r=value as? [String:Any],Set(r.keys)==["code","sub_code","classification"],let classification=r["classification"] as? String,["provider_rejection","resource_missing"].contains(classification) else{throw CredentialError.uncertainLocalState}
        func scalar(_ v:Any?)throws -> String? {
            if v is NSNull{return nil}
            if let s=v as? String {try require(s.range(of:"^[0-9]{1,10}$",options:.regularExpression) != nil);return s}
            guard let n=v as? NSNumber,CFGetTypeID(n) != CFBooleanGetTypeID(),n.doubleValue>=0,n.doubleValue<=2147483647,n.doubleValue.rounded()==n.doubleValue else{throw CredentialError.uncertainLocalState};return n.stringValue
        }
        let code=try scalar(r["code"]),sub=try scalar(r["sub_code"])
        try require(resourceMissing == (classification=="resource_missing"))
        if resourceMissing{try require(code=="200" && sub=="10007")}
        return try JSONDecoder().decode(MusicProviderBusinessStatus.self,from:JSONSerialization.data(withJSONObject:r))
    }
    static func providerRecord(_ value: Any) throws -> MusicProviderRecord {
        guard let record = value as? [String: Any], Set(record.keys) == ["fields", "omitted_authentication_fields"],
              let fields = record["fields"] as? [String: Any], let omitted = record["omitted_authentication_fields"] as? [String],
              omitted == Array(Set(omitted)).sorted(), omitted.allSatisfy({ ProviderBusinessPolicy.authenticationKeys.union(["authenticated_url","authentication_context","session","sessionid","deviceid","appid","headers","signature","credential","credentials"]).contains($0) }) else { throw CredentialError.uncertainLocalState }
        try ProviderBusinessPolicy.validate(fields)
        return try JSONDecoder().decode(MusicProviderRecord.self, from: JSONSerialization.data(withJSONObject: record))
    }
    private static func verificationSong(_ raw: [String: Any]) throws -> MusicReadSong {
        if raw["metadata"] != nil { return try song(raw) }
        guard Set(raw.keys).isSubset(of: ["song_id","name","url","provider_record"]),
              let id = raw["song_id"] as? String, validID(id), id == id.lowercased(),
              let name = raw["name"] as? String, validText(name, limit: 800)
        else { throw CredentialError.uncertainLocalState }
        return .init(songID:id,name:name,url:try url(raw["url"],kind:"song"),visible:nil,
                     metadata:.init(artists:nil,album:nil,recordingVersion:nil,durationMS:nil,
                                    originCoverType:nil,unknownFields:["artists","album","recording_version","duration_ms"]),
                     privateCloudSong:nil,playFlag:nil,providerRecord:try raw["provider_record"].map {try providerRecord($0)})
    }
    private static func song(_ raw: [String: Any]) throws -> MusicReadSong {
        try require(Set(raw.keys).isSubset(of: ["song_id","name","url","visible","metadata","private_cloud_song","play_flag","provider_record"]))
        guard let id = raw["song_id"] as? String, validID(id), id == id.lowercased(),
              let name = raw["name"] as? String, validText(name, limit: 800) else { throw CredentialError.uncertainLocalState }
        for key in ["visible","private_cloud_song","play_flag"] where raw[key] != nil { try require(bool(raw[key]) != nil) }
        guard let metadata = raw["metadata"] as? [String: Any],
              Set(metadata.keys).subtracting(["origin_cover_type","business_info"]) == ["artists","album","recording_version","duration_ms","unknown_fields"],
              metadata["duration_ms"] is NSNull,
              let unknown = metadata["unknown_fields"] as? [String] else { throw CredentialError.uncertainLocalState }
        var artists: [String]?, album: String?, expected: [String] = []
        if metadata["artists"] is NSNull { expected.append("artists") }
        else {
            guard let names = metadata["artists"] as? [String], (1...20).contains(names.count),
                  names.allSatisfy({ validText($0, limit: 200) }) else { throw CredentialError.uncertainLocalState }
            artists = names
        }
        if metadata["album"] is NSNull { expected.append("album") }
        else {
            guard let name = metadata["album"] as? String, validText(name, limit: 400) else { throw CredentialError.uncertainLocalState }
            album = name
        }
        let origin = integer(metadata["origin_cover_type"])
        if let raw = metadata["origin_cover_type"], !(raw is NSNull) { try require(origin.map { (0...2).contains($0) } == true) }
        let version: String? = origin == 1 ? "original_performer" : origin == 2 ? "cover" : nil
        if let version { try require(metadata["recording_version"] as? String == version) }
        else { try require(metadata["recording_version"] is NSNull); expected.append("recording_version") }
        expected.append("duration_ms")
        try require(unknown == expected)
        return .init(songID: id, name: name, url: try url(raw["url"], kind: "song"), visible: bool(raw["visible"]),
                     metadata: .init(artists: artists, album: album, recordingVersion: version, durationMS: nil, originCoverType: origin, unknownFields: unknown, businessInfo: try metadata["business_info"].map {try business($0,origin:origin)}),
                     privateCloudSong: bool(raw["private_cloud_song"]), playFlag: bool(raw["play_flag"]),
                     providerRecord: try raw["provider_record"].map(providerRecord))
    }
    private static func pagination(_ value: Any?, count: Int, complete: Bool, offset: Int) throws -> MusicReadPagination {
        guard let raw = value as? [String: Any],
              Set(raw.keys).subtracting(["terminal_observations"]) == ["state","pages","items","total"] || Set(raw.keys).subtracting(["terminal_observations"]) == ["state","pages","items","total","offset","next_offset"],
              let state = MusicReadPagination.State(rawValue: raw["state"] as? String ?? ""),
              let pages = integer(raw["pages"]), pages >= 0,
              integer(raw["items"]) == count,
              raw["total"] is NSNull || integer(raw["total"]).map({ $0 >= offset + count }) == true
        else { throw CredentialError.uncertainLocalState }
        if raw["offset"] == nil { try require(offset == 0) }
        else { try require(integer(raw["offset"]) == offset) }
        let next = integer(raw["next_offset"])
        if let value = raw["next_offset"], !(value is NSNull) {
            try require(next == offset + count && count > 0 && next! <= 99999 && state == .budgetExhausted && !complete)
            try require(raw["total"] is NSNull || integer(raw["total"])! > next!)
        }
        try require(complete == (state == .stableObserved))
        if complete { try require(offset == 0 && next == nil && pages >= 2 && pages % 2 == 0 && (raw["total"] is NSNull || integer(raw["total"]) == count)) }
        if state == .continuationEnd { try require(offset > 0 && next == nil && (raw["total"] is NSNull || integer(raw["total"]) == offset + count)) }
        var observations: [MusicProviderRecord]?
        if let value = raw["terminal_observations"] {
            guard let rows = value as? [[String: Any]], !rows.isEmpty, rows.count <= pages else { throw CredentialError.uncertainLocalState }
            observations = try rows.map { row in
                let result = try providerRecord(row)
                guard let f = row["fields"] as? [String: Any], integer(f["http_status"]) == 200, integer(f["code"]) == 200,
                      f["sub_code"] as? String == "10007" || integer(f["sub_code"]) == 10007,
                      f["path"] as? String == "/openapi/music/basic/playlist/song/list/get/v3", f["method"] as? String == "GET",
                      let endOffset = integer(f["offset"]), (0...99999).contains(endOffset),
                      ["terminal_empty","empty_page_count_conflict"].contains(f["classification"] as? String ?? "")
                else { throw CredentialError.uncertainLocalState }
                try require(endOffset <= offset + count)
                if complete { try require(f["classification"] as? String == "terminal_empty" && endOffset == count) }
                if state == .continuationEnd { try require(f["classification"] as? String == "terminal_empty" && endOffset == offset + count) }
                if f["classification"] as? String == "empty_page_count_conflict" { try require(state == .drift && endOffset == 0 && !complete) }
                return result
            }
        }
        return .init(state: state, pages: pages, items: count, total: integer(raw["total"]), offset: offset, nextOffset: next, terminalObservations: observations)
    }
    private static func playlist(_ raw: [String: Any]) throws -> MusicReadPlaylist {
        try require(Set(raw.keys).isSubset(of: ["playlist_id","name","url","track_count","provider_record"]))
        guard let id = raw["playlist_id"] as? String, validID(id), id == id.lowercased(),
              let name = raw["name"] as? String, validText(name, limit: 400) else { throw CredentialError.uncertainLocalState }
        if raw["track_count"] != nil { try require(integer(raw["track_count"]) != nil) }
        return .init(playlistID: id, name: name, url: try url(raw["url"], kind: "playlist"), trackCount: integer(raw["track_count"]), providerRecord: try raw["provider_record"].map { try providerRecord($0) })
    }
    private static func failure(_ value: Any, state: MusicReadState, correlationID: UUID?, request: MusicReadRequest) throws -> MusicReadFailure {
        guard let raw=value as? [String: Any],
              Set(raw.keys).subtracting(["provider_status","provider_result"])==["reason","stage","retryable","automatic_retry","correlation_id","http_status","local_code","next_step","output_bytes","output_limit_bytes"],
              let reason=MusicReadFailure.Reason(rawValue:raw["reason"] as? String ?? ""),
              let stage=MusicReadFailure.Stage(rawValue:raw["stage"] as? String ?? ""),
              let nextStep=MusicReadFailure.NextStep(rawValue:raw["next_step"] as? String ?? ""),
              let text=raw["correlation_id"] as? String,text.utf8.count==36,let id=UUID(uuidString:text),id==correlationID,
              let retryable=bool(raw["retryable"]),retryable==(state == .providerUnavailable),bool(raw["automatic_retry"])==false
        else {throw CredentialError.uncertainLocalState}
        let expectedStage:MusicReadFailure.Stage
        switch reason {
        case .runtimeOutputMissing,.responseTooLarge:expectedStage = .runtime
        case .providerRejected,.providerResourceMissing,.providerUnavailable,.providerResponseInvalid:expectedStage = .providerResponse
        case .loginRequired,.refreshRejected,.sessionStateInvalid:expectedStage = .session
        case .manifestContractRejected:expectedStage = .manifest
        case .cliOutputMissing,.cliOutputTooLarge,.cliOutputInvalid:expectedStage = .cliOutput
        case .resultSchemaInvalid:expectedStage = .projection
        }
        try require(stage==expectedStage)
        let expectedState:MusicReadState
        switch reason {
        case .providerRejected,.providerResourceMissing:expectedState = .providerRejected
        case .providerUnavailable:expectedState = .providerUnavailable
        case .loginRequired:expectedState = .loginRequired
        case .refreshRejected:expectedState = .refreshRejected
        default:expectedState = .contractRejected
        }
        try require(state==expectedState)
        let http=integer(raw["http_status"])
        try require(raw["http_status"] is NSNull || http.map{(100...599).contains($0)}==true)
        var code:Int?
        if !(raw["local_code"] is NSNull) {
            guard let n=raw["local_code"] as? NSNumber,CFGetTypeID(n) != CFBooleanGetTypeID(),
                  n.doubleValue.rounded()==n.doubleValue,(-97062 ... -97001).contains(n.doubleValue) else {throw CredentialError.uncertainLocalState}
            code=n.intValue
        }
        if reason == .cliOutputTooLarge {try require(code == -97062)}
        if reason == .cliOutputMissing {try require(code == -97027)}
        let expectedNext:MusicReadFailure.NextStep = state == .providerUnavailable ? .retryReadManually : [.loginRequired,.refreshRejected].contains(state) ? .checkLoginInARL :
            state == .providerRejected ? .inspectProviderResponse : .inspectAdapter
        try require(nextStep==expectedNext)
        var outputBytes:Int?,outputLimit:Int?
        if reason == .cliOutputTooLarge {
            guard let bytes=raw["output_bytes"] as? NSNumber,CFGetTypeID(bytes) != CFBooleanGetTypeID(),
                  bytes.doubleValue.rounded()==bytes.doubleValue,(1048577...1_000_000_000).contains(bytes.doubleValue),
                  let limit=raw["output_limit_bytes"] as? NSNumber,CFGetTypeID(limit) != CFBooleanGetTypeID(),
                  [1048576,1048576+(1048576+1)*(1+2*16)].contains(limit.doubleValue),bytes.doubleValue>limit.doubleValue
            else {throw CredentialError.uncertainLocalState}
            outputBytes=bytes.intValue;outputLimit=limit.intValue
        } else if reason == .responseTooLarge {
            guard case .library = request,
                  let bytes=raw["output_bytes"] as? NSNumber,CFGetTypeID(bytes) != CFBooleanGetTypeID(),
                  bytes.doubleValue.rounded()==bytes.doubleValue,(262145...1_000_000_000).contains(bytes.doubleValue),
                  let limit=raw["output_limit_bytes"] as? NSNumber,CFGetTypeID(limit) != CFBooleanGetTypeID(),limit.intValue==262144
            else {throw CredentialError.uncertainLocalState}
            outputBytes=bytes.intValue;outputLimit=limit.intValue
        } else {try require(raw["output_bytes"] is NSNull && raw["output_limit_bytes"] is NSNull)}
        if reason == .providerResourceMissing {try require(raw["provider_status"] != nil)}
        return .init(reason:reason,stage:stage,retryable:retryable,automaticRetry:false,correlationID:id,httpStatus:http,localCode:code,
                     nextStep:nextStep,outputBytes:outputBytes,outputLimitBytes:outputLimit,providerStatus: try raw["provider_status"].map{try providerStatus($0,resourceMissing:reason == .providerResourceMissing)},
                     providerResult: try raw["provider_result"].map { try providerRecord($0) })
    }
    static func decode(_ raw: [String: Any], for request: MusicReadRequest, correlationID: UUID? = nil, verification: Bool = false) throws -> MusicReadResult {
        try request.validate()
        let fieldSet = Set(raw.keys).subtracting(["provider_result"])
        try require(fieldSet == ["state","session","payload"] || fieldSet == ["state","session","payload","failure"])
        let provider = try raw["provider_result"].map { try providerRecord($0) }
        guard let rawState = raw["state"] as? String, let state = MusicReadState(rawValue: rawState),
              let rawSession = raw["session"] as? String, let session = MusicReadSession(rawValue: rawSession)
        else { throw CredentialError.uncertainLocalState }
        if state != .authorizedRead {
            try require(raw["payload"] is NSNull)
            if state == .loginRequired { try require(session == .missing) }
            if state == .refreshRejected { try require(session == .rejected) }
            let detail = try raw["failure"].map {try failure($0,state:state,correlationID:correlationID,request:request)}
            return .init(state: state, session: session, payload: nil, failure: detail, providerResult: provider)
        }
        try require(raw["failure"] == nil)
        try require(session == .present || session == .refreshed)
        guard let payload = raw["payload"] as? [String: Any], let complete = bool(payload["complete"])
        else { throw CredentialError.uncertainLocalState }
        let result: MusicReadPayload
        switch request {
        case .library(let query):
            try require(Set(payload.keys) == ["library","complete"] && !complete)
            guard let raw = payload["library"] as? [String: Any],
                  Set(raw.keys) == ["operation","parameters","provider_record","coverage"],
                  raw["operation"] as? String == query.operation.rawValue,
                  raw["coverage"] as? String == "single_provider_response",
                  let parameters = raw["parameters"] as? [String: Any],
                  Set(parameters.keys) == Set(query.parameters.keys)
            else { throw CredentialError.uncertainLocalState }
            for (key, value) in parameters {
                let expected = query.parameters[key]!
                if let text = value as? String { try require(text == expected) }
                else if let number = value as? NSNumber {
                    if CFGetTypeID(number) == CFBooleanGetTypeID() { try require((number.boolValue ? "true" : "false") == expected) }
                    else { try require(number.stringValue == expected) }
                } else { throw CredentialError.uncertainLocalState }
            }
            let record = try providerRecord(raw["provider_record"] as Any)
            try require(record.fields["code"] == .integer(0) || record.fields["code"] == .integer(200))
            try require(record.fields["success"] != .boolean(false))
            if let sub = record.fields["subCode"], sub != .null {
                try require([MusicProviderValue.integer(0), .integer(200), .text("0"), .text("200")].contains(sub))
            }
            var value = MusicReadPayload(songs:nil, playlists:nil, playlist:nil, complete:false)
            var library = try JSONDecoder().decode(MusicLibraryReadPayload.self, from:JSONSerialization.data(withJSONObject:raw))
            if (query.operation == .albumCollected || query.operation == .playlistCollected), case .object(let data) = record.fields["data"],
               case .array(let records) = data["records"] {
                library.returnedRecords = records.count
            }
            value.library = library
            result = value
        case .search(_, let offset):
            try require(Set(payload.keys) == ["songs","complete","search_page"])
            guard let rows = payload["songs"] as? [[String: Any]], rows.count <= 20 else { throw CredentialError.uncertainLocalState }
            let songs = try rows.map(song)
            try require(Set(songs.map(\.songID)).count == songs.count)
            guard let page = payload["search_page"] as? [String: Any],
                  Set(page.keys).subtracting(["coverage"]) == ["offset","limit","total","continuation_supported","next_offset"],
                  integer(page["offset"]) == offset, integer(page["limit"]) == 20,
                  let supported = bool(page["continuation_supported"]),
                  page["total"] is NSNull || integer(page["total"]).map({ $0 >= offset + songs.count }) == true,
                  page["next_offset"] is NSNull || integer(page["next_offset"]).map({ supported && !songs.isEmpty && $0 == offset + songs.count }) == true
            else { throw CredentialError.uncertainLocalState }
            let total = integer(page["total"]), next = integer(page["next_offset"])
            let coverage=page["coverage"] as? String
            if page["coverage"] != nil {try require(!complete && ["budget_exhausted","local_limit"].contains(coverage ?? "") && (coverage=="budget_exhausted" ? next != nil : next == nil))}
            try require(offset == 0 || supported)
            if complete { try require(offset == 0 && next == nil && (total == nil || total == songs.count)) }
            if let next, let total { try require(next < total) }
            result = .init(songs: songs, playlists: nil, playlist: nil, complete: complete,
                searchPage: .init(offset: offset, limit: 20, total: total, continuationSupported: supported, nextOffset: next,coverage:coverage))
        case .cloudSongs(let cursor, let requestedLimit):
            try require(Set(payload.keys) == ["songs","complete","cloud_page"])
            guard let rows = payload["songs"] as? [[String: Any]], rows.count <= 50,
                  let page = payload["cloud_page"] as? [String: Any],
                  Set(page.keys) == ["limit","total","has_more","next_cursor"],
                  let limit = integer(page["limit"]), (1...requestedLimit).contains(limit), rows.count <= limit
            else { throw CredentialError.uncertainLocalState }
            let songs = try rows.map(song)
            try require(Set(songs.map(\.songID)).count == songs.count)
            try require(page["total"] is NSNull || integer(page["total"]).map({ $0 >= songs.count }) == true)
            try require(page["has_more"] is NSNull || bool(page["has_more"]) != nil)
            let next = page["next_cursor"] as? String, more = bool(page["has_more"])
            try require(page["next_cursor"] is NSNull || next.map({ validCursor($0) && $0 != cursor }) == true)
            try require(complete == (more == false))
            if more == true { try require(next != nil && !songs.isEmpty) }
            if more == false { try require(next == nil) }
            result = .init(songs: songs, playlists: nil, playlist: nil, complete: complete,
                cloudPage: .init(limit: limit, total: integer(page["total"]), hasMore: more, nextCursor: next))
        case .userPlaylists, .userPlaylistsPage:
            try require(Set(payload.keys) == ["playlists","complete","pagination"])
            guard let rows = payload["playlists"] as? [[String: Any]] else { throw CredentialError.uncertainLocalState }
            let playlists = try rows.map(playlist)
            try require(Set(playlists.map(\.playlistID)).count == playlists.count)
            result = .init(songs: nil, playlists: playlists, playlist: nil, complete: complete,
                           pagination: try pagination(payload["pagination"], count: playlists.count, complete: complete, offset: request.paginationOffset))
        case .playlistDetail(let id), .playlistDetailPage(let id, _):
            try require(Set(payload.keys) == ["playlist","songs","complete","pagination"])
            guard let row = payload["playlist"] as? [String: Any], let rows = payload["songs"] as? [[String: Any]]
            else { throw CredentialError.uncertainLocalState }
            let item = try playlist(row), songs = try rows.map { try verification ? verificationSong($0) : song($0) }
            try require(item.playlistID == id.lowercased() && Set(songs.map(\.songID)).count == songs.count)
            try require(!complete || item.trackCount == songs.count)
            result = .init(songs: songs, playlists: nil, playlist: item, complete: complete,
                           pagination: try pagination(payload["pagination"], count: songs.count, complete: complete, offset: request.paginationOffset))
        }
        return .init(state: state, session: session, payload: result, providerResult: provider)
    }
}

/// Ten finite public catalog reads. HTTP method does not determine effect semantics.
public enum MusicLibraryReadOperation: String, Codable, Sendable, CaseIterable {
    case searchAll = "search_all", searchAlbum = "search_album", searchPlaylist = "search_playlist"
    case albumGet = "album_get", albumTracks = "album_tracks", albumCollected = "album_collected"
    case artistSongs = "artist_songs", songLyric = "song_lyric"
    case playlistCollected = "playlist_collected", playlistGetTags = "playlist_get_tags"
    public var toolName: String { "mio_netease_" + rawValue }
}
public struct MusicLibraryReadRequest: Sendable, Equatable {
    public let operation: MusicLibraryReadOperation
    let parameters: [String:String]
    public init(toolName:String, argumentsJSON:Data) throws {
        guard let operation=MusicLibraryReadOperation.allCases.first(where:{$0.toolName==toolName}) else {throw CredentialError.invalidInput}
        let raw=try MusicStrictJSON.object(argumentsJSON,limit:16384)
        let fields=Self.fields(operation)
        guard fields.0.isSubset(of:Set(raw.keys)),Set(raw.keys).isSubset(of:fields.0.union(fields.1)) else {throw CredentialError.invalidInput}
        let mapping=["album_id":"albumId","artist_id":"artistId","song_id":"songId","desc_flag":"descFlag","quality_flag":"qualityFlag","start_time":"startTime","end_time":"endTime"]
        var parameters:[String:String]=[:]
        for (key,value) in raw {
            let target=mapping[key] ?? key
            if ["desc_flag","quality_flag"].contains(key) {
                guard let n=value as? NSNumber,CFGetTypeID(n)==CFBooleanGetTypeID() else {throw CredentialError.invalidInput}
                parameters[target]=n.boolValue ? "true":"false"
            } else if ["limit","offset","start_time","end_time"].contains(key) {
                guard let n=value as? NSNumber,CFGetTypeID(n) != CFBooleanGetTypeID(),
                      n.doubleValue.isFinite,n.doubleValue>=0,n.doubleValue<=9_007_199_254_740_991,
                      n.doubleValue.rounded()==n.doubleValue,let v=Int64(n.stringValue)
                else {throw CredentialError.invalidInput}
                parameters[target]=String(v)
            } else {
                guard let text=value as? String else {throw CredentialError.invalidInput}
                parameters[target]=key.hasSuffix("_id") ? text.lowercased():text
            }
        }
        self.operation=operation;self.parameters=parameters;try validate()
    }
    static func fields(_ operation:MusicLibraryReadOperation)->(Set<String>,Set<String>) {
        switch operation {
        case .searchAll:(["keyword"],[])
        case .searchAlbum,.searchPlaylist:(["keyword"],["limit","offset"])
        case .albumGet:(["album_id"],["desc_flag"])
        case .albumTracks:(["album_id"],["quality_flag"])
        case .albumCollected:(["limit","offset"],[])
        case .artistSongs:(["artist_id","limit","offset","start_time","end_time"],[])
        case .songLyric:(["song_id"],[])
        case .playlistCollected:([],["limit","offset"])
        case .playlistGetTags:([],[])
        }
    }
    func validate() throws {
        for (key,value) in parameters {
            if ["albumId","artistId","songId"].contains(key) {
                guard MusicReadProtocol.validID(value) else {throw CredentialError.invalidInput}
            }
            if key=="keyword" {
                guard value.count<=100,MusicReadProtocol.validText(value,limit:400),!value.hasPrefix("-") else {throw CredentialError.invalidInput}
            }
            if key=="limit" {guard let n=Int(value),(1...(operation == .playlistCollected ? 500 : 100)).contains(n) else {throw CredentialError.invalidInput}}
            if key=="offset" {guard let n=Int64(value),n>=0,n <= (operation == .playlistCollected ? 9_007_199_254_740_991 : 99999) else {throw CredentialError.invalidInput}}
        }
        if let start=parameters["startTime"].flatMap(Int64.init),let end=parameters["endTime"].flatMap(Int64.init),start>end {throw CredentialError.invalidInput}
    }
}
public struct MusicLibraryReadPayload: Codable, Sendable, Equatable {
    public let operation: MusicLibraryReadOperation
    public let parameters:[String:MusicProviderValue]
    public let providerRecord:MusicProviderRecord
    public let coverage:String
    /// Count only this received page; never infer collection total from recordCount.
    public var returnedRecords:Int? = nil
    enum CodingKeys:String,CodingKey {case operation,parameters,coverage,providerRecord="provider_record",returnedRecords="returned_records"}
}
