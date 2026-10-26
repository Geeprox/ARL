import Foundation
@main enum MusicProviderReviewTests {
    static func main() throws {
        try ProviderBusinessPolicy.validate(["recording":["session":["date":"1932","studio":"Example"]], "artist":["signature":"Public bio","link":"https://example.invalid/public?signature=artist&key=business-id"]])
        do { try ProviderBusinessPolicy.validate(["url":"appscheme://callback#access_token=UNFAMILIAR-UPSTREAM-TOKEN"]); preconditionFailure("custom_oauth_fragment_accepted") } catch CredentialError.uncertainLocalState {}
        let large = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [String: Any]
        let auth = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))) as! [String: Any]
        do { _ = try MusicReadProtocol.decode(auth["read"] as! [String: Any], for: .search(keyword: "Sample")); preconditionFailure("review_auth_fixture_accepted") } catch CredentialError.uncertainLocalState {}
        let input = try MusicReadProtocol.decode(large["read"] as! [String: Any], for: .search(keyword: "Sample"))
        let original = input.payload!.songs![0]
        let statuses = ["public_catalog": MusicAggregateSourceStatus(state: "authorized_read", coverage: "end_observed", scannedCount: 1, cachedCount: 1, total: 1, cacheAgeSeconds: nil, readAttempts: 1, failure: nil)]
        var cache = MusicAggregateSearchCache(); cache.bind(CredentialReference(purpose: .neteaseMusic), generation: UUID(), now: 1)
        let q = try MusicAggregateQuery(arguments: ["keyword": "Sample"])
        func progress(_ cache: inout MusicAggregateSearchCache, _ songs: [MusicReadSong]) throws -> MusicSearchProgress {
            var p = try cache.begin(q, now: 1); p.publicPending = songs; p.publicNext = nil; p.publicStarted = true; p.publicEnded = true; return p
        }
        let p = try progress(&cache, [original])
        let first = try cache.finish(query: q, progress: p, statuses: statuses, session: .present, now: 2)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let firstBytes = try encoder.encode(first).count
        precondition(first.payload.songs.count == 1 && first.payload.search.nextCursor == nil && firstBytes <= 261120, "large_transmissible_song_not_returned")
        let second = MusicReadSong(songID: String(repeating: "b", count: 32), name: original.name, url: original.url, visible: original.visible, metadata: original.metadata, providerRecord: original.providerRecord)
        let pair = try progress(&cache, [original, second]); let page1 = try cache.finish(query: q, progress: pair, statuses: statuses, session: .present, now: 2)
        precondition(page1.payload.songs.count == 1 && page1.payload.search.nextCursor != nil)
        let next = try MusicAggregateQuery(arguments: ["keyword": "Sample", "cursor": page1.payload.search.nextCursor!])
        let resumed = try cache.begin(next, now: 3); let page2 = try cache.finish(query: next, progress: resumed, statuses: statuses, session: .present, now: 3)
        precondition(page2.payload.songs.count == 1 && page2.payload.songs[0].songID != page1.payload.songs[0].songID && page2.payload.search.nextCursor == nil, "large_continuation_did_not_advance")
        var fields = original.providerRecord!.fields; fields["oversize"] = .text(String(repeating: "x", count: 270000))
        let oversized = MusicReadSong(songID: original.songID, name: original.name, url: original.url, visible: original.visible, metadata: original.metadata, providerRecord: .init(fields: fields, omittedAuthenticationFields: []))
        let overflow = try progress(&cache, [oversized]); let failure = try cache.finish(query: q, progress: overflow, statuses: statuses, session: .present, now: 2)
        precondition(failure.state == "response_too_large" && failure.payload.search.outputFailure != nil && failure.payload.search.nextCursor == nil, "oversize_empty_cursor_loop")
        print("{\"status\":\"PASS\",\"review_auth_fixture_rejected\":true,\"large_item_delivered\":true,\"continuation_advances\":true,\"oversize_explicit_without_cursor\":true}")
    }
}
