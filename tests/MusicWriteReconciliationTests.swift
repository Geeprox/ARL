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
    enum Mode { case notDispatched, success, lostAfterEffect, lostBeforeEffect, loggedOut, incomplete, ambiguousCreate, readFailed, notAdded, incompleteAfterWrite }
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
            if mode == .readFailed && writes > 0 {
                let correlation=UUID()
                let raw: [String:Any] = ["state":"provider_rejected","session":"present","payload":NSNull(),"failure":[
                    "reason":"provider_rejected","stage":"provider_response","retryable":false,"automatic_retry":false,
                    "correlation_id":correlation.uuidString,"http_status":200,"local_code":NSNull(),"next_step":"inspect_provider_response",
                    "output_bytes":NSNull(),"output_limit_bytes":NSNull(),
                    "provider_result":["fields":["path":"/openapi/music/basic/playlist/song/list/get/v3","body":["code":200,"subCode":10007,"message":String(repeating:"original reason ",count:1000),"data":NSNull()]],"omitted_authentication_fields":[]]]]
                return .init(result:try MusicReadProtocol.decode(raw,for:request,correlationID:correlation),credential:try copy(secret))
            }
            let playlist = MusicReadPlaylist(playlistID: id, name: "Synthetic playlist", url: nil, trackCount: hasSong ? 1 : 0)
            let songs: [MusicReadSong] = hasSong ? [.init(songID: song, name: "Synthetic song", url: nil, visible: true)] : []
            let payload: MusicReadPayload
            switch request {
            case .cloudSongs, .userPlaylistsPage, .playlistDetailPage: throw CredentialError.invalidInput // Write fixtures never use partial pages.
            case .userPlaylists:
                var rows = playlistExists ? [playlist] : []
                if mode == .ambiguousCreate, writes > 0 { rows.append(.init(playlistID: String(repeating: "3", count: 32), name: playlist.name, url: nil, trackCount: 0)) }
                payload = .init(songs: nil, playlists: rows, playlist: nil, complete: mode != .incomplete && !(mode == .incompleteAfterWrite && writes > 0))
            case .playlistDetail(let target):
                guard target == id, playlistExists else { return .init(result: .init(state: .providerRejected, session: .present, payload: nil), credential: try copy(secret)) }
                payload = .init(songs: songs, playlists: nil, playlist: playlist, complete: mode != .incomplete && !(mode == .incompleteAfterWrite && writes > 0))
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
            if request.intent == .createPlaylist { playlistExists = true } else if ![.readFailed,.notAdded,.incompleteAfterWrite].contains(mode) { hasSong = true }
            if mode == .lostAfterEffect || mode == .ambiguousCreate { throw CredentialError.storageUnavailable }
            return .init(state: .submitted, playlistID: id, credential: try copy(secret))
        }
    }
}
private enum Failure: Error { case assertion }
@main enum MusicWriteReconciliationTests {
    static func check(_ value: Bool, line: Int = #line) throws { if !value { FileHandle.standardError.write(Data("assertion line: \(line)\n".utf8)); throw Failure.assertion } }
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else { throw Failure.assertion }
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let repository = try FixtureRepository(), music = FixtureMusic(.notDispatched, existing: false)
        let directory = root.appendingPathComponent("ledger")
        let journal = FileMusicWriteJournal(directory: directory)
        let owner = CredentialOnboarding(repository: repository, validator: FixtureValidator(), music: music, writeJournal: journal)
        let missingID = UUID()
        let missing = try await owner.reconcileWrite(repository.reference, requestID: missingID)
        try check(missing.state == "record_missing" && music.writes == 0 && music.reads == 0)
        try check(!FileManager.default.fileExists(atPath: directory.path))

        let request = try MusicWriteRequest(requestID: UUID(), intent: .createPlaylist, name: "Synthetic playlist")
        let first = try await owner.consumeWrite(repository.reference, request: request)
        try check(first.state == .notDispatched && music.writes == 1)
        let saved = try journal.inspect()
        try check(saved?.records[request.requestID.uuidString]?.effectDisposition == .notDispatched)
        let reads = music.reads
        let restarted = CredentialOnboarding(repository: repository, validator: FixtureValidator(), music: music,
            writeJournal: FileMusicWriteJournal(directory: directory))
        let query = try await restarted.reconcileWrite(repository.reference, requestID: request.requestID)
        try check(query.state == "not_dispatched" && !query.automaticReplay && !query.newSubmissionAllowed)
        let readonlyRequest = try MusicWriteRequest(requestID: request.requestID, intent: request.intent, name: request.name, reconcileOnly: true)
        let replay = try await restarted.consumeWrite(repository.reference, request: readonlyRequest)
        try check(replay.state == .notDispatched && music.writes == 1 && music.reads == reads)

        // Historical pending record: absence of a disposition can never be
        // inferred into not_dispatched from an empty, complete provider list.
        let historical = try MusicWriteRequest(requestID: UUID(), intent: .createPlaylist, name: "Historical synthetic")
        try journal.transaction { ledger in
            guard let epoch = ledger.epochs[repository.reference.id.uuidString] else { throw Failure.assertion }
            ledger.records[historical.requestID.uuidString] = .init(request: historical, reference: repository.reference.id,
                epoch: epoch, baseline: [], returnedPlaylistID: nil, result: nil)
        }
        let legacy = try await restarted.reconcileWrite(repository.reference, requestID: historical.requestID)
        try check(legacy.state == "outcome_unknown" && legacy.effectDisposition == nil && !legacy.readbackVerified)
        let stillPending = try journal.inspect()?.records[historical.requestID.uuidString]
        try check(stillPending?.effectDisposition == nil && stillPending?.result == nil && music.writes == 1)
        let missingAgain = try await restarted.reconcileWrite(repository.reference, requestID: UUID())
        try check(missingAgain.state == "record_missing" && (try journal.inspect()?.records.count) == 2 && music.writes == 1)
        for mode in [FixtureMusic.Mode.readFailed,.notAdded,.incompleteAfterWrite] {
            let repo = try FixtureRepository(), transport = FixtureMusic(mode,existing:true)
            let store = FileMusicWriteJournal(directory:root.appendingPathComponent("classification-"+String(describing:mode)))
            let service = CredentialOnboarding(repository:repo,validator:FixtureValidator(),music:transport,writeJournal:store)
            let append = try MusicWriteRequest(requestID:UUID(),intent:.appendSong,name:"Synthetic playlist",playlistID:transport.id,songID:transport.song)
            let result = try await service.consumeWrite(repo.reference,request:append)
            let expected: MusicWriteResult.State = mode == .readFailed ? .readbackFailed : mode == .notAdded ? .songAbsent : .incompleteRead
            try check(result.state == expected && transport.writes == 1 && !result.readbackVerified)
            if mode == .readFailed {
                let json = try JSONSerialization.jsonObject(with:JSONEncoder().encode(result)) as! [String:Any]
                let failure=json["readback_failure"] as! [String:Any]
                let body=((failure["provider_result"] as! [String:Any])["fields"] as! [String:Any])["body"] as! [String:Any]
                try check((body["subCode"] as? Int)==10007 && (body["message"] as? String)==String(repeating:"original reason ",count:1000))
            }
            let before=try Data(contentsOf:root.appendingPathComponent("classification-"+String(describing:mode)+"/write-ledger.json"))
            let repeated=try await service.reconcileWrite(repo.reference,requestID:append.requestID)
            try check(repeated.state == expected.rawValue && transport.writes == 1)
            try check(try Data(contentsOf:root.appendingPathComponent("classification-"+String(describing:mode)+"/write-ledger.json"))==before)
        }
        print("{\"status\":\"PASS\",\"group\":\"durable_not_dispatched_and_readonly_reconcile\",\"missing_id_creates_nothing\":true,\"historical_unknown_preserved\":true,\"same_id_not_replayed\":true,\"real_keychain\":0,\"real_provider\":0}")
    }
}
