import Foundation

private enum AggregateFixtureFailure: Error { case assertion(String) }
private func verify(_ value: Bool, _ name: String) throws {
    if !value { throw AggregateFixtureFailure.assertion(name) }
}
private func example(_ id: Int, artist: String = "Expected Artist", version: String? = nil, title: String = "Synthetic Song") -> MusicReadSong {
    .init(songID: String(format: "%032x", id), name: title, url: nil, visible: true,
          metadata: .init(artists: [artist], album: "Synthetic Album", recordingVersion: version,
                          durationMS: version == nil ? nil : 120000, unknownFields: version == nil ? ["recording_version","duration_ms"] : []),
          privateCloudSong: true, playFlag: true)
}
private func cloudPayload(_ rows: [MusicReadSong], cursor: String? = nil, complete: Bool = false) -> MusicReadPayload {
    .init(songs: rows, playlists: nil, playlist: nil, complete: complete,
          cloudPage: .init(limit: 50, total: nil, hasMore: complete ? false : cursor == nil ? nil : true, nextCursor: cursor))
}
private struct AggregateValidator: CredentialValidator {
    func validate(_ secret: CredentialInput, purpose: CredentialPurpose, deadline: ContinuousClock.Instant) async -> ConnectionTestResult { .init(.credentialUnconfirmed) }
}
private final class AggregateRepository: CredentialRepository, @unchecked Sendable {
    let reference = CredentialReference(purpose: .neteaseMusic)
    private let lock = NSLock()
    private var stored: StoredMetadata
    private var bytes: Data
    private var configured = true
    private var leaseCounter = 0, commitCounter = 0
    init() throws {
        stored = .init(reference: reference)
        bytes = try MusicEnvelope.seed(appID: "SYNTHETIC-APP", privateKey: String(repeating: "S", count: 64))
    }
    func counts() -> (Int, Int) { lock.withLock { (leaseCounter, commitCounter) } }
    func rotate() { lock.withLock { stored = .init(reference: reference) } }
    func revoke() { lock.withLock { configured = false } }
    func metadata(_ purpose: CredentialPurpose) throws -> StoredMetadata? { lock.withLock { configured ? stored : nil } }
    func lease(_ ref: CredentialReference) throws -> (metadata: StoredMetadata, secret: CredentialInput) {
        try lock.withLock {
            guard configured, ref == reference else { throw CredentialError.staleReference }
            leaseCounter += 1
            return (stored, try .init(purpose: .neteaseMusic, data: bytes))
        }
    }
    func commitLease(_ ref: CredentialReference, input: CredentialInput, result: ConnectionTestResult?, expectedGeneration: UUID) throws -> StoredMetadata {
        defer { input.clear() } // Production semantics: the returned transport credential is destroyed.
        return try lock.withLock {
            guard configured, ref == reference, stored.generation == expectedGeneration else { throw CredentialError.staleReference }
            bytes = try input.copyBytes(for: .neteaseMusic)
            stored = .init(reference: reference, state: result?.state ?? .savedUnverified, lastTest: result)
            commitCounter += 1
            return stored
        }
    }
    func create(_ input: CredentialInput, purpose: CredentialPurpose) throws -> StoredMetadata { input.clear(); throw CredentialError.alreadyConfigured }
    func replace(_ ref: CredentialReference, input: CredentialInput) throws -> StoredMetadata { input.clear(); throw CredentialError.deploymentNotApproved }
    func record(_ ref: CredentialReference, result: ConnectionTestResult, expectedGeneration: UUID) throws -> StoredMetadata { throw CredentialError.deploymentNotApproved }
    func remove(_ ref: CredentialReference) throws { revoke() }
}
private final class AggregateTransport: MusicReadTransport, MusicProcessBarrier, @unchecked Sendable {
    enum Mode { case success, publicFailure, cloudFailure, publicTimeout, block }
    private let lock = NSLock()
    let mode: Mode
    private var requests: [MusicReadRequest] = []
    private var lastIssued: Data?
    private var checkedRotated = false
    init(_ mode: Mode) { self.mode = mode }
    func recordedRequests() -> [MusicReadRequest] { lock.withLock { requests } }
    func observations() -> (Int, Bool) { lock.withLock { (requests.count, checkedRotated) } }
    func cleanupStatus() -> MusicCleanupStatus { .init(phase: .idle, generation: nil, lastReapedGeneration: nil) }
    func sendRead(_ secret: CredentialInput, request: MusicReadRequest) async throws -> MusicReadRuntimeResult {
        var input = try secret.copyBytes(for: .neteaseMusic)
        defer { input.resetBytes(in: 0..<input.count) }
        let sequence = try lock.withLock { () throws -> Int in
            try verify(!input.isEmpty, "cleared_credential_reused")
            if let expected = lastIssued { try verify(expected == input, "rotated_session_not_released_from_repository"); checkedRotated = true }
            requests.append(request); return requests.count
        }
        if mode == .block { try await Task.sleep(for: .seconds(10)) }
        if mode == .publicTimeout, case .search = request { throw TransportFailure.timeout }
        let outgoing = try MusicEnvelope.seed(appID: "SYNTHETIC-APP-\(sequence)", privateKey: String(repeating: "S", count: 64))
        lock.withLock { lastIssued = outgoing }
        let result: MusicReadResult
        switch request {
        case .search:
            if mode == .publicFailure { result = .init(state: .providerRejected, session: .present, payload: nil) }
            else {
                result = .init(state: .authorizedRead, session: .present,
                    payload: .init(songs: [example(1, artist: "Cover Artist")], playlists: nil, playlist: nil, complete: true,
                                   searchPage: .init(offset: 0, limit: 20, total: 21, continuationSupported: true, nextOffset: 20)))
            }
        case .cloudSongs:
            if mode == .cloudFailure { result = .init(state: .providerRejected, session: .present, payload: nil) }
            else { result = .init(state: .authorizedRead, session: .present, payload: cloudPayload([example(2)], complete: true)) }
        default: throw CredentialError.invalidInput
        }
        return .init(result: result, credential: try .init(purpose: .neteaseMusic, data: outgoing))
    }
}
private final class IndexClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 100
    func now() -> TimeInterval { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
}
private final class IndexTransport: MusicReadTransport, MusicProcessBarrier, @unchecked Sendable {
    private let lock = NSLock()
    private var cloudCursors: [String?] = []
    private var failedPage: Int?
    private var blockCloud = false
    private var sequence = 0
    func setFailure(_ page: Int?) { lock.withLock { failedPage = page } }
    func setBlocked(_ value: Bool) { lock.withLock { blockCloud = value } }
    func cursors() -> [String?] { lock.withLock { cloudCursors } }
    func cleanupStatus() -> MusicCleanupStatus { .init(phase: .idle, generation: nil, lastReapedGeneration: nil) }
    func sendRead(_ secret: CredentialInput, request: MusicReadRequest) async throws -> MusicReadRuntimeResult {
        let sequence = lock.withLock { self.sequence += 1; return self.sequence }
        // The repository consumes this envelope after every page, exercising the production lease sequence.
        let outgoing = try MusicEnvelope.seed(appID: "INDEX-SYNTHETIC-\(sequence)", privateKey: String(repeating: "S", count: 64))
        let result: MusicReadResult
        switch request {
        case .search:
            result = .init(state: .authorizedRead, session: .present,
                payload: .init(songs: [], playlists: nil, playlist: nil, complete: true,
                               searchPage: .init(offset: 0, limit: 20, total: 0, continuationSupported: true, nextOffset: nil)))
        case .cloudSongs(let cursor, _):
            let page = cursor == nil ? 0 : cursor == "synthetic-page-2" ? 1 : -1
            try verify(page >= 0, "guessed_cursor")
            let state = lock.withLock { cloudCursors.append(cursor); return (failedPage == page, blockCloud) }
            if state.1 { try await Task.sleep(for: .seconds(10)) }
            else { try await Task.sleep(for: .milliseconds(40)) }
            if state.0 { result = .init(state: .providerRejected, session: .present, payload: nil) }
            else {
                let rows = page == 0 ? (1...50).map { example($0, title: "Filler \($0)") } : [example(51, title: "Target Fifty One")]
                result = .init(state: .authorizedRead, session: .present,
                    payload: cloudPayload(rows, cursor: page == 0 ? "synthetic-page-2" : nil, complete: page == 1))
            }
        default: throw CredentialError.invalidInput
        }
        return .init(result: result, credential: try .init(purpose: .neteaseMusic, data: outgoing))
    }
}
private actor StaggeredFlightState {
    private var pending: Set<Int> = [1, 2]
    func finish(_ id: Int) { pending.remove(id) }
    func isPending(_ id: Int) -> Bool { pending.contains(id) }
}
@main struct MusicAggregateSearchTests {
    static func main() async throws {
        var groups = 0
        let query = try MusicAggregateQuery(arguments: ["keyword":"Synthetic Song","artist":"Expected Artist"])
        let publicStatus = MusicAggregateSourceStatus(state: "authorized_read", coverage: "end_observed", scannedCount: 1, cachedCount: 1,
                                                     total: 1, cacheAgeSeconds: nil, readAttempts: 1, failure: nil)
        let statuses = ["public_catalog":publicStatus,"private_cloud":publicStatus]
        if !CommandLine.arguments.contains("--increment-only") {
        // Owner lifecycle, precise session rotation, single-source independence and timeout all use the real actor.
        for mode in [AggregateTransport.Mode.success, .publicFailure, .cloudFailure, .publicTimeout] {
            let repo = try AggregateRepository(), transport = AggregateTransport(mode)
            let service = CredentialOnboarding(repository: repo, validator: AggregateValidator(), musicReads: transport)
            let result = try await service.aggregateMusicSearch(repo.reference, query: query)
            try verify(result.state == "authorized_read", "one_source_result_must_survive")
            try verify(transport.observations().0 == 2, "one_attempt_per_source")
            if mode == .success {
                try verify(transport.observations().1, "fresh_lease_after_consuming_commit")
                try verify(result.payload.songs.first?.songID == example(1).songID, "public_provider_order_changed")
                try verify(repo.counts() == (3,2), "authorization_and_two_scoped_leases")
            } else {
                try verify(result.payload.search.partial, "source_failure_must_be_partial")
                try verify(result.payload.songs.count == 1, "successful_source_retained")
            }
            groups += 1
        }
        // Unsupported compatibility intent never changes the exact public keyword/offset.
        do {
            let repo = try AggregateRepository(), transport = AggregateTransport(.success)
            let service = CredentialOnboarding(repository: repo, validator: AggregateValidator(), musicReads: transport)
            let q = try MusicAggregateQuery(arguments: ["keyword":"Come Together", "artist":"The Beatles", "album":"Abbey Road"])
            let r = try await service.aggregateMusicSearch(repo.reference, query: q)
            try verify(transport.recordedRequests().first == .search(keyword: "Come Together", offset: 0), "beatles_public_request_rewritten")
            try verify(r.payload.search.unsupportedParameters == ["artist", "album"] && r.payload.songs.count == 1, "unsupported_filter_or_unrelated_cloud")
            groups += 1
        }
        // Aggregate callers share the active operation; cancellation does not open a second provider call.
        do {
            let repo = try AggregateRepository(), transport = AggregateTransport(.block)
            let service = CredentialOnboarding(repository: repo, validator: AggregateValidator(), musicReads: transport)
            let task = Task { try await service.aggregateMusicSearch(repo.reference, query: query) }
            let until = ProcessInfo.processInfo.systemUptime + 2
            while transport.observations().0 == 0 && ProcessInfo.processInfo.systemUptime < until { await Task.yield() }
            try verify(transport.observations().0 == 1, "fixture_entered")
            let waiter = Task { try await service.aggregateMusicSearch(repo.reference, query: query) }
            try await Task.sleep(for: .milliseconds(25))
            try verify(transport.observations().0 == 1, "parallel_source_leaked")
            waiter.cancel(); task.cancel()
            do { _ = try await task.value; throw AggregateFixtureFailure.assertion("cancel_ignored") } catch is CancellationError {}
            do { _ = try await waiter.value; throw AggregateFixtureFailure.assertion("waiter_cancel_ignored") } catch is CancellationError {}
            let readiness = await service.ownerRecoveryReadiness()
            if case .ready = readiness {} else { throw AggregateFixtureFailure.assertion("slot_not_released") }
            groups += 1
        }
        // An account generation change invalidates both cached songs and opaque query cursors.
        do {
            let repo = try AggregateRepository(), transport = AggregateTransport(.success)
            let service = CredentialOnboarding(repository: repo, validator: AggregateValidator(), musicReads: transport)
            let result = try await service.aggregateMusicSearch(repo.reference, query: query)
            guard let cursor = result.payload.search.nextCursor else { throw AggregateFixtureFailure.assertion("next_cursor_missing") }
            repo.rotate()
            let continued = try MusicAggregateQuery(arguments: ["keyword":"Synthetic Song","artist":"Expected Artist","cursor":cursor])
            do { _ = try await service.aggregateMusicSearch(repo.reference, query: continued); throw AggregateFixtureFailure.assertion("account_cursor_reused") }
            catch CredentialError.invalidInput {}
            try verify(transport.observations().0 == 2, "stale_cursor_must_not_send")
            repo.revoke()
            do { _ = try await service.aggregateMusicSearch(repo.reference, query: query); throw AggregateFixtureFailure.assertion("revoked_cache_returned") }
            catch CredentialError.staleReference {}
            groups += 1
        }
        // Transparent source order and same-ID ambiguity: no title merge, no invented recording evidence.
        do {
            var cache = MusicAggregateSearchCache()
            let ref = CredentialReference(purpose: .neteaseMusic), gen = UUID()
            cache.bind(ref, generation: gen, now: 10)
            cache.startCloudRefresh(now: 10)
            try cache.ingestCloud(cloudPayload([example(7, artist:"Expected Artist")], cursor:"next"), now: 10)
            var progress = try cache.begin(query, now: 10)
            progress.publicStarted = true; progress.publicEnded = true; progress.publicNext = nil
            progress.publicPending = [example(7, artist:"Cover Artist")]
            let result = try cache.finish(query:query, progress:progress, statuses:statuses, session:.present, now:11)
            try verify(result.payload.songs.count == 2, "same_id_conflicting_identity_merged")
            try verify(result.payload.songs.first?.sources == ["public_catalog"], "public_source_order_changed")
            try verify(result.payload.songs.allSatisfy { !$0.recordingIdentityConfirmed }, "unknown_version_became_original")
            try verify(result.payload.songs.allSatisfy { $0.identityAssessment == "deprecated_not_assessed" }, "identity_assessed_locally")
            groups += 1
        }
        // Cursor expiry does not expire the index; capacity does not evict existing songs.
        do {
            var cache = MusicAggregateSearchCache()
            let ref = CredentialReference(purpose:.neteaseMusic), gen = UUID()
            cache.bind(ref,generation:gen,now:1)
            cache.startCloudRefresh(now: 1)
            for page in 0..<21 {
                let rows = (0..<50).map { example(page * 50 + $0 + 1) }
                try cache.ingestCloud(cloudPayload(rows,cursor:"page-\(page)"),now:Double(page+1))
            }
            try verify(cache.cloudRows.count == 1050 && !cache.evicted, "all_cloud_rows_retained")
            try verify(try JSONEncoder().encode(cache.cloudRows).count > 0, "cloud_index_serializable")
            let progress = try cache.begin(query,now:22)
            let result = try cache.finish(query:query,progress:progress,statuses:statuses,session:.present,now:22)
            try verify(result.payload.songs.count <= 50 && result.payload.search.partial, "page_limit_or_false_full_coverage")
            let cursor = result.payload.search.nextCursor!
            let changed = try MusicAggregateQuery(arguments:["keyword":"Other","artist":"Expected Artist","cursor":cursor])
            do { _ = try cache.begin(changed,now:23); throw AggregateFixtureFailure.assertion("cross_query_cursor") } catch CredentialError.invalidInput {}
            cache.bind(ref,generation:gen,now:400)
            try verify(!cache.cloudRows.isEmpty, "cursor_ttl_deleted_index")
            groups += 1
        }
        // Strict native decoding accepts only bounded projections; unknown data stays unknown.
        do {
            let metadata: [String:Any] = ["artists":NSNull(),"album":NSNull(),"recording_version":NSNull(),"duration_ms":NSNull(),
                                        "unknown_fields":["artists","album","recording_version","duration_ms"]]
            let song:[String:Any] = ["song_id":String(repeating:"a",count:32),"name":"Synthetic Song","metadata":metadata,"private_cloud_song":true]
            var raw:[String:Any] = ["state":"authorized_read","session":"present","payload":["songs":[song],"complete":false,
                "cloud_page":["limit":50,"total":NSNull(),"has_more":true,"next_cursor":"next"]]]
            let parsed = try MusicReadProtocol.decode(raw,for:.cloudSongs(cursor:nil))
            try verify(parsed.payload?.songs?.first?.privateCloudSong == true && parsed.payload?.cloudPage?.nextCursor == "next", "native_cloud_decode")
            raw["payload"] = ["songs":[song,song],"complete":false,"cloud_page":["limit":50,"total":NSNull(),"has_more":true,"next_cursor":"next"]]
            do { _ = try MusicReadProtocol.decode(raw,for:.cloudSongs(cursor:nil)); throw AggregateFixtureFailure.assertion("native_duplicate_id") }
            catch CredentialError.uncertainLocalState {}
            groups += 1
        }
        // First query finds item 51 without an external cursor; ordinary searches reuse the same index.
        do {
            let repo = try AggregateRepository(), transport = IndexTransport(), clock = IndexClock()
            let service = CredentialOnboarding(repository: repo, validator: AggregateValidator(), musicReads: transport, musicSearchNow: { clock.now() })
            let target = try MusicAggregateQuery(arguments: ["keyword":"Target Fifty One","field":"title"])
            let missing = try MusicAggregateQuery(arguments: ["keyword":"Absent","field":"title"])
            let first = try await service.aggregateMusicSearch(repo.reference, query: target)
            try verify(first.payload.songs.map(\.songID) == [example(51).songID], "item_51_not_returned_in_first_call")
            try verify(first.payload.complete && first.payload.search.nextCursor == nil, "complete_two_page_scan_needs_external_cursor")
            try verify(transport.cursors() == [nil,"synthetic-page-2"] && repo.counts() == (4,3), "pagination_or_page_lease_sequence")
            clock.advance(301)
            _ = try await service.consumeRead(repo.reference, request: .search(keyword: "Legacy"))
            _ = try await service.aggregateMusicSearch(repo.reference, query: missing)
            _ = try await service.aggregateMusicSearch(repo.reference, query: missing)
            try verify(transport.cursors().count == 2, "miss_or_legacy_commit_rebuilt_index")
            clock.advance(12 * 60 * 60)
            let staleHit = try await service.aggregateMusicSearch(repo.reference, query: target)
            try verify(staleHit.payload.search.sourceStatus["private_cloud"]?.stale == true && transport.cursors().count == 2, "stale_hit_refreshed")
            transport.setFailure(0)
            let failed = try await service.aggregateMusicSearch(repo.reference, query: missing)
            try verify(failed.payload.search.partial && transport.cursors().count == 3, "aged_miss_did_not_try_one_refresh")
            _ = try await service.aggregateMusicSearch(repo.reference, query: missing)
            let retained = try await service.aggregateMusicSearch(repo.reference, query: target)
            try verify(transport.cursors().count == 4 && retained.payload.songs.count == 1, "explicit_retry_retains_existing_rows")
            try verify(retained.payload.search.sourceStatus["private_cloud"]?.retryAfterSeconds == nil, "no_12_hour_failure_lockout")
            clock.advance(43201); transport.setFailure(nil)
            _ = try await service.aggregateMusicSearch(repo.reference, query: missing)
            try verify(transport.cursors().count == 6, "explicit_refresh_completes_after_failure")
            groups += 1
        }
        // Concurrent initial misses share exactly one two-page cloud scan, including different queries.
        do {
            let repo = try AggregateRepository(), transport = IndexTransport()
            let service = CredentialOnboarding(repository: repo, validator: AggregateValidator(), musicReads: transport)
            let queries = try ["Target Fifty One","Absent A","Absent B","Absent C"].map { try MusicAggregateQuery(arguments:["keyword":$0,"field":"title"]) }
            let results = try await withThrowingTaskGroup(of: MusicAggregateSearchResult.self) { group in
                for item in queries { group.addTask { try await service.aggregateMusicSearch(repo.reference, query: item) } }
                var results: [MusicAggregateSearchResult] = []
                for try await result in group { results.append(result) }
                return results
            }
            try verify(results.count == 4 && transport.cursors() == [nil,"synthetic-page-2"], "concurrent_misses_repeated_scan")
            try verify(results.filter { !$0.payload.songs.isEmpty }.count == 1, "different_query_received_other_result")
            groups += 1
        }
        // An incomplete first scan stays partial and enters cooldown without inventing absence.
        do {
            let repo = try AggregateRepository(), transport = IndexTransport()
            transport.setFailure(1)
            let service = CredentialOnboarding(repository: repo, validator: AggregateValidator(), musicReads: transport)
            let target = try MusicAggregateQuery(arguments: ["keyword":"Target Fifty One","field":"title"])
            let first = try await service.aggregateMusicSearch(repo.reference, query: target)
            let second = try await service.aggregateMusicSearch(repo.reference, query: target)
            try verify(first.payload.songs.isEmpty && second.payload.songs.isEmpty && !first.payload.complete && !second.payload.complete, "partial_scan_claimed_absence")
            try verify(transport.cursors().count == 3 && second.payload.search.sourceStatus["private_cloud"]?.cachedCount == 50, "partial_scan_resumable_and_rows_retained")
            groups += 1
        }
        // Listing omission never deletes a previously indexed song; membership becomes uncertain.
        do {
            var cache = MusicAggregateSearchCache()
            let reference = CredentialReference(purpose: .neteaseMusic), generation = UUID()
            cache.bind(reference, generation: generation, now: 1)
            cache.startCloudRefresh(now: 1)
            try cache.ingestCloud(cloudPayload([example(51)], complete: true), now: 1)
            cache.startCloudRefresh(now: 43202)
            try cache.ingestCloud(cloudPayload([], complete: true), now: 43202)
            try verify(cache.cloudRows.count == 1 && cache.retainedUnconfirmedCount == 1 && cache.isStale(now: 43202), "list_omission_deleted_or_confirmed_song")
            cache.bind(reference, generation: UUID(), now: 43203)
            try verify(cache.cloudRows.isEmpty && cache.lastRefreshAttempt == nil, "new_generation_inherited_account_index")
            groups += 1
        }
        // A late old-generation response cannot populate the new account's index.
        do {
            let repo = try AggregateRepository(), transport = IndexTransport()
            transport.setBlocked(true)
            let service = CredentialOnboarding(repository: repo, validator: AggregateValidator(), musicReads: transport)
            let target = try MusicAggregateQuery(arguments: ["keyword":"Target Fifty One","field":"title"])
            let task = Task { try await service.aggregateMusicSearch(repo.reference, query: target) }
            let until = ProcessInfo.processInfo.systemUptime + 2
            while transport.cursors().isEmpty && ProcessInfo.processInfo.systemUptime < until { await Task.yield() }
            try verify(transport.cursors().count == 1, "old_scan_not_started")
            repo.rotate(); task.cancel()
            do { _ = try await task.value; throw AggregateFixtureFailure.assertion("old_account_cancel_ignored") } catch is CancellationError {}
            transport.setBlocked(false)
            let fresh = try await service.aggregateMusicSearch(repo.reference, query: target)
            try verify(fresh.payload.complete && transport.cursors() == [nil,nil,"synthetic-page-2"], "old_scan_polluted_new_account")
            groups += 1
        }
        }
        // Contradictory total/end evidence cannot certify an incomplete account index.
        do {
            for (total, more, complete, cursor) in [(2, false, true, Optional<String>.none), (1, true, false, Optional("next"))] {
                var cache = MusicAggregateSearchCache()
                cache.bind(CredentialReference(purpose: .neteaseMusic), generation: UUID(), now: 1)
                cache.startCloudRefresh(now: 1)
                let payload = MusicReadPayload(songs: [example(51)], playlists: nil, playlist: nil, complete: complete,
                    cloudPage: .init(limit: 50, total: total, hasMore: more, nextCursor: cursor))
                try cache.ingestCloud(payload, now: 1)
                cache.endCloudRefresh(now: 1, succeeded: complete)
                try verify(cache.drift && cache.isStale(now: 1) && cache.lastSuccessfulRefresh == nil, "contradictory_total_marked_complete")
                try verify(cache.cloudRows.count == 1 && cache.retryAfter == nil && !cache.wantsCloudPage, "contradiction_erased_data_or_retried")
                let q = try MusicAggregateQuery(arguments: ["keyword":"Synthetic Song","field":"title"])
                var progress = try cache.begin(q, now: 1)
                progress.publicStarted = true; progress.publicEnded = true; progress.publicNext = nil
                let result = try cache.finish(query: q, progress: progress, statuses: statuses, session: .present, now: 2)
                try verify(result.payload.search.partial && !result.payload.complete, "contradictory_coverage_claimed_absence")
            }
            groups += 1
        }
        // Two staggered shared flights must not reset one waiting caller's original deadline.
        do {
            let state = StaggeredFlightState()
            let first = Task { try await Task.sleep(for: .milliseconds(60)); await state.finish(1) }
            let second = Task { try await Task.sleep(for: .milliseconds(1000)); await state.finish(2) }
            let began = ProcessInfo.processInfo.systemUptime, deadline = began + 0.15
            try await MusicSearchReadDeadline.waitForCompletion(until: deadline) { await state.isPending(1) }
            do {
                try await MusicSearchReadDeadline.waitForCompletion(until: deadline) { await state.isPending(2) }
                throw AggregateFixtureFailure.assertion("staggered_wait_ignored_own_deadline")
            } catch TransportFailure.timeout {}
            let elapsed = ProcessInfo.processInfo.systemUptime - began
            let stillRunning = await state.isPending(2)
            try verify(elapsed < 0.7 && stillRunning && !second.isCancelled, "waiting_timeout_cancelled_or_awaited_shared_scan")
            try await first.value; try await second.value
            let finished = await state.isPending(2)
            try verify(!finished && !second.isCancelled, "other_request_did_not_complete_after_waiter_timeout")
            groups += 1
        }
        print("{\"status\":\"PASS\",\"groups\":\(groups),\"real_keychain\":false,\"network_calls\":0,\"playlist_effects\":0}")
    }
}
