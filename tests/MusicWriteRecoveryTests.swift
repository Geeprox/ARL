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
            case .library, .cloudSongs, .userPlaylistsPage, .playlistDetailPage: throw CredentialError.invalidInput // Write fixtures never use partial pages.
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
@main enum MusicWriteRecoveryTests {
    static func check(_ value: Bool, _ message: String) throws {
        if !value { throw Failure.assertion(message) }
    }
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else { throw Failure.assertion("private root") }
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let repository = try FixtureRepository()
        let directory = root.appendingPathComponent("known-not-sent")
        let journal = FileMusicWriteJournal(directory: directory)
        let stopped = FixtureMusic(.notDispatched, existing: false)
        let originalOwner = CredentialOnboarding(repository: repository, validator: FixtureValidator(), music: stopped, writeJournal: journal)
        let create = try MusicWriteRequest(requestID: UUID(), intent: .createPlaylist, name: "Synthetic playlist")
        let first = try await originalOwner.consumeWrite(repository.reference, request: create)
        try check(first.state == .notDispatched && stopped.writes == 1, "local refusal")
        let originalBytes = try Data(contentsOf: directory.appendingPathComponent("write-ledger.json"))
        let working = FixtureMusic(.success, existing: false)
        let owner = CredentialOnboarding(repository: repository, validator: FixtureValidator(), music: working, writeJournal: journal)
        let created = try await owner.consumeWrite(repository.reference, request: create)
        try check(created.readbackVerified && working.writes == 1, "same UUID retry succeeds despite display-count drift")
        let again = try await owner.consumeWrite(repository.reference, request: create)
        try check(again.readbackVerified && working.writes == 1, "success duplicate only reads")
        try check(try Data(contentsOf: directory.appendingPathComponent("write-ledger.json")) == originalBytes, "original bytes preserved")
        try check(try journal.inspectRecovery(requestID: create.requestID)?.attempts.count == 1, "linked recovery")

        let unknownDirectory = root.appendingPathComponent("historical-unknown")
        let unknownJournal = FileMusicWriteJournal(directory: unknownDirectory)
        let request = try MusicWriteRequest(requestID: UUID(), intent: .createPlaylist, name: "Synthetic playlist")
        let epoch = UUID()
        try unknownJournal.transaction { ledger in
            ledger.epochs[repository.reference.id.uuidString] = epoch
            ledger.records[request.requestID.uuidString] = .init(request: request, reference: repository.reference.id, epoch: epoch, baseline: [])
        }
        let historicalBytes = try Data(contentsOf: unknownDirectory.appendingPathComponent("write-ledger.json"))
        let uncertain = FixtureMusic(.lostBeforeEffect, existing: false)
        let unknownOwner = CredentialOnboarding(repository: repository, validator: FixtureValidator(), music: uncertain, writeJournal: unknownJournal)
        let held = try await unknownOwner.consumeWrite(repository.reference, request: request)
        try check(held.state == .outcomeUnknown && uncertain.writes == 0, "no decision no recovery")
        // Synthetic equivalent of the explicitly authorized one-time historical decision.
        try unknownJournal.recoveryTransaction { _, retries in
            retries.records[request.requestID.uuidString] = .init(request: request, reference: repository.reference.id,
                epoch: epoch, reason: .userRequestedOnce, decidedAt: Date())
        }
        let lost = try await unknownOwner.consumeWrite(repository.reference, request: request)
        try check(lost.state == .outcomeUnknown && uncertain.writes == 1, "one recovery reserved before uncertain send")
        let restarted = CredentialOnboarding(repository: repository, validator: FixtureValidator(), music: uncertain,
            writeJournal: FileMusicWriteJournal(directory: unknownDirectory))
        let repeated = try await restarted.consumeWrite(repository.reference, request: request)
        let observed = try await restarted.reconcileWrite(repository.reference, requestID: request.requestID)
        try check(repeated.state == .outcomeUnknown && observed.state == "outcome_unknown" && uncertain.writes == 1, "restart cannot retry unknown")
        try check(observed.recovery?.attemptCount == 1 && observed.effectDisposition == .outcomeUnknown, "latest unknown classification presented")
        try check(try Data(contentsOf: unknownDirectory.appendingPathComponent("write-ledger.json")) == historicalBytes, "historical pending byte identical")

        // The original record remains unchanged; only the read-only DTO uses
        // the latest recovery attempt. A pending nil must not reveal old no-send.
        let originalRecord=MusicWriteRecord(request:request,reference:repository.reference.id,epoch:epoch,baseline:[],effectDisposition:.notDispatched)
        var recoveryRecord=MusicWriteRecoveryRecord(request:request,reference:repository.reference.id,epoch:epoch,reason:.notDispatched,decidedAt:Date())
        let originalProjection=MusicReconciliationResult(requestID:request.requestID,record:originalRecord,result:.init(.notDispatched,request:request))
        try check(originalProjection.effectDisposition == .notDispatched,"original non-dispatch without recovery")
        let dispositions:[MusicEffectDisposition?]=[.outcomeUnknown,nil,.submitted,.notDispatched]
        for disposition in dispositions {
            recoveryRecord.attempts=[MusicWriteRecord(request:request,reference:repository.reference.id,epoch:epoch,baseline:[],effectDisposition:disposition)]
            let projected=MusicReconciliationResult(requestID:request.requestID,record:originalRecord,result:.init(.outcomeUnknown,request:request),recovery:.init(recoveryRecord))
            try check(projected.effectDisposition == (disposition ?? .outcomeUnknown),"latest recovery disposition wins")
            try check(!projected.newSubmissionAllowed && !projected.automaticReplay,"projection cannot enable submission")
            try check(recoveryRecord.mayReserve == (disposition == .notDispatched),"unknown pending and submitted stay held")
        }
        try check(originalRecord.effectDisposition == .notDispatched && recoveryRecord.reason == .notDispatched,"historical record and admission reason preserved")

        let append = try MusicWriteRequest(requestID: UUID(), intent: .appendSong, name: create.name,
            playlistID: created.playlistID, songID: working.song)
        let added = try await owner.consumeWrite(repository.reference, request: append)
        let duplicate = try await owner.consumeWrite(repository.reference, request: append)
        try check(added.readbackVerified && duplicate.readbackVerified && working.hasSong && working.writes == 2, "create then append once")
        print("{\"status\":\"PASS\",\"groups\":[\"known_not_sent_retry_same_UUID\",\"historical_one_retry_unknown_never_replays\",\"create_then_append_once\"],\"real_keychain\":0,\"real_provider\":0}")
    }
}
