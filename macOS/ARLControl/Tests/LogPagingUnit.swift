import Foundation

@main struct LogPagingUnit {
    static func main() throws {
        var checks: [[String: Any]] = []
        func check(_ name: String, _ passed: Bool) { checks.append(["name": name, "passed": passed]) }
        func page(_ ids: [Int], more: Bool = true, cursor: String? = "a") -> RedactedLogPage {
            .init(entries: ids.map { .init(sequence: $0, at_ms: $0, level: "info", event: "runtime_ready", code: nil, app_id: nil) }, hasMore: more, nextCursor: cursor, truncated: false, sourceDescription: "test")
        }
        // Explicit server progress fixture; these tests never parse a cursor.
        @discardableResult func complete(_ response: RedactedLogPage, for request: LogPagingState.Request, in state: inout LogPagingState) -> Bool {
            let scanned = response.entries.last?.sequence ?? state.scannedThroughSequence
            return state.complete(response, sessionID: request.sessionID!, latestSequence: scanned + (response.hasMore ? 1 : 0),
                                  scannedThroughSequence: scanned, for: request)
        }
        var p = LogPagingState(); let session = String(repeating: "a", count: 32); p.observeSession(session, latestSequence: 0)
        check("offline-does-not-request", p.begin(online: false) == nil)
        let first = p.begin(online: true)!
        check("one-request-in-flight", p.begin(online: true) == nil)
        complete(page([1, 2]), for: first, in: &p)
        let second = p.begin(online: true)!
        complete(page([2, 3], cursor: "b"), for: second, in: &p)
        check("dedupe-and-stable-append", p.page!.entries.map(\.id) == [1, 2, 3])
        let third = p.begin(online: true)!
        p.fail("rpc_deadline_exceeded", for: third)
        check("error-preserves-visible-rows", p.page!.entries.count == 3)
        check("error-does-not-auto-loop", p.begin(online: true) == nil)
        let retry = p.begin(online: true, retry: true)!
        check("retry-same-cursor", retry.cursor == "b")
        complete(page([4], more: false, cursor: "c"), for: retry, in: &p)
        check("no-more-stops", p.begin(online: true) == nil)
        p.reset(); let old = p.begin(online: true)!; p.reset(); let fresh = p.begin(online: true)!
        check("filter-reset-rejects-old-response", !complete(page([1]), for: old, in: &p) && p.inFlight == fresh && p.page == nil)
        complete(page([10], cursor: "a"), for: fresh, in: &p); let cyclic = p.begin(online: true)!
        check("unchanged-cursor-stops", !complete(page([11], cursor: "a"), for: cyclic, in: &p) && p.error == "invalid_cursor" && p.begin(online: true) == nil)
        p.reset(); let start = p.begin(online: true)!; complete(page([1], cursor: "a"), for: start, in: &p)
        let a = p.begin(online: true)!; complete(page([2], cursor: "b"), for: a, in: &p)
        let b = p.begin(online: true)!
        check("cursor-cycle-stops", !complete(page([3], cursor: "a"), for: b, in: &p))
        p.reset()
        for batch in 0..<5 { let request = p.begin(online: true)!; complete(page(Array((batch * 100)..<(batch * 100 + 100)), cursor: "c\(batch)"), for: request, in: &p) }
        check("display-bounded-at-500", p.page!.entries.count == 500 && p.reachedLimit && p.begin(online: true) == nil)
        p.reset(); let pending = p.begin(online: true)!; p.disconnect()
        check("disconnect-invalidates-in-flight", !complete(page([1]), for: pending, in: &p) && p.inFlight == nil)
        let data = try JSONSerialization.data(withJSONObject: checks, options: [.prettyPrinted, .sortedKeys]); print(String(decoding: data, as: UTF8.self))
        if checks.contains(where: { $0["passed"] as? Bool == false }) { exit(1) }
    }
}
