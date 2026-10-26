import Foundation

@main struct LogSessionPagingUnit {
    static func main() throws {
        let a = String(repeating: "a", count: 32)
        let b = String(repeating: "b", count: 32)
        func page(_ sequences: [Int], cursor: String = "opaque", more: Bool = false) -> RedactedLogPage {
            .init(entries: sequences.map { .init(sequence: $0, at_ms: 1000, level: "info", event: "runtime_ready", code: nil, app_id: nil) },
                  hasMore: more, nextCursor: cursor, truncated: false, sourceDescription: "test")
        }
        @discardableResult func complete(_ response: RedactedLogPage, sessionID: String, for request: LogPagingState.Request, in state: inout LogPagingState) -> Bool {
            let scanned = response.entries.last?.sequence ?? state.scannedThroughSequence
            return state.complete(response, sessionID: sessionID, latestSequence: scanned + (response.hasMore ? 1 : 0),
                                  scannedThroughSequence: scanned, for: request)
        }
        func rejectsPage(_ raw: [String: Any]) -> Bool {
            do { _ = try LogSessionReply.page(JSONSerialization.data(withJSONObject: raw)); return false }
            catch { return true }
        }
        var checks: [[String: Any]] = []
        func check(_ name: String, _ passed: Bool) { checks.append(["name": name, "passed": passed]) }
        var state = LogPagingState()
        check("no-page-without-server-checkpoint", state.begin(online: true) == nil)
        state.observeSession(a, latestSequence: 2)
        let first = state.begin(online: true)!
        complete(page([1, 2]), sessionID: a, for: first, in: &state)
        let ids = state.page!.entries.map(\.id)
        let generation = state.generation
        for _ in 0..<20 { state.observeSession(a, latestSequence: 2) }
        check("steady-refresh-keeps-rows-identities-generation", state.generation == generation && state.page!.entries.map(\.id) == ids)
        check("end-page-does-not-block-session-checkpoint", !state.canLoad && !state.observeSession(a, latestSequence: 2))
        state.disconnect()
        check("disconnect-retains-historical-rows", state.page!.entries.map(\.id) == ids)
        check("no-request-before-session-confirmed", state.begin(online: true, retry: true) == nil)
        state.observeSession(a, latestSequence: 2)
        check("same-session-reconnect-keeps-selection-identities", state.page!.entries.map(\.id) == ids && !state.needsSessionConfirmation)
        state.disconnect(code: "rpc_deadline_exceeded")
        state.observeSession(a, latestSequence: 2)
        check("checkpoint-timeout-clears-after-confirmed-reconnect", state.error == nil && state.page!.entries.map(\.id) == ids)
        state.observeSession(a, latestSequence: 3)
        check("ended-page-new-real-head-enables-tail", state.hasUnseenTail && state.page!.entries.map(\.id) == ids)
        let tail = state.begin(online: true)!
        check("tail-retains-opaque-terminal-cursor", tail.cursor == "opaque")
        complete(page([3], cursor: "tail"), sessionID: a, for: tail, in: &state)
        check("tail-appends-preserving-selected-identity", Array(state.page!.entries.prefix(2).map(\.id)) == ids && state.page!.entries.map(\.sequence) == [1, 2, 3] && !state.canLoad)
        state.observeSession(a, latestSequence: 2)
        check("older-checkpoint-cannot-rewind-head", state.latestSequence == 3 && !state.canLoad)
        let beforeRestart = state.generation
        check("explicit-new-session-invalidates-once", state.observeSession(b, latestSequence: 2) && state.page == nil && state.generation == beforeRestart + 1)
        check("repeated-new-session-no-second-clear", !state.observeSession(b, latestSequence: 2) && state.generation == beforeRestart + 1)
        let newPage = state.begin(online: true)!
        complete(page([1, 2]), sessionID: b, for: newPage, in: &state)
        check("reused-sequences-cannot-retarget-old-selection", Set(ids).isDisjoint(with: state.page!.entries.map(\.id)))
        check("wire-sequence-remains-original", state.page!.entries.map(\.sequence) == [1, 2])
        let encoded = try JSONEncoder().encode(state.page!.entries[0])
        let keys = Set((try JSONSerialization.jsonObject(with: encoded) as! [String: Any]).keys)
        check("local-identity-never-exported", keys == ["sequence", "at_ms", "level", "event", "code", "app_id"])
        state.reset()
        let old = state.begin(online: true)!
        state.observeSession(a, latestSequence: 2)
        let current = state.begin(online: true)!
        check("late-old-page-rejected-after-session-change", !complete(page([3]), sessionID: b, for: old, in: &state) && state.inFlight == current)
        check("atomic-page-session-mismatch-rejected", !complete(page([3]), sessionID: b, for: current, in: &state) && state.needsSessionConfirmation)
        state.observeSession(a, latestSequence: 2)
        let pending = state.begin(online: true)!
        state.disconnect()
        check("late-response-after-disconnect-rejected", !complete(page([3]), sessionID: a, for: pending, in: &state))
        let checkpoint: [String: Any] = ["schema_version": 3, "redaction_version": 1, "mode": "checkpoint", "session_id": a, "latest_sequence": 2]
        check("strict-checkpoint-decodes", try LogSessionReply.checkpoint(JSONSerialization.data(withJSONObject: checkpoint)).sessionID == a)
        var oldSchema = checkpoint; oldSchema["schema_version"] = 2
        do { _ = try LogSessionReply.checkpoint(JSONSerialization.data(withJSONObject: oldSchema)); check("no-silent-v2-fallback", false) }
        catch { check("no-silent-v2-fallback", true) }
        var hostile = checkpoint; hostile["session_id"] = "not-a-session"
        do { _ = try LogSessionReply.checkpoint(JSONSerialization.data(withJSONObject: hostile)); check("session-bound-validated", false) }
        catch { check("session-bound-validated", true) }
        state.observeSession(a, latestSequence: 3)
        let filtered = state.begin(online: true)!
        state.reset()
        let fresh = state.begin(online: true)!
        check("filter-cancellation-rejects-late-page", !complete(page([3]), sessionID: a, for: filtered, in: &state) && state.inFlight == fresh)
        var empty = LogPagingState()
        empty.observeSession(a, latestSequence: 0)
        let noRows = empty.begin(online: true)!
        check("empty-stream-stops-with-bound-cursor", empty.complete(page([], cursor: "zero"), sessionID: a, latestSequence: 0, scannedThroughSequence: 0, for: noRows) && !empty.canLoad)
        empty.observeSession(a, latestSequence: 1)
        let firstEvent = empty.begin(online: true)!
        complete(page([1], cursor: "one"), sessionID: a, for: firstEvent, in: &empty)
        check("empty-ended-stream-receives-new-event", empty.page!.entries.map(\.sequence) == [1] && !empty.canLoad)
        let selected = empty.page!.entries[0].id
        empty.observeSession(a, latestSequence: 2)
        let excluded = empty.begin(online: true)!
        empty.complete(page([], cursor: "two"), sessionID: a, latestSequence: 2, scannedThroughSequence: 2, for: excluded)
        check("filtered-empty-tail-consumes-progress", empty.page!.entries.map(\.sequence) == [1] && !empty.canLoad && empty.page!.entries[0].id == selected)
        empty.observeSession(a, latestSequence: 3)
        let afterExcluded = empty.begin(online: true)!
        complete(page([3], cursor: "three"), sessionID: a, for: afterExcluded, in: &empty)
        check("matching-event-after-filtered-empty-tail", empty.page!.entries.map(\.sequence) == [1, 3] && empty.page!.entries[0].id == selected)
        var booleanHead = checkpoint; booleanHead["latest_sequence"] = true
        do { _ = try LogSessionReply.checkpoint(JSONSerialization.data(withJSONObject: booleanHead)); check("checkpoint-rejects-boolean-head", false) }
        catch { check("checkpoint-rejects-boolean-head", true) }
        var extra = checkpoint; extra["extra"] = 0
        do { _ = try LogSessionReply.checkpoint(JSONSerialization.data(withJSONObject: extra)); check("checkpoint-rejects-extra-field", false) }
        catch { check("checkpoint-rejects-extra-field", true) }
        let record: [String: Any] = ["sequence": 1, "at_ms": 1000, "level": "info", "event": "runtime_ready", "code": NSNull(), "app_id": NSNull()]
        let wire: [String: Any] = ["schema_version": 3, "redaction_version": 1, "mode": "page", "session_id": a,
            "latest_sequence": 1, "scanned_through_sequence": 1, "records": [record], "next_cursor": "opaque", "more": false, "truncated": false]
        let parsed = try LogSessionReply.page(JSONSerialization.data(withJSONObject: wire))
        check("strict-page-decodes-with-opaque-cursor", parsed.sessionID == a && parsed.latestSequence == 1 && parsed.page.entries.map(\.sequence) == [1])
        var badPage = wire; badPage["scanned_through_sequence"] = 2
        check("page-rejects-scan-beyond-head", rejectsPage(badPage))
        badPage = wire; badPage["scanned_through_sequence"] = 0
        check("page-rejects-record-beyond-scan", rejectsPage(badPage))
        badPage = wire; badPage["more"] = true
        check("page-rejects-more-with-no-unscanned-event", rejectsPage(badPage))
        badPage = wire; badPage["next_cursor"] = NSNull()
        check("page-rejects-unbound-terminal-cursor", rejectsPage(badPage))
        let passed = checks.allSatisfy { $0["passed"] as? Bool == true }
        print(String(decoding: try JSONSerialization.data(withJSONObject: ["passed": passed, "cases": checks], options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
        if !passed { exit(1) }
    }
}
