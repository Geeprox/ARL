import Foundation
import CryptoKit

/// Fixed user-requested effects. IDs must come from the read tools; the caller
/// keeps requestID unchanged across timeouts, reconnects and retries.
public struct MusicWriteRequest: Codable, Equatable, Sendable {
    public enum Intent: String, Codable, Sendable { case createPlaylist = "create_playlist", appendSong = "append_song", updatePlaylistName = "update_playlist_name", updatePlaylistDescription = "update_playlist_description", updatePlaylistTags = "update_playlist_tags", addSongs = "add_songs", reorderSongs = "reorder_songs", removeSongs = "remove_songs" }
    public let requestID: UUID
    public let intent: Intent
    public let name: String
    public let playlistID: String?
    public let songID: String?
    public let value: String?
    public let songIDs: [String]?
    public let tags: [String]?
    /// This mode may inspect an existing request but can never reserve a new effect.
    public let reconcileOnly: Bool
    public init(requestID: UUID, intent: Intent, name: String, playlistID: String? = nil, songID: String? = nil, value: String? = nil, songIDs: [String]? = nil, tags: [String]? = nil, reconcileOnly: Bool = false) throws {
        self.requestID = requestID; self.intent = intent; self.name = name
        self.playlistID = playlistID?.lowercased(); self.songID = songID?.lowercased()
        self.reconcileOnly = reconcileOnly; self.value = value
        self.songIDs = songIDs?.map { $0.lowercased() }; self.tags = tags
        try validate()
    }
    enum CodingKeys: String, CodingKey { case requestID, intent, name, playlistID, songID, value, songIDs, tags, reconcileOnly }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(requestID: values.decode(UUID.self, forKey: .requestID), intent: values.decode(Intent.self, forKey: .intent),
                      name: values.decode(String.self, forKey: .name), playlistID: values.decodeIfPresent(String.self, forKey: .playlistID),
                      songID: values.decodeIfPresent(String.self, forKey: .songID), value: values.decodeIfPresent(String.self, forKey: .value), songIDs: values.decodeIfPresent([String].self, forKey: .songIDs), tags: values.decodeIfPresent([String].self, forKey: .tags), reconcileOnly: values.decodeIfPresent(Bool.self, forKey: .reconcileOnly) ?? false)
    }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        // Query mode is not part of the persisted effect identity. Targets and
        // intent remain exact, so changing either still conflicts with the UUID.
        lhs.requestID == rhs.requestID && lhs.intent == rhs.intent && lhs.name == rhs.name &&
        lhs.playlistID == rhs.playlistID && lhs.songID == rhs.songID && lhs.value == rhs.value && lhs.songIDs == rhs.songIDs && lhs.tags == rhs.tags
    }
    func validate() throws {
        guard name.count <= 100, MusicReadProtocol.validText(name, limit: 400),
              name == name.trimmingCharacters(in: .whitespacesAndNewlines), !name.hasPrefix("-")
        else { throw CredentialError.invalidInput }
        guard intent == .updatePlaylistTags || tags == nil, isSongListUpdate || songIDs == nil else { throw CredentialError.invalidInput }
        switch intent {
        case .updatePlaylistTags:
            guard let playlistID, MusicReadProtocol.validID(playlistID), songID == nil, value == nil, let tags,
                  (1...3).contains(tags.count), Set(tags).count == tags.count,
                  tags.allSatisfy({ !$0.isEmpty && !$0.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) }) else { throw CredentialError.invalidInput }
        case .addSongs, .reorderSongs, .removeSongs:
            guard let playlistID, MusicReadProtocol.validID(playlistID), songID == nil, value == nil, let songIDs, !songIDs.isEmpty,
                  songIDs.allSatisfy(MusicReadProtocol.validID), Set(songIDs).count == songIDs.count,
                  intent != .removeSongs || songIDs.count <= 500 else { throw CredentialError.invalidInput }
        case .createPlaylist:
            guard playlistID == nil, songID == nil, value == nil else { throw CredentialError.invalidInput }
        case .appendSong:
            guard value == nil, let playlistID, let songID, MusicReadProtocol.validID(playlistID), MusicReadProtocol.validID(songID)
            else { throw CredentialError.invalidInput }
        case .updatePlaylistName, .updatePlaylistDescription:
            guard let playlistID, MusicReadProtocol.validID(playlistID), songID == nil, let value,
                  Self.validMetadataValue(value, rename: intent == .updatePlaylistName) else { throw CredentialError.invalidInput }
        }
    }
    var isMetadataUpdate: Bool { intent == .updatePlaylistName || intent == .updatePlaylistDescription || intent == .updatePlaylistTags }
    var isSongListUpdate: Bool { [.addSongs, .reorderSongs, .removeSongs].contains(intent) }
    static func validMetadataValue(_ value: String, rename: Bool) -> Bool {
        if rename { return !value.isEmpty && value.unicodeScalars.count <= 100 && value.utf8.count <= 400 &&
            value == value.trimmingCharacters(in: .whitespacesAndNewlines) && !value.hasPrefix("-") &&
            !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) }
        return value.unicodeScalars.count <= 1000 && value.utf8.count <= 4000 &&
            !value.unicodeScalars.contains(where: { ($0.value < 32 && $0.value != 9 && $0.value != 10) || $0.value == 127 })
    }
    var operation: String {
        switch intent { case .createPlaylist: "playlist_create"; case .appendSong: "playlist_append"
        case .updatePlaylistName: "playlist_update_name"; case .updatePlaylistDescription: "playlist_update_desc"
        case .updatePlaylistTags: "playlist_update_tags"; case .addSongs: "playlist_add_songs"
        case .reorderSongs: "playlist_reorder"; case .removeSongs: "playlist_remove_songs" }
    }
    var arguments: [String: String] {
        if let songIDs { return ["playlist_id": playlistID!, "song_ids": String(data: try! JSONEncoder().encode(songIDs), encoding: .utf8)!] }
        if let tags { return ["playlist_id": playlistID!, "tags": String(data: try! JSONEncoder().encode(tags), encoding: .utf8)!] }
        if isMetadataUpdate { return ["playlist_id": playlistID!, "value": value!] }
        return intent == .createPlaylist ? ["name": name] : ["playlist_id": playlistID!, "song_id": songID!]
    }
    static func contentsDigest(_ songs: [MusicReadSong]) throws -> String {
        SHA256.hash(data: try JSONEncoder().encode(songs.map(\.songID))).map { String(format: "%02x", $0) }.joined()
    }
    static func playlistTags(_ playlist: MusicReadPlaylist?) -> [String]? {
        guard let field = playlist?.providerRecord?.fields["tags"] else { return nil }
        if case .null = field { return nil } // Provider detail null is unavailable, not an observed empty tag list.
        guard case .array(let items) = field else { return nil }
        let tags = items.compactMap { if case .text(let t) = $0 { return t }; return nil }
        return tags.count == items.count ? tags : nil
    }
    static func playlistDescription(_ playlist: MusicReadPlaylist?) -> String? {
        guard let fields = playlist?.providerRecord?.fields else { return nil }
        var values: [String] = []
        for key in ["describe", "description", "desc"] {
            guard let value = fields[key] else { continue }
            switch value { case .text(let text): values.append(text); case .null: values.append(""); default: return nil }
        }
        guard let first = values.first, values.allSatisfy({ $0 == first }) else { return nil }
        return first
    }
}
public struct MusicWriteResult: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        case verified, alreadyPresent = "already_present", outcomeUnknown = "outcome_unknown", notDispatched = "not_dispatched"
        case requiresSetup = "requires_setup", targetMismatch = "target_mismatch", incompleteRead = "incomplete_read"
        case requestConflict = "request_conflict", accountChanged = "account_changed", providerUnavailable = "provider_unavailable"
        case readbackFailed = "readback_failed", songAbsent = "song_absent"
    }
    public let state: State
    public let requestID: UUID
    public let playlistID: String?
    public let songID: String?
    public let readbackVerified: Bool
    public var providerResult: MusicProviderRecord? = nil
    public var readbackFailure: MusicReadFailure? = nil
    public var readbackProviderResult: MusicProviderRecord? = nil
    public var readbackState: String? = nil
    public var matchedSongID: String? = nil
    enum CodingKeys: String, CodingKey { case state, requestID = "request_id", playlistID = "playlist_id", songID = "song_id", readbackVerified = "readback_verified", providerResult = "provider_result", readbackFailure = "readback_failure", readbackProviderResult = "readback_provider_result", readbackState = "readback_state", matchedSongID = "matched_song_id" }
    init(_ state: State, request: MusicWriteRequest, playlistID: String? = nil, providerResult: MusicProviderRecord? = nil,
         readbackFailure: MusicReadFailure? = nil, readbackProviderResult: MusicProviderRecord? = nil, readbackState: String? = nil, matchedSongID: String? = nil) {
        self.matchedSongID = matchedSongID
        self.readbackProviderResult = readbackProviderResult
        self.providerResult = providerResult; self.readbackFailure = readbackFailure; self.readbackState = readbackState
        self.state = state; requestID = request.requestID
        self.playlistID = playlistID ?? request.playlistID; songID = request.songID
        readbackVerified = state == .verified || state == .alreadyPresent
    }
}
public struct MusicConnectionStatus: Codable, Sendable {
    public let state: String
    public let ready: Bool
    public let configuration: String
    public let login: String
    public let writes: String
    public let configurationUI = "ARL > 服务连接 > 网易云音乐"
    enum CodingKeys: String, CodingKey { case state, ready, configuration, login, writes, configurationUI = "configuration_ui" }
}
struct MusicWriteEffect: Sendable {
    enum State: String { case submitted, notSubmitted = "not_submitted", outcomeUnknown = "outcome_unknown" }
    let state: State
    let playlistID: String?
    let credential: CredentialInput
    var providerResult: MusicProviderRecord? = nil
}
protocol MusicWriteTransport: Sendable {
    func sendWrite(_ owned: CredentialInput, request: MusicWriteRequest) async throws -> MusicWriteEffect
}

struct MusicWriteRecord: Codable, Equatable, Sendable {
    let request: MusicWriteRequest
    let reference: UUID
    let epoch: UUID
    let baseline: [String]
    var baselineSongIDs: [String]? = nil
    var contentDigest: String? = nil // Legacy metadata writes observed exact ordered song IDs.
    var metadataFieldsOnly: Bool? = nil // Schema 3: attest only the requested metadata, without a membership claim.
    // Persisted before the effect. An interrupted pending record permits reads
    // only, including when the provider never actually received the effect.
    var effectDisposition: MusicEffectDisposition? = nil // Missing on historical records stays unknown.
    var returnedPlaylistID: String?
    var providerResult: MusicProviderRecord? = nil
    var result: MusicWriteResult?
    var cloudResource: MusicCloudOperationContext? = nil
}
struct MusicWriteLedger: Codable, Sendable {
    var schema = 1
    var epochs: [String: UUID] = [:]
    var records: [String: MusicWriteRecord] = [:]
}
public enum MusicEffectDisposition: String, Codable, Sendable {
    case notDispatched = "not_dispatched", submitted, outcomeUnknown = "outcome_unknown"
}
/// The query has no user-supplied target or write mode, and never creates an intent.
public struct MusicReconciliationResult: Encodable, Sendable {
    public let state: String
    public let requestID: UUID
    public let originalIntent: String?
    public let originalName: String?
    public let playlistID: String?
    public let songID: String?
    public let effectDisposition: MusicEffectDisposition?
    public let readbackVerified: Bool
    public let automaticReplay = false
    public let newSubmissionAllowed = false
    public let recovery: MusicWriteRecoveryStatus?
    public var providerResult: MusicProviderRecord? = nil
    public var readbackFailure: MusicReadFailure? = nil
    public var readbackProviderResult: MusicProviderRecord? = nil
    public var readbackState: String? = nil
    enum CodingKeys: String, CodingKey {
        case state, requestID = "request_id", originalIntent = "original_intent", originalName = "original_name"
        case playlistID = "playlist_id", songID = "song_id", effectDisposition = "effect_disposition"
        case readbackVerified = "readback_verified", automaticReplay = "automatic_replay", newSubmissionAllowed = "new_submission_allowed", recovery, providerResult = "provider_result", readbackFailure = "readback_failure", readbackProviderResult = "readback_provider_result", readbackState = "readback_state"
    }
    init(requestID: UUID, record: MusicWriteRecord? = nil, result: MusicWriteResult? = nil, recovery: MusicWriteRecoveryStatus? = nil) {
        self.recovery = recovery
        self.providerResult = result == nil ? record?.providerResult : result?.providerResult
        self.readbackProviderResult = result?.readbackProviderResult
        self.readbackFailure = result?.readbackFailure; self.readbackState = result?.readbackState
        self.requestID=requestID;state=result?.state.rawValue ?? "record_missing"
        originalIntent=record?.request.intent.rawValue;originalName=record?.request.name
        playlistID=result?.playlistID ?? record?.request.playlistID ?? record?.returnedPlaylistID
        songID=record?.request.songID
        // Present the latest reserved attempt, including pending/unknown.
        // Never fall back to the original non-dispatch after recovery started.
        if let recovery,recovery.attemptCount > 0 {
            effectDisposition=recovery.effectDisposition ?? .outcomeUnknown
        } else { effectDisposition=record?.effectDisposition }
        readbackVerified=result?.readbackVerified ?? false
    }
}
protocol MusicWriteJournal: Sendable {
    func inspect() throws -> MusicWriteLedger?
    func transaction<T>(_ body: (inout MusicWriteLedger) throws -> T) throws -> T
    func inspectRecovery(requestID: UUID) throws -> MusicWriteRecoveryRecord?
    func recoveryTransaction<T>(_ body: (MusicWriteLedger, inout MusicWriteRecoveryLedger) throws -> T) throws -> T
}

extension MusicWriteJournal {
    // Old synthetic journals must opt into the new query; no transaction fallback.
    func inspect() throws -> MusicWriteLedger? { throw CredentialError.deploymentNotApproved }
    func inspectRecovery(requestID: UUID) throws -> MusicWriteRecoveryRecord? { nil }
    func recoveryTransaction<T>(_ body: (MusicWriteLedger, inout MusicWriteRecoveryLedger) throws -> T) throws -> T { throw CredentialError.deploymentNotApproved }
}

// Current cloud-file operations have their own explicit lineage. They never
// replace a legacy request target or consume/reset its recovery reservation.
public struct MusicCloudResource: Codable, Sendable, Equatable {
    public let pcID: String
    public let songID: String
    public let originalID: String
    public let name: String
    public let artists: [String]
    public let album: String
    enum CodingKeys: String, CodingKey { case pcID = "pc_id", songID = "song_id", originalID = "original_id", name, artists, album }
    static func decimal(_ value: MusicProviderValue?) -> String? {
        let text: String
        switch value { case .integer(let n) where n > 0: text = String(n)
        case .unsigned(let n) where n > 0: text = String(n)
        case .text(let t): text = t
        default: return nil }
        return text.range(of: "^[1-9][0-9]{0,19}$", options: .regularExpression) != nil ? text : nil
    }
    init?(_ song: MusicReadSong) {
        guard song.privateCloudSong == true, let f = song.providerRecord?.fields,
              case .text(let providerID)? = f["encryptedId"] ?? f["songId"] ?? f["id"],
              providerID.lowercased() == song.songID,
              let pc = Self.decimal(f["pcId"]), let original = Self.decimal(f["originalId"]),
              let artists = song.metadata.artists, !artists.isEmpty, let album = song.metadata.album,
              !album.isEmpty, !song.name.isEmpty else { return nil }
        pcID = pc; songID = song.songID; originalID = original
        name = song.name.precomposedStringWithCanonicalMapping
        self.artists = artists.map(\.precomposedStringWithCanonicalMapping).sorted()
        self.album = album.precomposedStringWithCanonicalMapping
        guard (try? validate()) != nil else { return nil }
    }
    func validate() throws {
        guard Self.decimal(.text(pcID)) == pcID, Self.decimal(.text(originalID)) == originalID,
              MusicReadProtocol.validID(songID), songID == songID.lowercased(),
              MusicReadProtocol.validText(name, limit: 800), MusicReadProtocol.validText(album, limit: 400),
              (1...20).contains(artists.count), Set(artists).count == artists.count,
              artists == artists.sorted(), artists.allSatisfy({ MusicReadProtocol.validText($0, limit: 200) })
        else { throw CredentialError.invalidInput }
    }
    func sameFileIdentity(as other: Self) -> Bool {
        pcID == other.pcID && name == other.name && artists == other.artists && album == other.album
    }
}
public struct MusicCloudSelection: Codable, Sendable, Equatable {
    public let selectionID: UUID
    public let resource: MusicCloudResource
    public let observedAt: TimeInterval
    enum CodingKeys: String, CodingKey { case selectionID = "selection_id", resource, observedAt = "observed_at" }
}
struct MusicCloudOperationContext: Codable, Sendable, Equatable {
    let supersedesRequestID: UUID
    let selectedResource: MusicCloudResource
    let resource: MusicCloudResource
    let observedAt: TimeInterval
    func operationID(reference: UUID, epoch: UUID) -> UUID {
        let key = ["ARL.current-cloud.v1", reference.uuidString, epoch.uuidString, supersedesRequestID.uuidString,
                   resource.pcID, resource.songID, resource.originalID].joined(separator: "|")
        var bytes = Array(SHA256.hash(data: Data(key.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 15) | 128; bytes[8] = (bytes[8] & 63) | 128
        let h = bytes.map { String(format: "%02x", $0) }.joined()
        let cuts = [0,8,12,16,20,32].map { h.index(h.startIndex, offsetBy: $0) }
        return UUID(uuidString: (0..<5).map { String(h[cuts[$0]..<cuts[$0+1]]) }.joined(separator: "-"))!
    }
}
public struct MusicCurrentCloudAppendRequest: Sendable {
    public let supersedesRequestID: UUID
    public let selectionID: UUID
    public let pcID: String
    public init(supersedesRequestID: UUID, pcID: String, selectionID: UUID) {
        self.supersedesRequestID = supersedesRequestID; self.selectionID = selectionID; self.pcID = pcID
    }
}
public struct MusicCurrentCloudAppendResult: Encodable, Sendable {
    public let state: String
    public let supersedesRequestID: UUID
    public let requestID: UUID?
    public let resource: MusicCloudResource?
    public let result: MusicWriteResult?
    public let automaticReplay = false
    public let newSubmissionAllowed = false
    enum CodingKeys: String, CodingKey { case state, supersedesRequestID = "supersedes_request_id", requestID = "request_id", resource, result, automaticReplay = "automatic_replay", newSubmissionAllowed = "new_submission_allowed" }
    init(_ state: String, supersedes: UUID, context: MusicCloudOperationContext? = nil, result: MusicWriteResult? = nil) {
        self.state = state; supersedesRequestID = supersedes; requestID = result?.requestID
        resource = context?.resource; self.result = result
    }
}
extension MusicWriteLedger {
    func cloudSuccessor(of requestID: UUID) -> MusicWriteRecord? {
        records.values.first { $0.cloudResource?.supersedesRequestID == requestID }
    }
    func cloudReservation(reference: UUID, epoch: UUID, playlistID: String, pcID: String) -> MusicWriteRecord? {
        records.values.first { $0.reference == reference && $0.epoch == epoch && $0.request.playlistID == playlistID && $0.cloudResource?.resource.pcID == pcID }
    }
}
