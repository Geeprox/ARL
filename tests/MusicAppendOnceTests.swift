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
    enum Mode { case notDispatched, success, lostAfterEffect, lostBeforeEffect, loggedOut, incomplete, ambiguousCreate, wrongTarget, missingMembership, drift }
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
                let returned = mode == .wrongTarget ? MusicReadPlaylist(playlistID: String(repeating: "4", count: 32), name: playlist.name, url: nil, trackCount: 0) : playlist
                let members: [MusicReadSong]? = mode == .missingMembership ? nil : mode == .drift && reads % 2 == 1 ? [.init(songID: String(repeating: "3", count: 32), name: "Other", url: nil, visible: true)] : songs
                payload = .init(songs: members, playlists: nil, playlist: returned, complete: mode != .incomplete)
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
@main enum MusicAppendOnceTests {
    static func check(_ value: Bool, _ message: String) throws {
        if !value { throw Failure.assertion(message) }
    }
    private static func setup(_ root: URL, _ label: String, _ repo: FixtureRepository,
                      intent: MusicWriteRequest.Intent = .appendSong, history: Bool = true) throws
        -> (FileMusicWriteJournal, MusicWriteRequest, URL, Data, [MusicWriteRecord]) {
        let directory = root.appendingPathComponent(label), journal = FileMusicWriteJournal(directory: directory)
        let request = try MusicWriteRequest(requestID: UUID(), intent: intent, name: "Synthetic playlist",
            playlistID: intent == .appendSong ? String(repeating: "2", count: 32) : nil,
            songID: intent == .appendSong ? String(repeating: "1", count: 32) : nil)
        let epoch = UUID()
        let original = MusicWriteRecord(request: request, reference: repo.reference.id, epoch: epoch,
                                       baseline: [], effectDisposition: .notDispatched)
        try journal.transaction {
            $0.epochs[repo.reference.id.uuidString] = epoch; $0.records[request.requestID.uuidString] = original
        }
        let attempts = history ? [
            MusicWriteRecord(request: request, reference: repo.reference.id, epoch: epoch,
                             baseline: [], effectDisposition: .notDispatched),
            MusicWriteRecord(request: request, reference: repo.reference.id, epoch: epoch,
                             baseline: [], effectDisposition: .outcomeUnknown)
        ] : []
        if history {
            try journal.recoveryTransaction { _, ledger in
                var value = MusicWriteRecoveryRecord(request: request, reference: repo.reference.id, epoch: epoch,
                                                     reason: .notDispatched, decidedAt: Date())
                value.attempts = attempts; ledger.records[request.requestID.uuidString] = value
            }
        }
        return (journal, request, directory, try Data(contentsOf: directory.appendingPathComponent("write-ledger.json")), attempts)
    }
    private static func owner(_ repository: FixtureRepository, _ music: FixtureMusic, _ journal: FileMusicWriteJournal) -> CredentialOnboarding {
        CredentialOnboarding(repository: repository, validator: FixtureValidator(), music: music, writeJournal: journal)
    }
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else { throw Failure.assertion("private root required") }
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        var groups: [String] = []
        let repo = try FixtureRepository()

        let (journal, request, directory, original, history) = try setup(root, "success", repo)
        let working = FixtureMusic(.success, existing: true), service = owner(repo, working, journal)
        let held = try await service.consumeWrite(repo.reference, request: request)
        try check(held.state == .songAbsent && working.writes == 0, "ordinary unknown remains read-only")
        let queried = try await service.reconcileWrite(repo.reference, requestID: request.requestID)
        try check(!queried.readbackVerified && working.writes == 0, "query never grants recovery")
        groups.append("ordinary_retry_and_query_do_not_send")
        let result = try await service.recoverAppendOnce(repo.reference, requestID: request.requestID)
        try check(result.readbackVerified && result.requestID == request.requestID && working.writes == 1, "explicit recovery succeeds once")
        let saved = try journal.inspectRecovery(requestID: request.requestID)!
        try check(saved.attempts.count == 3 && Array(saved.attempts.prefix(2)) == history &&
                  saved.appendDecision?.priorAttemptCount == 2 &&
                  saved.appendDecision?.contract == MusicWriteRecoveryRecord.AppendDecision.currentContract, "history preserved and linked")
        try check(try Data(contentsOf: directory.appendingPathComponent("write-ledger.json")) == original, "original ledger byte identical")
        let ledger = try JSONDecoder().decode(MusicWriteRecoveryLedger.self,
            from: Data(contentsOf: directory.appendingPathComponent("recovery-ledger.json")))
        try check(ledger.schema == 2 && result.recovery?.appendRecoveryReserved == true, "new reservation requires schema2")
        groups.append("same_UUID_one_reservation_original_and_unknown_history_preserved")
        let restarted = owner(repo, working, FileMusicWriteJournal(directory: directory))
        _ = try await restarted.recoverAppendOnce(repo.reference, requestID: request.requestID)
        _ = try await restarted.consumeWrite(repo.reference, request: request)
        try check(working.writes == 1, "restart and both entrypoints cannot repeat")
        groups.append("restart_success_never_resends")
        for change in 0..<3 {
            let before = try Data(contentsOf: directory.appendingPathComponent("recovery-ledger.json"))
            do {
                try journal.recoveryTransaction { _, ledger in
                    var value = ledger.records[request.requestID.uuidString]!
                    if change == 0 { value.attempts[1].effectDisposition = .notDispatched }
                    else if change == 1 { value.appendDecision = nil }
                    else { value.attempts.append(value.attempts.last!) }
                    ledger.records[request.requestID.uuidString] = value
                }
                throw Failure.assertion("tamper accepted")
            } catch CredentialError.uncertainLocalState {}
            try check(try Data(contentsOf: directory.appendingPathComponent("recovery-ledger.json")) == before, "failed mutation left bytes unchanged")
        }
        var downgrade = ledger; downgrade.schema = 1
        do { try downgrade.validate(originals: journal.inspect()!); throw Failure.assertion("downgrade accepted") }
        catch CredentialError.uncertainLocalState {}
        groups.append("history_mutation_second_attempt_and_schema_downgrade_rejected")

        for (label, mode) in [("uncertain", FixtureMusic.Mode.lostBeforeEffect), ("local-refusal", .notDispatched)] {
            let (j, req, dir, bytes, _) = try setup(root, label, repo)
            let transport = FixtureMusic(mode, existing: true)
            let first = try await owner(repo, transport, j).recoverAppendOnce(repo.reference, requestID: req.requestID)
            try check(!first.readbackVerified && transport.writes == 1, "uncertain/non-dispatch is not success")
            let next = owner(repo, transport, FileMusicWriteJournal(directory: dir))
            _ = try await next.recoverAppendOnce(repo.reference, requestID: req.requestID)
            _ = try await next.consumeWrite(repo.reference, request: req)
            try check(transport.writes == 1 && (try j.inspectRecovery(requestID: req.requestID))?.mayReserveAppendOnce == false,
                      "reserved once cannot renew even if locally refused")
            try check(try Data(contentsOf: dir.appendingPathComponent("write-ledger.json")) == bytes, "failed effect original preserved")
            groups.append(label + "_once_consumed_across_restart")
        }
        for (label, mode) in [("incomplete", FixtureMusic.Mode.incomplete), ("wrong-target", .wrongTarget),
                              ("missing-membership", .missingMembership), ("drift", .drift)] {
            let (j, req, _, _, _) = try setup(root, label, repo)
            let transport = FixtureMusic(mode, existing: true)
            let result = try await owner(repo, transport, j).recoverAppendOnce(repo.reference, requestID: req.requestID)
            try check(!result.readbackVerified && transport.writes == 0 &&
                      (try j.inspectRecovery(requestID: req.requestID))?.appendDecision == nil, "unsafe preflight denied")
            groups.append(label + "_no_reservation_or_effect")
        }
        do {
            let (j, req, _, _, _) = try setup(root, "already-present", repo)
            let transport = FixtureMusic(.success, existing: true); transport.hasSong = true
            let result = try await owner(repo, transport, j).recoverAppendOnce(repo.reference, requestID: req.requestID)
            try check(result.readbackVerified && result.state == "already_present" && transport.writes == 0,
                      "present song completes without effect")
            groups.append("already_present_readback_only")
        }
        do {
            let (j, req, _, _, _) = try setup(root, "changed-account", repo)
            try j.transaction { $0.epochs[repo.reference.id.uuidString] = UUID() }
            let transport = FixtureMusic(.success, existing: true)
            let result = try await owner(repo, transport, j).recoverAppendOnce(repo.reference, requestID: req.requestID)
            try check(result.state == "account_changed" && transport.writes == 0 && transport.reads == 0, "epoch changed denies")
            groups.append("account_epoch_change_denied")
        }
        do {
            let (j, req, _, _, _) = try setup(root, "wrong-intent", repo, intent: .createPlaylist, history: false)
            let transport = FixtureMusic(.success, existing: false)
            let result = try await owner(repo, transport, j).recoverAppendOnce(repo.reference, requestID: req.requestID)
            try check(result.state == "request_conflict" && transport.writes == 0, "cannot recover create via append")
            let missingDir = root.appendingPathComponent("missing-original")
            let missing = try await owner(repo, transport, FileMusicWriteJournal(directory: missingDir))
                .recoverAppendOnce(repo.reference, requestID: UUID())
            try check(missing.state == "record_missing" && !FileManager.default.fileExists(atPath: missingDir.path), "missing cannot create ledger")
            groups.append("wrong_intent_and_missing_original_never_create")
        }
        do {
            let (j, req, dir, _, _) = try setup(root, "concurrent", repo)
            let transport = FixtureMusic(.lostBeforeEffect, existing: true)
            let a = owner(repo, transport, j), b = owner(repo, transport, FileMusicWriteJournal(directory: dir))
            async let first: Void = attempt(a, repo.reference, req.requestID)
            async let second: Void = attempt(b, repo.reference, req.requestID)
            try await first; try await second
            try check(transport.writes == 1, "cross-owner reservation permits one effect")
            groups.append("concurrent_owners_one_durable_reservation")
        }
        let output: [String: Any] = ["status":"PASS","groups":groups,"real_provider":0,"real_keychain":0,"real_permissions":0]
        print(String(decoding: try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]), as: UTF8.self))
    }
    static func attempt(_ service: CredentialOnboarding, _ reference: CredentialReference, _ id: UUID) async throws {
        do { _ = try await service.recoverAppendOnce(reference, requestID: id) }
        catch CredentialError.busy {}
        catch CredentialError.staleReference {} // Concurrent lease loser must stop before an effect.
    }
}
