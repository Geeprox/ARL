import Foundation

struct LogPagingState {
    struct Request: Equatable, Sendable {
        let generation: Int
        let cursor: String?
        let sessionID: String?
        let scannedThroughSequence: Int
    }
    private(set) var generation = 0
    private(set) var sessionID: String?
    private(set) var needsSessionConfirmation = true
    private(set) var page: RedactedLogPage?
    private(set) var inFlight: Request?
    private(set) var error: String?
    private(set) var latestSequence = 0
    private(set) var scannedThroughSequence = 0
    private var completedCursors = Set<String>()
    private var completedCursorOrder: [String] = []
    private var rowIDs: [Int: Int] = [:]
    private var nextRowID = 0
    var reachedLimit: Bool { (page?.entries.count ?? 0) >= 500 }
    var canLoad: Bool { !reachedLimit && (page == nil || page?.hasMore == true || latestSequence > scannedThroughSequence) }
    var hasUnseenTail: Bool { page?.hasMore == false && canLoad }

    /// Called only with a validated server checkpoint, never a parsed cursor.
    @discardableResult mutating func observeSession(_ observed: String, latestSequence observedLatest: Int) -> Bool {
        let wasAwaitingConfirmation = needsSessionConfirmation
        let changed = sessionID != observed
        if changed {
            reset()
            sessionID = observed
            latestSequence = observedLatest
            rowIDs.removeAll()
            // nextRowID is intentionally retained: an old selection cannot
            // silently target the same sequence in another process session.
        }
        // A checkpoint sent before an in-flight page may finish afterwards.
        // Within one lifetime its older head must not rewind our progress.
        latestSequence = max(latestSequence, observedLatest)
        needsSessionConfirmation = false
        if wasAwaitingConfirmation { error = nil }
        return changed
    }
    mutating func reset() {
        generation += 1
        page = nil; inFlight = nil; error = nil
        scannedThroughSequence = 0
        completedCursors.removeAll()
        completedCursorOrder.removeAll()
    }
    mutating func begin(online: Bool, retry: Bool = false) -> Request? {
        guard online, sessionID != nil, !needsSessionConfirmation, inFlight == nil,
              canLoad, error == nil || retry else { return nil }
        let cursor = page?.nextCursor
        guard page == nil || cursor != nil else { error = "invalid_cursor"; return nil }
        guard !completedCursors.contains(cursor ?? "initial") else { error = "invalid_cursor"; return nil }
        error = nil
        let request = Request(generation: generation, cursor: cursor, sessionID: sessionID,
                              scannedThroughSequence: scannedThroughSequence)
        inFlight = request
        return request
    }
    @discardableResult mutating func complete(_ response: RedactedLogPage, sessionID returnedSession: String,
                                            latestSequence returnedLatest: Int, scannedThroughSequence returnedScanned: Int,
                                            for request: Request) -> Bool {
        guard request == inFlight, request.generation == generation else { return false }
        guard !needsSessionConfirmation, returnedSession == sessionID, returnedSession == request.sessionID else {
            disconnect(code: "log_session_changed")
            return false
        }
        guard returnedScanned >= request.scannedThroughSequence, returnedScanned <= returnedLatest,
              response.entries.allSatisfy({ $0.sequence <= returnedScanned }),
              response.hasMore ? returnedScanned < returnedLatest : returnedScanned == returnedLatest else {
            fail("invalid_response", for: request)
            return false
        }
        guard let nextCursor = response.nextCursor else { fail("invalid_cursor", for: request); return false }
        if completedCursors.contains(nextCursor) ||
            (nextCursor == request.cursor && (response.hasMore || returnedScanned != request.scannedThroughSequence)) {
            fail("invalid_cursor", for: request)
            return false
        }
        let old = page?.entries ?? []
        var seen = Set(old.map(\.sequence))
        var added: [RedactedLogEntry] = []
        for var entry in response.entries where seen.insert(entry.sequence).inserted {
            if rowIDs[entry.sequence] == nil {
                let (next, overflow) = nextRowID.addingReportingOverflow(1)
                guard !overflow else { fail("invalid_response", for: request); return false }
                nextRowID = next
                rowIDs[entry.sequence] = next
            }
            entry.presentationID = rowIDs[entry.sequence]
            added.append(entry)
        }
        let entries = Array((old + added).prefix(500))
        let retained = Set(entries.map(\.sequence))
        rowIDs = rowIDs.filter { retained.contains($0.key) }
        // A terminal empty read may legitimately retain its cursor. It can be
        // read again only after a later checkpoint reports new real events.
        if nextCursor != request.cursor {
            let completed = request.cursor ?? "initial"
            if completedCursors.insert(completed).inserted {
                completedCursorOrder.append(completed)
                if completedCursorOrder.count > 500 { completedCursors.remove(completedCursorOrder.removeFirst()) }
            }
        }
        inFlight = nil
        latestSequence = max(latestSequence, returnedLatest)
        scannedThroughSequence = returnedScanned
        page = RedactedLogPage(entries: entries, hasMore: response.hasMore && entries.count < 500,
            nextCursor: response.nextCursor, truncated: (page?.truncated ?? false) || response.truncated || old.count + added.count > 500,
            sourceDescription: response.sourceDescription)
        return true
    }
    mutating func fail(_ code: String, for request: Request) {
        guard request == inFlight, request.generation == generation else { return }
        inFlight = nil; error = code
    }
    mutating func disconnect(code: String = "disconnected") {
        generation += 1
        inFlight = nil; needsSessionConfirmation = true; error = code
        // Keep already displayed historical rows and their identities. No
        // request/response may merge until a server checkpoint confirms session.
    }
}
