import Foundation
import CoreFoundation

// This task-local cap shortens the existing read deadline; it never extends it.
enum MusicSearchReadDeadline {
    @TaskLocal static var current: TimeInterval?
    // Observe completion within this caller's budget. Never await/cancel the shared task itself.
    static func waitForCompletion(until deadline: TimeInterval, isPending: @Sendable () async -> Bool) async throws {
        while await isPending() {
            try Task.checkCancellation()
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw TransportFailure.timeout }
            try await Task.sleep(for: .seconds(min(0.025, remaining)))
        }
        try Task.checkCancellation()
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw TransportFailure.timeout }
    }
}

public struct MusicAggregateQuery: Sendable, Equatable {
    public enum Field: String, Sendable { case any, title, artist, album }
    public let keyword: String
    public let offset: Int
    public let field: Field
    public let artist: String?
    public let album: String?
    public let recordingVersion: String?
    public let cursor: UUID?
    public init(arguments: [String: Any]) throws {
        guard Set(arguments.keys).isSubset(of: ["keyword","offset","field","artist","album","recording_version","cursor"]),
              let keyword = arguments["keyword"] as? String, keyword.count <= 100,
              MusicReadProtocol.validText(keyword, limit: 400), !keyword.hasPrefix("-")
        else { throw CredentialError.invalidInput }
        self.keyword = keyword
        if let raw = arguments["offset"] {
            guard let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
                  n.doubleValue.rounded() == n.doubleValue, n.doubleValue == 0
            else { throw CredentialError.invalidInput }
            offset = n.intValue
        } else { offset = 0 }
        if let raw = arguments["field"] {
            guard let text = raw as? String, let field = Field(rawValue: text) else { throw CredentialError.invalidInput }
            self.field = field
        } else { field = .any }
        func optional(_ key: String) throws -> String? {
            guard let raw = arguments[key] else { return nil }
            guard let value = raw as? String, value.count <= 100, MusicReadProtocol.validText(value, limit: 400)
            else { throw CredentialError.invalidInput }
            return value
        }
        artist = try optional("artist"); album = try optional("album"); recordingVersion = try optional("recording_version")
        if let raw = arguments["cursor"] {
            guard let value = raw as? String, value.utf8.count == 36, let id = UUID(uuidString: value), offset == 0
            else { throw CredentialError.invalidInput }
            cursor = id
        } else { cursor = nil }
    }
    // Bind exact outbound keyword and exact intent. Normalization is for local matching only.
    var binding: [Data] { [keyword, field.rawValue, artist ?? "", album ?? "", recordingVersion ?? ""].map { Data($0.utf8) } }
    static func normal(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
    enum Match { case matched, noMatch }
    // A local cloud lookup only. Public candidates retain provider order and membership.
    func match(_ song: MusicReadSong) -> Match {
        let values: [String]
        switch field {
        case .any: values = [song.name] + (song.metadata.artists ?? []) + [song.metadata.album ?? ""]
        case .title: values = [song.name]
        case .artist: values = song.metadata.artists ?? []
        case .album: values = [song.metadata.album ?? ""]
        }
        let haystack = Self.normal(values.joined(separator: " "))
        let tokens = Self.normal(keyword).split(separator: " ")
        return !tokens.isEmpty && tokens.allSatisfy { haystack.contains($0) } ? .matched : .noMatch
    }
    func matches(_ song: MusicReadSong) -> Bool { match(song) == .matched }
    var unsupportedParameters: [String] {
        [("artist", artist), ("album", album), ("recording_version", recordingVersion)]
            .compactMap { $0.1 == nil ? nil : $0.0 }
    }

}
public struct MusicAggregateSong: Codable, Sendable, Equatable {
    public struct SourceRecord: Codable, Sendable, Equatable {
        public let source: String
        public let songID: String
        public let metadata: MusicReadSongMetadata
        public let providerRecord: MusicProviderRecord?
        public let privateCloudSong: Bool?
        public let playFlag: Bool?
        public let visible: Bool?
        public let unknownFields: [String]
        public var cloudSelection: MusicCloudSelection? = nil
        enum CodingKeys: String, CodingKey {
            case source, songID = "song_id", metadata, providerRecord = "provider_record", privateCloudSong = "private_cloud_song", playFlag = "play_flag", visible, unknownFields = "unknown_fields", cloudSelection = "cloud_selection"
        }
    }
    public let songID: String
    public let name: String
    public let url: URL?
    public let visible: Bool?
    public let metadata: MusicReadSongMetadata
    public let sources: [String]
    public let sourceRecords: [SourceRecord]
    public let identityAssessment: String
    public let recordingIdentityConfirmed: Bool
    public let queryMatch: String
    public let queryUnknownFields: [String]
    enum CodingKeys: String, CodingKey {
        case songID = "song_id", name, url, visible, metadata, sources, sourceRecords = "source_records",
             identityAssessment = "identity_assessment", recordingIdentityConfirmed = "recording_identity_confirmed",
             queryMatch = "query_match", queryUnknownFields = "query_unknown_fields"
    }
    init(_ song: MusicReadSong, source: String, query: MusicAggregateQuery, selection: MusicCloudSelection? = nil) {
        songID = song.songID; name = song.name; url = song.url; visible = song.visible; metadata = song.metadata
        sources = [source]
        sourceRecords = [.init(source: source, songID: song.songID, metadata: song.metadata, providerRecord: song.providerRecord,
                              privateCloudSong: song.privateCloudSong, playFlag: song.playFlag, visible: song.visible,
                              unknownFields: (song.privateCloudSong == nil ? ["private_cloud_song"] : []) +
                                (song.playFlag == nil ? ["play_flag"] : []) + (song.visible == nil ? ["visible"] : []), cloudSelection: selection)]
        identityAssessment = "deprecated_not_assessed"
        // A provider original-performer tag alone cannot identify a recording edition.
        recordingIdentityConfirmed = false
        queryMatch = source == "public_catalog" ? "provider_result" : "local_keyword_match"
        queryUnknownFields = []
    }

}
public struct MusicAggregateSourceStatus: Codable, Sendable {
    public let state: String
    public let coverage: String
    public let scannedCount: Int
    public let cachedCount: Int
    public let total: Int?
    public let cacheAgeSeconds: Int?
    public let readAttempts: Int
    public let nextPageAvailable: Bool
    public let failure: MusicReadFailure?
    public let stale: Bool?
    public let retryAfterSeconds: Int?
    public let refreshIntervalSeconds: Int?
    public let retainedUnconfirmedCount: Int?
    init(state: String, coverage: String, scannedCount: Int, cachedCount: Int, total: Int?, cacheAgeSeconds: Int?,
         readAttempts: Int, failure: MusicReadFailure?, nextPageAvailable: Bool = false, stale: Bool? = nil,
         retryAfterSeconds: Int? = nil, refreshIntervalSeconds: Int? = nil, retainedUnconfirmedCount: Int? = nil) {
        self.state = state; self.coverage = coverage; self.scannedCount = scannedCount; self.cachedCount = cachedCount
        self.total = total; self.cacheAgeSeconds = cacheAgeSeconds; self.readAttempts = readAttempts
        self.failure = failure; self.nextPageAvailable = nextPageAvailable
        self.stale = stale; self.retryAfterSeconds = retryAfterSeconds
        self.refreshIntervalSeconds = refreshIntervalSeconds; self.retainedUnconfirmedCount = retainedUnconfirmedCount
    }
    enum CodingKeys: String, CodingKey {
        case state, coverage, scannedCount = "scanned_count", cachedCount = "cached_count", total,
             cacheAgeSeconds = "cache_age_seconds", readAttempts = "read_attempts", failure, nextPageAvailable = "next_page_available",
             stale, retryAfterSeconds = "retry_after_seconds", refreshIntervalSeconds = "refresh_interval_seconds",
             retainedUnconfirmedCount = "retained_unconfirmed_count"
    }
}
public struct MusicAggregateSearchResult: Codable, Sendable {
    public struct Search: Codable, Sendable {
        public let version: Int
        public let partial: Bool
        public let nextCursor: String?
        public let sourceStatus: [String: MusicAggregateSourceStatus]
        public let identityPolicy: String
        public let matchingComplete: Bool
        public let publicRequest: PublicRequest
        public let unsupportedParameters: [String]
        public let localMatchPolicy: String
        public let deprecatedFields: [String: String]
        public var outputFailure: String? = nil
        public struct PublicRequest: Codable, Sendable {
            public let keyword: String
            public let offset: Int
            public let limit: Int
        }
        enum CodingKeys: String, CodingKey {
            case version, partial, nextCursor = "next_cursor", sourceStatus = "source_status", identityPolicy = "identity_policy", matchingComplete = "matching_complete"
            case publicRequest = "public_request", unsupportedParameters = "unsupported_parameters", localMatchPolicy = "local_match_policy", deprecatedFields = "deprecated_fields", outputFailure = "output_failure"
        }
    }
    public struct Payload: Codable, Sendable {
        public let songs: [MusicAggregateSong]
        public let complete: Bool
        public let searchPage: MusicSearchPage?
        public let search: Search
        enum CodingKeys: String, CodingKey { case songs, complete, searchPage = "search_page", search }
    }
    public let state: String
    public let session: MusicReadSession
    public let payload: Payload
}
struct MusicSearchProgress: Sendable {
    let binding: [Data]
    let createdAt: TimeInterval
    let startedFromZero: Bool
    var publicNext: Int?
    var publicScanned = 0
    var publicStarted = false
    var publicEnded = false
    var publicPage: MusicSearchPage?
    var publicPending: [MusicReadSong] = []
    var delivered: Set<String> = []
}
// Account-scoped, metadata-only in-memory index. App restart rebuilds it; no new persistent custody.
struct MusicAggregateSearchCache: Sendable {
    private struct Cursor: Sendable { let progress: MusicSearchProgress; let issuedAt: TimeInterval }
    private(set) var reference: CredentialReference?
    private(set) var generation: UUID?
    private var index: [String: MusicReadSong] = [:]
    private var indexBytes = 0
    struct CloudReceipt: Sendable {
        let selection: MusicCloudSelection
        let cursor: String?
        let limit: Int
        let issuedAt: TimeInterval
    }
    private var cloudReceipts: [String: CloudReceipt] = [:]
    private var cloudSelections: [UUID: CloudReceipt] = [:]
    private var scanPCs: Set<String> = []
    private var cursors: [UUID: Cursor] = [:]
    private var visited: Set<String> = []
    private var scanIDs: Set<String> = []
    private(set) var cloudStarted = false
    private(set) var cloudEnd = false
    private(set) var cloudNext: String?
    private(set) var cloudScanned = 0
    private(set) var cloudReadLimit = 50
    private(set) var cloudTotal: Int?
    private(set) var evicted = false // Capacity was reached; existing rows are retained, never evicted.
    private(set) var drift = false
    private(set) var fetchedAt: TimeInterval?
    private(set) var lastSuccessfulRefresh: TimeInterval?
    private(set) var lastRefreshAttempt: TimeInterval?
    private(set) var retryAfter: TimeInterval?
    private(set) var refreshing = false
    private var retainedCloudIDs: Set<String> = []
    private(set) var retainedUnconfirmedCount = 0
    static let ttl: TimeInterval = 300 // Opaque query cursor lifetime only.
    static let refreshInterval: TimeInterval = 12 * 60 * 60
        var cloudRows: [MusicReadSong] { index.values.sorted { $0.songID < $1.songID } }
    var wantsCloudPage: Bool { refreshing && !cloudEnd && !drift && !evicted }
    func isStale(now: TimeInterval) -> Bool {
        guard let lastSuccessfulRefresh else { return true }
        return now < lastSuccessfulRefresh || now - lastSuccessfulRefresh >= Self.refreshInterval ||
            !cloudEnd || drift || evicted || retainedUnconfirmedCount != 0
    }
    func shouldRefresh(for query: MusicAggregateQuery, now: TimeInterval) -> Bool {
        if refreshing { return true }
        if let retryAfter, now < retryAfter { return false }
        guard lastRefreshAttempt != nil else { return true }
        if let lastSuccessfulRefresh, now >= lastSuccessfulRefresh,
           now - lastSuccessfulRefresh < Self.refreshInterval { return false }
        // A known matching cached song does not trigger a provider scan, even when stale.
        return !index.values.contains { query.matches($0) }
    }
    mutating func bind(_ ref: CredentialReference, generation current: UUID, now: TimeInterval) {
        if reference != ref || generation != current {
            self = .init(); reference = ref; generation = current
        }
        cursors = cursors.filter { now >= $0.value.issuedAt && now - $0.value.issuedAt < Self.ttl }
    }
    mutating func advanceGeneration(from old: UUID, to new: UUID) throws {
        guard generation == old else { self = .init(); throw CredentialError.uncertainLocalState }
        generation = new
    }
    mutating func begin(_ query: MusicAggregateQuery, now: TimeInterval) throws -> MusicSearchProgress {
        if let token = query.cursor {
            guard let cursor = cursors[token], cursor.progress.binding == query.binding,
                  now >= cursor.issuedAt && now - cursor.issuedAt < Self.ttl,
                  now - cursor.progress.createdAt < Self.ttl
            else { throw CredentialError.invalidInput }
            return cursor.progress
        }
        return .init(binding: query.binding, createdAt: now, startedFromZero: query.offset == 0, publicNext: query.offset)
    }
    mutating func startCloudRefresh(now: TimeInterval) {
        guard !refreshing else { return } // Continue the existing provider cursor on the next explicit query.
        // Do not remove prior rows, including rows omitted by the provider's next listing.
        visited.removeAll(); scanIDs.removeAll(); scanPCs.removeAll()
        cloudStarted = false; cloudEnd = false; cloudNext = nil; cloudScanned = 0; cloudTotal = nil; cloudReadLimit = 50
        evicted = false; drift = false; refreshing = true; lastRefreshAttempt = now
        retryAfter = now + Self.refreshInterval
    }
    mutating func endCloudRefresh(now: TimeInterval, succeeded: Bool) {
        guard refreshing else { return }
        refreshing = false
        if succeeded && cloudEnd && !drift && !evicted {
            lastSuccessfulRefresh = now; retryAfter = now + Self.refreshInterval
            retainedCloudIDs = Set(index.keys).subtracting(scanIDs)
            retainedUnconfirmedCount = retainedCloudIDs.count
        } else {
            // A failed/incomplete scan is never retried by the very next miss.
            cloudEnd = false; refreshing = cloudNext != nil && !drift; retryAfter = nil
        }
    }
    mutating func ingestCloud(_ payload: MusicReadPayload, now: TimeInterval) throws {
        guard let songs = payload.songs, let page = payload.cloudPage, songs.count <= 50,
              Set(songs.map(\.songID)).count == songs.count else { throw CredentialError.uncertainLocalState }
        guard refreshing else { throw CredentialError.uncertainLocalState }
        if let next = page.nextCursor, visited.contains(next) || next == cloudNext {
            drift = true; cloudNext = nil; throw CredentialError.uncertainLocalState
        }
        let usedCursor = cloudNext
        if let used = cloudNext { visited.insert(used) }
        if songs.contains(where: { scanIDs.contains($0.songID) }) {
            drift = true; cloudNext = nil; throw CredentialError.uncertainLocalState
        }
        if let prior = cloudTotal, let total = page.total, prior != total { drift = true }
        for song in songs {
            scanIDs.insert(song.songID)
            let bytes = try JSONEncoder().encode(song).count + 1
            let previousBytes = try index[song.songID].map { try JSONEncoder().encode($0).count + 1 } ?? 0
            index[song.songID] = song; indexBytes += bytes - previousBytes
            if let resource = MusicCloudResource(song) {
                if !scanPCs.insert(resource.pcID).inserted { cloudReceipts.removeValue(forKey: resource.pcID); drift = true }
                else { cloudReceipts[resource.pcID] = .init(selection: .init(selectionID: UUID(), resource: resource, observedAt: now), cursor: usedCursor, limit: page.limit, issuedAt: now) }
            }
        }
        cloudStarted = true; cloudScanned += songs.count
        cloudReadLimit = page.limit
        cloudTotal = page.total ?? cloudTotal; cloudNext = page.nextCursor; cloudEnd = payload.complete
        // End/continuation evidence cannot override a contradictory known total.
        if let total = cloudTotal, cloudScanned > total ||
            (cloudEnd && cloudScanned != total) || (page.hasMore == true && cloudScanned >= total) { drift = true }
        fetchedAt = now
        if cloudEnd { endCloudRefresh(now: now, succeeded: true) }
    }
    func cloudStatus(result: MusicReadResult?, runtimeFailed: Bool, attempts: Int, now: TimeInterval) -> MusicAggregateSourceStatus {
        let coverage = drift ? "drift" : evicted ? "capacity_limited" : retainedUnconfirmedCount > 0 ? "retained_unconfirmed" :
            cloudEnd ? "end_observed" : cloudStarted ? "partial" : lastRefreshAttempt == nil ? "not_started" : "refresh_incomplete"
        return .init(state: runtimeFailed ? "runtime_failed" : result?.state.rawValue ?? (cloudStarted || lastSuccessfulRefresh != nil || !index.isEmpty ? "cached" : "not_attempted"),
                     coverage: coverage, scannedCount: cloudScanned, cachedCount: index.count, total: cloudTotal,
                     cacheAgeSeconds: lastSuccessfulRefresh.map { max(0, Int(now - $0)) }, readAttempts: attempts, failure: result?.failure,
                     nextPageAvailable: cloudNext != nil, stale: isStale(now: now),
                     retryAfterSeconds: retryAfter.map { max(0, Int(ceil($0 - now))) },
                     refreshIntervalSeconds: Int(Self.refreshInterval), retainedUnconfirmedCount: retainedUnconfirmedCount)
    }
    func cloudSelection(_ id: UUID, reference: CredentialReference, now: TimeInterval) -> CloudReceipt? {
        guard self.reference == reference, let receipt = cloudSelections[id], now >= receipt.issuedAt,
              now - receipt.issuedAt < Self.ttl else { return nil }
        return receipt
    }
    mutating func retainPointSelection(_ song: MusicReadSong, cursor: String?, limit: Int, now: TimeInterval) throws -> MusicCloudResource {
        guard let resource = MusicCloudResource(song) else { throw CredentialError.invalidInput }
        let bytes = try JSONEncoder().encode(song).count + 1
        let previous = try index[song.songID].map { try JSONEncoder().encode($0).count + 1 } ?? 0
        index[song.songID] = song; indexBytes += bytes - previous
        if let old = cloudReceipts[resource.pcID]?.selection.resource, old.songID != resource.songID, index[old.songID] != nil {
            retainedCloudIDs.insert(old.songID)
        }
        retainedCloudIDs.remove(resource.songID); retainedUnconfirmedCount = retainedCloudIDs.count
        cloudReceipts[resource.pcID] = .init(selection: .init(selectionID: UUID(), resource: resource, observedAt: now), cursor: cursor, limit: limit, issuedAt: now)
        return resource
    }
    mutating func finish(query: MusicAggregateQuery, progress initial: MusicSearchProgress,
                         statuses: [String: MusicAggregateSourceStatus], session: MusicReadSession, now: TimeInterval) throws -> MusicAggregateSearchResult {
        var progress = initial
        // Keep each source record independent. Even equal resource IDs do not prove recording identity.
        var pool: [(MusicReadSong, String)] = progress.publicPending.map { ($0, "public_catalog") } +
            cloudRows.filter(query.matches).map { ($0, "private_cloud") }
        pool.removeAll { progress.delivered.contains($0.1 + ":" + $0.0.songID) }
        cloudSelections = cloudSelections.filter { now >= $0.value.issuedAt && now - $0.value.issuedAt < Self.ttl }
        var candidates: [MusicAggregateSong] = []
        for (song, source) in pool {
            var selection: MusicCloudSelection?
            if source == "private_cloud", let resource = MusicCloudResource(song), let receipt = cloudReceipts[resource.pcID], receipt.selection.resource == resource, !drift {
                let current = MusicCloudSelection(selectionID: UUID(), resource: resource, observedAt: receipt.selection.observedAt)
                cloudSelections[current.selectionID] = .init(selection: current, cursor: receipt.cursor, limit: receipt.limit, issuedAt: now)
                selection = current
            }
            candidates.append(MusicAggregateSong(song, source: source, query: query, selection: selection))
        }
        let token = UUID()
        func continuation(_ progress: MusicSearchProgress) -> (Bool, Bool) {
            let privatePending = cloudRows.contains { query.matches($0) && !progress.delivered.contains("private_cloud:" + $0.songID) }
            let publicPending = progress.publicPending.contains { !progress.delivered.contains("public_catalog:" + $0.songID) }
            let more = (progress.publicNext != nil || publicPending || privatePending) && now - progress.createdAt < Self.ttl
            return (more, privatePending)
        }
        func response(_ rows: [MusicAggregateSong], progress: MusicSearchProgress, failure: String? = nil) -> MusicAggregateSearchResult {
            let (more, privatePending) = continuation(progress)
            let next: UUID? = failure == nil && more ? token : nil
            var progress = progress
            progress.publicPending.removeAll { progress.delivered.contains("public_catalog:" + $0.songID) }
            let sourceFailed = statuses.values.contains { !["authorized_read","cached"].contains($0.state) }
            let complete = failure == nil && progress.startedFromZero && progress.publicEnded && !isStale(now: now) &&
            next == nil && !privatePending && progress.publicPending.isEmpty && !sourceFailed
        let available = !rows.isEmpty || statuses.values.contains { ["authorized_read","cached"].contains($0.state) }
        // A public offset cannot represent pending cloud/public rows. The public
        // page is diagnostic only; only next_cursor resumes the complete progress.
        let publicPage = progress.publicPage.map { MusicSearchPage(offset: $0.offset, limit: $0.limit,
            total: $0.total, continuationSupported: false, nextOffset: nil) }
        return .init(state: failure == nil ? (available ? "authorized_read" : "sources_unavailable") : "response_too_large", session: session,
                     payload: .init(songs: rows, complete: complete, searchPage: publicPage,
                                    search: .init(version: 3, partial: !complete, nextCursor: next?.uuidString,
                                                  sourceStatus: statuses, identityPolicy: "deprecated_not_assessed; resource_ids_do_not_prove_recording_identity; sources_not_merged",
                                                  matchingComplete: true,
                                                  publicRequest: .init(keyword: query.keyword, offset: progress.publicPage?.offset ?? 0, limit: 20),
                                                  unsupportedParameters: query.unsupportedParameters,
                                                  localMatchPolicy: "private_cloud_only; all_whitespace_tokens_as_substrings; case_diacritic_width_fold; field_selects_local_text_only; public_provider_order_then_cloud_id_order",
                                                  deprecatedFields: ["identity_assessment": "ARL compatibility field; not assessed; not a provider conclusion",
                                                      "recording_identity_confirmed": "ARL compatibility field; false means not assessed, not a provider rejection",
                                                      "query_unknown_fields": "deprecated; unsupported parameters are not evaluated",
                                                      "matching_complete": "local keyword evaluation only; not identity or provider coverage"], outputFailure: failure)))
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var rows: [MusicAggregateSong] = []
        for row in candidates {
            if rows.count == 50 { break }
            var candidateProgress = progress
            for source in row.sources { candidateProgress.delivered.insert(source + ":" + row.songID) }
            let candidate = response(rows + [row], progress: candidateProgress)
            guard try encoder.encode(candidate).count <= 262144 - 1024 else {
                if rows.isEmpty { return response([], progress: progress, failure: "single_item_exceeds_owner_frame") }
                break
            }
            rows.append(row); progress = candidateProgress
        }
        progress.publicPending.removeAll { progress.delivered.contains("public_catalog:" + $0.songID) }
        if continuation(progress).0 {
            cursors[token] = .init(progress: progress, issuedAt: now)
        }
        return response(rows, progress: progress)
    }
}
