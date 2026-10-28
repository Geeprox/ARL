import Foundation
@testable import ARLCredentialOnboarding

@main enum MusicWriteArchiveTests {
    enum Failure: Error { case assertion(String) }
    static func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try value() else { throw Failure.assertion(message) }
    }
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), journal = FileMusicWriteJournal(directory: root)
        let reference = UUID(), epoch = UUID(), firstID = UUID(), pendingID = UUID(), recoveredID = UUID()
        func record(_ id: UUID, complete: Bool) throws -> MusicWriteRecord {
            let request = try MusicWriteRequest(requestID: id, intent: .createPlaylist, name: "Synthetic archive")
            return MusicWriteRecord(request: request, reference: reference, epoch: epoch, baseline: [],
                effectDisposition: complete ? .submitted : .outcomeUnknown, returnedPlaylistID: complete ? String(repeating: "a", count: 32) : nil,
                result: complete ? MusicWriteResult(.verified, request: request, playlistID: String(repeating: "a", count: 32)) : nil)
        }
        let first = try record(firstID, complete: true), pending = try record(pendingID, complete: false)
        let recovered = try record(recoveredID, complete: false)
        try journal.transaction { ledger in
            ledger.epochs[reference.uuidString] = epoch
            ledger.records[firstID.uuidString] = first
            ledger.records[pendingID.uuidString] = pending
            ledger.records[recoveredID.uuidString] = recovered
        }
        try journal.recoveryTransaction { _, recovery in
            recovery.records[recoveredID.uuidString] = MusicWriteRecoveryRecord(request: recovered.request,
                reference: reference, epoch: epoch, reason: .userRequestedOnce, decidedAt: Date(),
                reconciled: MusicWriteResult(.verified, request: recovered.request, playlistID: String(repeating: "b", count: 32)))
        }
        for _ in 0..<650 {
            let row = try record(UUID(), complete: true)
            try journal.transaction { $0.records[row.request.requestID.uuidString] = row }
        }
        let active = try journal.inspect()!
        try expect(active.records.count < 384 && active.schema == 4, "terminal history compacts before original 512-record ceiling")
        try expect(active.records[pendingID.uuidString] == pending, "uncertain effects remain active")
        try expect(active.epochs[reference.uuidString] == epoch, "compaction never rotates authority")
        let reopened = FileMusicWriteJournal(directory: root)
        try expect(try reopened.inspect(requestID: firstID)?.records[firstID.uuidString] == first, "original terminal receipt survives restart")
        try expect(try reopened.inspectRecovery(requestID: recoveredID)?.reconciled?.playlistID == String(repeating: "b", count: 32), "recovery receipt survives archival")
        do {
            try reopened.transaction { $0.records[firstID.uuidString] = first }
            throw Failure.assertion("archived UUID replay admitted")
        } catch CredentialError.uncertainLocalState {}
        // Simulate interrupted active compaction with both durable copies.
        let path = root.appendingPathComponent("write-ledger.json")
        var interrupted = try JSONDecoder().decode(MusicWriteLedger.self, from: Data(contentsOf: path))
        interrupted.records[firstID.uuidString] = first
        try JSONEncoder().encode(interrupted).write(to: path)
        try expect(try reopened.inspect(requestID: firstID)?.records[firstID.uuidString] == first, "duplicate durable copies agree")
        // A known archived record cannot disappear and become a new effect.
        let archived = root.appendingPathComponent("completed-" + firstID.uuidString.lowercased() + ".json")
        try FileManager.default.removeItem(at: archived)
        do {
            _ = try reopened.inspect(requestID: firstID)
            throw Failure.assertion("missing archive treated as unseen request")
        } catch CredentialError.uncertainLocalState {}
        print("PASS music archive: 653 durable intents, reopen, dedup, recovery and missing-file rejection; no provider calls")
    }
}
