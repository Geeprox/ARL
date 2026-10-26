import Foundation

private struct FixtureValidator: CredentialValidator {
    func validate(_ secret: CredentialInput, purpose: CredentialPurpose, deadline: ContinuousClock.Instant) async -> ConnectionTestResult { .init(.credentialUnconfirmed) }
}
private final class FixtureRepository: CredentialRepository, @unchecked Sendable {
    let reference = CredentialReference(purpose: .neteaseMusic)
    private let lock = NSLock()
    private var stored: StoredMetadata
    private let bytes: Data
    var configured = true
    init() throws {
        stored = StoredMetadata(reference: reference)
        bytes = try MusicEnvelope.seed(appID: "SYNTHETIC-APP", privateKey: String(repeating: "S", count: 64))
    }
    func metadata(_ purpose: CredentialPurpose) throws -> StoredMetadata? { lock.withLock { configured ? stored : nil } }
    func lease(_ ref: CredentialReference) throws -> (metadata: StoredMetadata, secret: CredentialInput) {
        try lock.withLock {
            guard configured, ref == reference else { throw CredentialError.staleReference }
            return (stored, try CredentialInput(purpose: .neteaseMusic, data: bytes))
        }
    }
    func commitLease(_ ref: CredentialReference, input: CredentialInput, result: ConnectionTestResult?, expectedGeneration: UUID) throws -> StoredMetadata {
        defer { input.clear() }
        return try lock.withLock {
            guard ref == reference, stored.generation == expectedGeneration else { throw CredentialError.staleReference }
            stored = StoredMetadata(reference: reference, state: result?.state ?? .savedUnverified, lastTest: result); return stored
        }
    }
    func create(_ input: CredentialInput, purpose: CredentialPurpose) throws -> StoredMetadata { input.clear(); throw CredentialError.alreadyConfigured }
    func replace(_ ref: CredentialReference, input: CredentialInput) throws -> StoredMetadata { input.clear(); throw CredentialError.deploymentNotApproved }
    func record(_ ref: CredentialReference, result: ConnectionTestResult, expectedGeneration: UUID) throws -> StoredMetadata { throw CredentialError.deploymentNotApproved }
    func remove(_ ref: CredentialReference) throws { throw CredentialError.deploymentNotApproved }
}
private final class FixtureMusic: MusicTransport, MusicReadTransport, MusicWriteTransport, @unchecked Sendable {
    enum Mode { case notDispatched, success, lostAfterEffect, lostBeforeEffect, loggedOut, incomplete, ambiguousCreate }
    private let lock = NSLock()
    let mode: Mode
    let id = String(repeating: "2", count: 32), song = String(repeating: "1", count: 32)
    var playlistExists: Bool
    var hasSong = false
    var writes = 0
    var reads = 0
    init(_ mode: Mode, existing: Bool) { self.mode = mode; playlistExists = existing }
    func copy(_ secret: CredentialInput) throws -> CredentialInput { try .init(purpose: .neteaseMusic, data: secret.copyBytes(for: .neteaseMusic)) }
    func send(_ secret: CredentialInput, operation: MusicOperation, onLoginURL: @escaping @Sendable (URL) -> Void) async throws -> MusicRuntimeResult {
        .init(state: .sessionPresentUnverified, credential: try copy(secret))
    }
    func sendRead(_ secret: CredentialInput, request: MusicReadRequest) async throws -> MusicReadRuntimeResult {
        try lock.withLock {
            reads += 1
            if mode == .loggedOut { return .init(result: .init(state: .loginRequired, session: .missing, payload: nil), credential: try copy(secret)) }
            let playlist = MusicReadPlaylist(playlistID: id, name: "Synthetic playlist", url: nil, trackCount: reads % 2)
            let songs: [MusicReadSong] = hasSong ? [.init(songID: song, name: "Synthetic song", url: nil, visible: true)] : []
            let payload: MusicReadPayload
            switch request {
            case .cloudSongs, .userPlaylistsPage, .playlistDetailPage: throw CredentialError.invalidInput // Write fixtures never use partial pages.
            case .userPlaylists:
                var rows = playlistExists ? [playlist] : []
                if mode == .ambiguousCreate, writes > 0 { rows.append(.init(playlistID: String(repeating: "3", count: 32), name: playlist.name, url: nil, trackCount: 0)) }
                payload = .init(songs: nil, playlists: rows, playlist: nil, complete: mode != .incomplete)
            case .playlistDetail(let target):
                guard target == id, playlistExists else { return .init(result: .init(state: .providerRejected, session: .present, payload: nil), credential: try copy(secret)) }
                payload = .init(songs: songs, playlists: nil, playlist: playlist, complete: mode != .incomplete)
            case .search: payload = .init(songs: songs, playlists: nil, playlist: nil, complete: true)
            }
            return .init(result: .init(state: .authorizedRead, session: .present, payload: payload), credential: try copy(secret))
        }
    }
    func sendWrite(_ secret: CredentialInput, request: MusicWriteRequest) async throws -> MusicWriteEffect {
        try lock.withLock {
            writes += 1
            if mode == .notDispatched { return .init(state: .notSubmitted, playlistID: nil, credential: try copy(secret)) }
            if mode == .lostBeforeEffect { throw CredentialError.storageUnavailable }
            if request.intent == .createPlaylist { playlistExists = true } else { hasSong = true }
            if mode == .lostAfterEffect || mode == .ambiguousCreate { throw CredentialError.storageUnavailable }
            return .init(state: .submitted, playlistID: id, credential: try copy(secret))
        }
    }
}

private enum Failure: Error { case assertion(String) }
@main enum MusicExplicitRecoveryNotSentTests {
    static func check(_ value: Bool, _ message: String) throws { if !value { throw Failure.assertion(message) } }
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let repository = try FixtureRepository()
        let request = try MusicWriteRequest(requestID: UUID(), intent: .createPlaylist, name: "Synthetic playlist")
        let directory = root.appendingPathComponent("explicit-known-not-sent")
        let journal = FileMusicWriteJournal(directory: directory), epoch = UUID()
        try journal.transaction { ledger in
            ledger.epochs[repository.reference.id.uuidString] = epoch
            ledger.records[request.requestID.uuidString] = .init(request: request, reference: repository.reference.id, epoch: epoch, baseline: [])
        }
        let original = try Data(contentsOf: directory.appendingPathComponent("write-ledger.json"))
        try journal.recoveryTransaction { _, retries in
            retries.records[request.requestID.uuidString] = .init(request: request, reference: repository.reference.id, epoch: epoch, reason: .userRequestedOnce, decidedAt: Date())
        }
        let rejected = FixtureMusic(.notDispatched, existing: false)
        let owner = CredentialOnboarding(repository: repository, validator: FixtureValidator(), music: rejected, writeJournal: journal)
        let stopped = try await owner.consumeWrite(repository.reference, request: request)
        try check(stopped.state == .notDispatched && rejected.writes == 1, "explicit decision reached local non-dispatch")
        let stored = try journal.inspectRecovery(requestID: request.requestID)
        try check(stored?.attempts.count == 1 && stored?.mayReserve == true, "non-dispatch preserves eligibility without a new decision")
        let query = try MusicWriteRequest(requestID: request.requestID, intent: .createPlaylist, name: request.name, reconcileOnly: true)
        let queried = try await owner.consumeWrite(repository.reference, request: query)
        try check(queried.state == .notDispatched && rejected.writes == 1, "query never dispatches")
        let working = FixtureMusic(.success, existing: false)
        let restarted = CredentialOnboarding(repository: repository, validator: FixtureValidator(), music: working, writeJournal: FileMusicWriteJournal(directory: directory))
        let next = try await restarted.consumeWrite(repository.reference, request: request)
        let duplicate = try await restarted.consumeWrite(repository.reference, request: request)
        try check(next.readbackVerified && duplicate.readbackVerified && working.writes == 1, "same explicit original succeeds once after restart")
        let after = try journal.inspectRecovery(requestID: request.requestID)
        try check(after?.attempts.count == 2 && after?.attempts.first?.effectDisposition == .notDispatched && after?.attempts.last?.effectDisposition == .submitted && after?.mayReserve == false, "append-only attempts preserve one submitted effect")
        try check(try Data(contentsOf: directory.appendingPathComponent("write-ledger.json")) == original, "original bytes preserved")
        let unknownDirectory = root.appendingPathComponent("unknown-remains-held")
        let unknownJournal = FileMusicWriteJournal(directory: unknownDirectory)
        try unknownJournal.transaction { ledger in
            ledger.epochs[repository.reference.id.uuidString] = epoch
            ledger.records[request.requestID.uuidString] = .init(request: request, reference: repository.reference.id, epoch: epoch, baseline: [])
        }
        try unknownJournal.recoveryTransaction { _, retries in
            retries.records[request.requestID.uuidString] = .init(request: request, reference: repository.reference.id, epoch: epoch, reason: .userRequestedOnce, decidedAt: Date())
        }
        let uncertain = FixtureMusic(.lostBeforeEffect, existing: false)
        let unknownOwner = CredentialOnboarding(repository: repository, validator: FixtureValidator(), music: uncertain, writeJournal: unknownJournal)
        let first = try await unknownOwner.consumeWrite(repository.reference, request: request)
        let again = try await unknownOwner.consumeWrite(repository.reference, request: request)
        try check(first.state == .outcomeUnknown && again.state == .outcomeUnknown && uncertain.writes == 1, "unknown never gains eligibility")
        try check(try unknownJournal.inspectRecovery(requestID: request.requestID)?.mayReserve == false, "unknown state remains held")
        print("{\"status\":\"PASS\",\"groups\":[\"explicit_not_sent_same_UUID_retry_without_new_decision\",\"query_never_dispatches\",\"unknown_never_replays\"],\"real_provider\":0,\"real_keychain\":0}")
    }
}
