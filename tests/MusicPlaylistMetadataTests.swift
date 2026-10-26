import Foundation
@testable import ARLCredentialOnboarding

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

private final class MetadataMusic: MusicTransport, MusicReadTransport, MusicWriteTransport, @unchecked Sendable {
    enum Mode { case success, lostAfterEffect, lostBeforeEffect, wrongValue, reordered, missingDescription, changingDescription, wrongTarget, incomplete, notDispatched }
    let mode: Mode
    private let lock = NSLock()
    let id = String(repeating: "2", count: 32)
    var title = "Synthetic playlist", writes = 0, reads = 0
    var description: String? = "Old description"
    init(_ mode: Mode) { self.mode = mode }
    func copy(_ secret: CredentialInput) throws -> CredentialInput { try .init(purpose: .neteaseMusic, data: secret.copyBytes(for: .neteaseMusic)) }
    func send(_ secret: CredentialInput, operation: MusicOperation, onLoginURL: @escaping @Sendable (URL) -> Void) async throws -> MusicRuntimeResult {
        .init(state: .sessionPresentUnverified, credential: try copy(secret))
    }
    func sendRead(_ secret: CredentialInput, request: MusicReadRequest) async throws -> MusicReadRuntimeResult {
        try lock.withLock {
            reads += 1
            let desc = mode == .changingDescription && reads >= 3 ? "Changed externally" : description
            let record = mode == .missingDescription ? nil : MusicProviderRecord(fields: ["describe": desc.map(MusicProviderValue.text) ?? .null], omittedAuthenticationFields: [])
            let playlist = MusicReadPlaylist(playlistID: id, name: mode == .wrongTarget ? "Other target" : title, url: nil, trackCount: 2, providerRecord: record)
            var songs = ["1","3"].map { MusicReadSong(songID: String(repeating: $0, count: 32), name: "Synthetic song", url: nil, visible: true) }
            if mode == .reordered && writes > 0 { songs.reverse() }
            let payload: MusicReadPayload
            switch request {
            case .userPlaylists: payload = .init(songs: nil, playlists: [playlist], playlist: nil, complete: true)
            case .playlistDetail:
                if MusicReadPurpose.metadataOnly {
                    let verified=mode != .incomplete && mode != .changingDescription
                    payload = .init(songs:nil,playlists:nil,playlist:playlist,complete:false,metadataVerified:verified ? true:nil)
                } else {payload = .init(songs:songs,playlists:nil,playlist:playlist,complete:mode != .incomplete)}
            default: throw CredentialError.invalidInput
            }
            return .init(result: .init(state: .authorizedRead, session: .present, payload: payload), credential: try copy(secret))
        }
    }
    func sendWrite(_ secret: CredentialInput, request: MusicWriteRequest) async throws -> MusicWriteEffect {
        try lock.withLock {
            writes += 1
            if mode == .notDispatched { return .init(state: .notSubmitted, playlistID: nil, credential: try copy(secret)) }
            if mode == .lostBeforeEffect { throw CredentialError.storageUnavailable }
            if mode != .wrongValue {
                if request.intent == .updatePlaylistName { title = request.value! }
                else if request.intent == .updatePlaylistDescription { description = request.value! }
            }
            if mode == .lostAfterEffect { throw CredentialError.storageUnavailable }
            return .init(state: .submitted, playlistID: id, credential: try copy(secret))
        }
    }
}
@main enum MusicPlaylistMetadataTests {
    static func check(_ value: Bool, _ label: String) { precondition(value, label) }
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        var cases: [String] = []
        let targetID=String(repeating:"a",count:32)
        let metadata:[String:Any]=["playlist":["playlist_id":targetID,"name":"Large playlist","track_count":200001],"complete":false,"metadata_verified":true]
        let raw:[String:Any]=["state":MusicReadState.authorizedRead.rawValue,"session":MusicReadSession.present.rawValue,"payload":metadata]
        let decoded=try MusicReadProtocol.decode(raw,for:.playlistDetail(playlistID:targetID),verification:true,metadataOnly:true)
        check(decoded.payload?.songs==nil && decoded.payload?.complete==false && decoded.payload?.metadataVerified==true,"metadata observation must not invent membership coverage")
        do {_ = try MusicReadProtocol.decode(raw,for:.playlistDetail(playlistID:targetID));preconditionFailure("public read accepted metadata-only reply")}
        catch CredentialError.uncertainLocalState {cases.append("metadata_only_protocol_is_private")}

        for intent in [MusicWriteRequest.Intent.updatePlaylistName, .updatePlaylistDescription] {
            for mode in [MetadataMusic.Mode.success, .lostAfterEffect, .lostBeforeEffect, .wrongValue, .reordered, .wrongTarget, .incomplete, .notDispatched] {
                let repo = try FixtureRepository(), music = MetadataMusic(mode)
                let journal = FileMusicWriteJournal(directory: root.appendingPathComponent(UUID().uuidString))
                let owner = CredentialOnboarding(repository: repo, validator: FixtureValidator(), music: music, writeJournal: journal)
                let req = try MusicWriteRequest(requestID: UUID(), intent: intent, name: "Synthetic playlist", playlistID: music.id, value: intent == .updatePlaylistName ? "New title" : "New\n简介")
                let first = try await owner.consumeWrite(repo.reference, request: req)
                let expected: MusicWriteResult.State
                switch mode {
                case .success, .lostAfterEffect: expected = .verified
                case .wrongTarget: expected = .targetMismatch
                case .incomplete: expected = .incompleteRead
                case .notDispatched: expected = .notDispatched
                case .wrongValue, .lostBeforeEffect: expected = intent == .updatePlaylistName ? .targetMismatch : .readbackFailed
                case .reordered: expected = .verified
                default: expected = .outcomeUnknown
                }
                check(first.state == expected, "\(intent)/\(mode): \(first.state)")
                let count = music.writes
                _ = try await owner.consumeWrite(repo.reference, request: req)
                check(music.writes == count || mode == .notDispatched, "same UUID blindly replayed")
                // not_dispatched retries require an explicit call by the caller; the existing mechanism remains unchanged.
                if first.readbackVerified {
                    let conflict = try MusicWriteRequest(requestID: req.requestID, intent: intent, name: req.name, playlistID: req.playlistID, value: "Different")
                    let result = try await owner.consumeWrite(repo.reference, request: conflict)
                    check(result.state == .requestConflict, "UUID changed value not rejected")
                    let saved = try journal.inspect()
                    check(saved?.schema==3 && saved?.records[req.requestID.uuidString]?.metadataFieldsOnly == true && saved?.records[req.requestID.uuidString]?.contentDigest == nil, "metadata scope must not assert observed membership")
                }
                cases.append("\(intent.rawValue)/\(mode)")
            }
        }
        for mode in [MetadataMusic.Mode.missingDescription, .changingDescription] {
            let repo = try FixtureRepository(), music = MetadataMusic(mode)
            let owner = CredentialOnboarding(repository: repo, validator: FixtureValidator(), music: music, writeJournal: FileMusicWriteJournal(directory: root.appendingPathComponent(UUID().uuidString)))
            let req = try MusicWriteRequest(requestID: UUID(), intent: .updatePlaylistDescription, name: "Synthetic playlist", playlistID: music.id, value: "")
            let result = try await owner.consumeWrite(repo.reference, request: req)
            check(result.state == .incompleteRead && music.writes == 0, "untrusted description dispatched")
            cases.append("description/\(mode)")
        }
        // Actual provider contract: describe:null is an empty description, not an unreadable record.
        for next in ["New description\n简介", ""] {
            let repository = try FixtureRepository(), provider = MetadataMusic(.success)
            provider.description = nil
            let receipts = FileMusicWriteJournal(directory: root.appendingPathComponent(UUID().uuidString))
            let service = CredentialOnboarding(repository: repository, validator: FixtureValidator(), music: provider, writeJournal: receipts)
            let request = try MusicWriteRequest(requestID: UUID(), intent: .updatePlaylistDescription,
                name: "Synthetic playlist", playlistID: provider.id, value: next)
            let result = try await service.consumeWrite(repository.reference, request: request)
            check(result.state == .verified && result.readbackVerified && provider.writes == 1,
                "actual describe:null must dispatch once and verify exact text")
            check(provider.description == next, "provider description not updated")
            let persisted = try receipts.inspect()
            check(persisted?.records[request.requestID.uuidString]?.result?.readbackVerified == true,
                "verified operation not persisted")
            _ = try await service.consumeWrite(repository.reference, request: request)
            check(provider.writes == 1, "verified describe update replayed")
            cases.append(next.isEmpty ? "actual_describe_null_to_empty" : "actual_describe_null_to_text")
        }
        // Persisted UUID identity, empty description, and read-only missing intent.
        let repo = try FixtureRepository(), music = MetadataMusic(.success), directory = root.appendingPathComponent(UUID().uuidString)
        let journal = FileMusicWriteJournal(directory: directory)
        let owner = CredentialOnboarding(repository: repo, validator: FixtureValidator(), music: music, writeJournal: journal)
        let clear = try MusicWriteRequest(requestID: UUID(), intent: .updatePlaylistDescription, name: "Synthetic playlist", playlistID: music.id, value: "")
        check(try await owner.consumeWrite(repo.reference, request: clear).state == .verified, "empty description")
        let reopened = CredentialOnboarding(repository: repo, validator: FixtureValidator(), music: music, writeJournal: FileMusicWriteJournal(directory: directory))
        let query = try MusicWriteRequest(requestID: clear.requestID, intent: clear.intent, name: clear.name, playlistID: clear.playlistID, value: "", reconcileOnly: true)
        check(try await reopened.consumeWrite(repo.reference, request: query).readbackVerified && music.writes == 1, "restart replayed")
        let missing = try MusicWriteRequest(requestID: UUID(), intent: clear.intent, name: clear.name, playlistID: clear.playlistID, value: "", reconcileOnly: true)
        check(try await reopened.consumeWrite(repo.reference, request: missing).state == .outcomeUnknown && music.writes == 1, "readonly reserved")
        cases += ["empty_description", "restart_cached", "missing_reconcile_only"]
        // Guard strict ledger identity against a tampered content digest.
        do {
            try journal.transaction { ledger in
                ledger.records[clear.requestID.uuidString]?.contentDigest = String(repeating: "0", count: 64)
            }
            preconditionFailure("ledger allowed digest mutation")
        } catch CredentialError.uncertainLocalState { cases.append("immutable_digest") }
        // Historical records keep their original membership witness and are not reinterpreted.
        do {
            let repository=try FixtureRepository(),provider=MetadataMusic(.reordered)
            let receipts=FileMusicWriteJournal(directory:root.appendingPathComponent("legacy-membership"))
            let epoch=UUID(),request=try MusicWriteRequest(requestID:UUID(),intent:.updatePlaylistName,name:"Synthetic playlist",playlistID:provider.id,value:"Legacy renamed")
            let original=["1","3"].map {MusicReadSong(songID:String(repeating:$0,count:32),name:"Synthetic song",url:nil,visible:true)}
            let witness=try MusicWriteRequest.contentsDigest(original)
            try receipts.transaction {ledger in
                ledger.epochs[repository.reference.id.uuidString]=epoch
                ledger.records[request.requestID.uuidString] = .init(request:request,reference:repository.reference.id,epoch:epoch,baseline:[provider.id],contentDigest:witness)
            }
            provider.title="Legacy renamed";provider.writes=1
            let service=CredentialOnboarding(repository:repository,validator:FixtureValidator(),music:provider,writeJournal:receipts)
            let result=try await service.consumeWrite(repository.reference,request:request)
            check(result.state == .readbackFailed && provider.writes==1,"legacy membership receipt must retain its original witness without replay")
            check(try receipts.inspect()?.schema==1,"legacy receipt cannot silently migrate to metadata-only semantics")
            cases.append("legacy_membership_witness_preserved")
        }
        for (intent, value) in [(MusicWriteRequest.Intent.updatePlaylistName, "-bad"), (.updatePlaylistDescription, "\u{0}"), (.updatePlaylistDescription, String(repeating: "x", count: 1001))] {
            do { _ = try MusicWriteRequest(requestID: UUID(), intent: intent, name: clear.name, playlistID: clear.playlistID, value: value);preconditionFailure("invalid value") }
            catch CredentialError.invalidInput { cases.append("invalid_value") }
        }
        print(String(data: try JSONSerialization.data(withJSONObject: ["status": "PASS", "cases": cases, "real_writes": 0], options: .sortedKeys), encoding: .utf8)!)
    }
}
