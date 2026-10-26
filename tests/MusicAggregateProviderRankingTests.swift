import Foundation
private enum ProviderFixtureFault: Error { case assertion(String) }
private func require(_ value: @autoclosure () -> Bool, _ name: String) throws {
    if !value() { throw ProviderFixtureFault.assertion(name) }
}
@main struct MusicAggregateProviderRankingTests {
    static func main() throws {
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [String: Any]
        let statuses: [String: MusicAggregateSourceStatus] = Dictionary(uniqueKeysWithValues: ["public_catalog", "private_cloud"].map {
            ($0, .init(state: "authorized_read", coverage: "end_observed", scannedCount: 0, cachedCount: 0, total: nil, cacheAgeSeconds: 0, readAttempts: 1, failure: nil))
        })
        func parsed(_ value: [String: Any], _ request: MusicReadRequest) throws -> MusicReadPayload {
            let reply = try MusicReadProtocol.decode(value, for: request)
            try require(reply.state == .authorizedRead, "projection_state"); return reply.payload!
        }
        func start(_ name: String, _ query: MusicAggregateQuery) throws -> (MusicAggregateSearchCache, MusicSearchProgress) {
            let pair = raw[name] as! [String: Any]
            let pub = try parsed(pair["public"] as! [String: Any], .search(keyword: query.keyword))
            let cloud = try parsed(pair["cloud"] as! [String: Any], .cloudSongs(cursor: nil))
            var cache = MusicAggregateSearchCache()
            cache.bind(CredentialReference(purpose: .neteaseMusic), generation: UUID(), now: 1)
            cache.startCloudRefresh(now: 1); try cache.ingestCloud(cloud, now: 1)
            var progress = try cache.begin(query, now: 1)
            progress.publicStarted = true; progress.publicEnded = pub.complete
            progress.publicPage = pub.searchPage; progress.publicNext = pub.searchPage?.nextOffset; progress.publicPending = pub.songs ?? []
            return (cache, progress)
        }
        var groups = 0
        do {
            let query = try MusicAggregateQuery(arguments: ["keyword": "No local match", "artist": "Expected Artist", "album": "Expected Album", "recording_version": "live"])
            var (cache, progress) = try start("ranked", query)
            let result = try cache.finish(query: query, progress: progress, statuses: statuses, session: .present, now: 2)
            try require(result.payload.songs.count == 1 && result.payload.songs[0].sources == ["public_catalog"], "public_candidate_filtered_or_unrelated_cloud_admitted")
            try require(result.payload.search.publicRequest.keyword == query.keyword && result.payload.search.unsupportedParameters == ["artist", "album", "recording_version"], "unsupported_filters_hidden_or_keyword_rewritten")
            try require(result.payload.songs[0].identityAssessment == "deprecated_not_assessed" && !result.payload.songs[0].recordingIdentityConfirmed, "local_identity_conclusion")
            try require(result.payload.songs[0].queryMatch == "provider_result" && !result.payload.search.deprecatedFields.isEmpty, "compatibility_semantics_missing")
            groups += 1
        }
        do {
            let q = try MusicAggregateQuery(arguments: ["keyword": "Come Together", "artist": "The Beatles", "album": "Abbey Road"])
            var (cache, progress) = try start("beatles", q)
            let result = try cache.finish(query: q, progress: progress, statuses: statuses, session: .present, now: 2)
            try require(result.payload.songs.map(\.name) == ["Provider candidate", "Come Together (Remastered)", "Come Together"], "provider_order_or_cloud_relevance")
            try require(result.payload.songs.map(\.sources) == [["public_catalog"], ["public_catalog"], ["private_cloud"]], "source_attribution_lost")
            try require(result.payload.songs.allSatisfy { $0.identityAssessment == "deprecated_not_assessed" }, "remaster_conflict_invented")
            let record = result.payload.songs[1].sourceRecords[0].providerRecord!
            try require(record.fields["fullArtists"] != nil && record.fields["duration"] != nil, "original_business_record_lost")
            groups += 1
        }
        do {
            for field in ["artist", "album"] {
                let q = try MusicAggregateQuery(arguments: ["keyword": "Unrelated", "field": field])
                var (cache, progress) = try start("unknown", q)
                let r = try cache.finish(query: q, progress: progress, statuses: statuses, session: .present, now: 2)
                try require(r.payload.songs.isEmpty, "missing_metadata_admitted_unrelated_cloud")
            }
            let q = try MusicAggregateQuery(arguments: ["keyword": "晴天", "recording_version": "1932 original"])
            var (cache, progress) = try start("unknown", q)
            let r = try cache.finish(query: q, progress: progress, statuses: statuses, session: .present, now: 2)
            try require(r.payload.songs.count == 1 && r.payload.songs[0].queryMatch == "local_keyword_match", "title_evidence_lost")
            try require(r.payload.complete && r.payload.search.unsupportedParameters == ["recording_version"], "unsupported_intent_misrepresented_as_failure")
            groups += 1
        }
        do {
            let q = try MusicAggregateQuery(arguments: ["keyword": "晴天"])
            var (cache, progress) = try start("same", q)
            let r = try cache.finish(query: q, progress: progress, statuses: statuses, session: .present, now: 2)
            try require(r.payload.songs.count == 2 && r.payload.songs.map(\.sources) == [["public_catalog"], ["private_cloud"]], "same_resource_merged_as_recording")
            try require(r.payload.songs.allSatisfy { $0.sourceRecords.count == 1 && $0.sourceRecords[0].providerRecord != nil && !$0.recordingIdentityConfirmed }, "source_record_or_identity_semantics")
            groups += 1
        }
        do {
            let q = try MusicAggregateQuery(arguments: ["keyword": "晴天"])
            var (cache, progress) = try start("pagination", q)
            var current = try cache.finish(query: q, progress: progress, statuses: statuses, session: .present, now: 2)
            var all = current.payload.songs, loadedNext = false, rounds = 0
            while let cursor = current.payload.search.nextCursor {
                rounds += 1; try require(rounds <= 10, "continuation_never_ends")
                let nextQuery = try MusicAggregateQuery(arguments: ["keyword": "晴天", "cursor": cursor])
                var resumed = try cache.begin(nextQuery, now: 3)
                if resumed.publicPending.isEmpty && !loadedNext {
                    let next = try parsed(raw["public_next"] as! [String: Any], .search(keyword: "晴天", offset: 20))
                    resumed.publicPending += next.songs!; resumed.publicPage = next.searchPage
                    resumed.publicNext = next.searchPage?.nextOffset; resumed.publicEnded = true; loadedNext = true
                }
                current = try cache.finish(query: nextQuery, progress: resumed, statuses: statuses, session: .present, now: 3); all += current.payload.songs
            }
            try require(all.count == 90 && Set(all.map(\.songID)).count == 90 && current.payload.complete, "continuation_loss_or_duplicate")
            try require(all.allSatisfy { $0.sourceRecords[0].providerRecord != nil }, "continuation_business_fields_lost")
            groups += 1
        }
        do {
            for words in [["Beyoncé", "Beyonce"], ["ABC", "abc"], ["ＡＢＣ", "ABC"]] {
                let q = try MusicAggregateQuery(arguments: ["keyword": words[0]])
                var cache = MusicAggregateSearchCache(); cache.bind(CredentialReference(purpose: .neteaseMusic), generation: UUID(), now: 1)
                let p = try cache.begin(q, now: 1), r = try cache.finish(query: q, progress: p, statuses: statuses, session: .present, now: 2)
                let changed = try MusicAggregateQuery(arguments: ["keyword": words[1], "cursor": r.payload.search.nextCursor!])
                do { _ = try cache.begin(changed, now: 3); throw ProviderFixtureFault.assertion("cursor_changed_outbound_keyword") } catch CredentialError.invalidInput {}
            }
            groups += 1
        }
        print("{\"status\":\"PASS\",\"groups\":\(groups),\"production_projection_and_transparent_aggregation\":true,\"network_calls\":0}")
    }
}
