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


private func songID(_ n: Int) -> String { String(format: "%032x", n) }
private final class BatchMusic: MusicTransport, MusicReadTransport, MusicWriteTransport, @unchecked Sendable {
    enum Mode: String, CaseIterable { case success, lostAfter, lostBefore, partial, damagedExisting, incomplete, notDispatched }
    let mode: Mode; let id = songID(9999); private let lock = NSLock()
    var songs: [String]; var tags = ["Old"]; var writes = 0
    var detailTagsAvailable = true, createdTagsAvailable = true, createdTargetAvailable = true, createdReadFails = false, createdComplete = true
    var createdTagsOverride: [String]? = nil
    var postEffectCreatedReads = 0
    init(_ mode: Mode, songs: [String]) { self.mode = mode; self.songs = songs }
    func copy(_ secret: CredentialInput) throws -> CredentialInput { try .init(purpose:.neteaseMusic,data:secret.copyBytes(for:.neteaseMusic)) }
    func send(_ secret: CredentialInput, operation: MusicOperation, onLoginURL: @escaping @Sendable(URL)->Void) async throws -> MusicRuntimeResult { .init(state:.sessionPresentUnverified,credential:try copy(secret)) }
    func sendRead(_ secret: CredentialInput, request: MusicReadRequest) async throws -> MusicReadRuntimeResult {
        try lock.withLock {
            let isDetail: Bool
            if case .playlistDetail = request { isDetail = true } else { isDetail = false }
            let value: MusicProviderValue = isDetail && !detailTagsAvailable || !isDetail && !createdTagsAvailable ? .null : .array((!isDetail ? createdTagsOverride ?? tags : tags).map(MusicProviderValue.text))
            let p = MusicReadPlaylist(playlistID:id,name:"Synthetic playlist",url:nil,trackCount:songs.count,providerRecord:.init(fields:["tags":value],omittedAuthenticationFields:[]))
            let payload: MusicReadPayload
            switch request {
            case .userPlaylists:
                if writes > 0 { postEffectCreatedReads += 1 }
                if writes > 0 && createdReadFails { return .init(result:.init(state:.providerUnavailable,session:.present,payload:nil),credential:try copy(secret)) }
                payload = .init(songs:nil,playlists:writes > 0 && !createdTargetAvailable ? []:[p],playlist:nil,complete:writes > 0 ? createdComplete : true)
            case .playlistDetail: payload = .init(songs:songs.map{.init(songID:$0,name:"Synthetic song",url:nil,visible:true)},playlists:nil,playlist:p,complete:mode != .incomplete)
            default: throw CredentialError.invalidInput
            }
            return .init(result:.init(state:.authorizedRead,session:.present,payload:payload),credential:try copy(secret))
        }
    }
    func sendWrite(_ secret: CredentialInput, request: MusicWriteRequest) async throws -> MusicWriteEffect {
        try lock.withLock {
            writes += 1
            if mode == .notDispatched { return .init(state:.notSubmitted,playlistID:nil,credential:try copy(secret)) }
            if mode == .lostBefore { throw CredentialError.storageUnavailable }
            let wanted = request.songIDs ?? []
            switch request.intent {
            case .updatePlaylistTags: tags = mode == .partial ? ["Wrong"] : request.tags!
            case .addSongs:
                let added = mode == .partial ? Array(wanted.dropLast()) : wanted
                songs += added.filter { !songs.contains($0) }
            case .reorderSongs: songs = mode == .partial ? Array(wanted.reversed()) : wanted
            case .removeSongs:
                let removed = Set(mode == .partial ? Array(wanted.dropLast()) : wanted)
                songs.removeAll { removed.contains($0) }
            default: throw CredentialError.invalidInput
            }
            if mode == .damagedExisting { songs.append(songID(8888)) }
            if mode == .lostAfter { throw CredentialError.storageUnavailable }
            return .init(state:.submitted,playlistID:id,credential:try copy(secret))
        }
    }
}
@main enum MusicPlaylistBatchTests {
    static func main() async throws {
        let root = URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
        var count = 0
        for intent in [MusicWriteRequest.Intent.updatePlaylistTags,.addSongs,.reorderSongs,.removeSongs] {
            let base = intent == .addSongs ? [songID(700),songID(701)] : (1...501).map(songID)
            let wanted = intent == .reorderSongs ? Array(base.reversed()) : (1...500).map(songID)
            for mode in BatchMusic.Mode.allCases {
                let repo=try FixtureRepository(),music=BatchMusic(mode,songs:base)
                let directory=root.appendingPathComponent(UUID().uuidString)
                let journal=FileMusicWriteJournal(directory:directory)
                let owner=CredentialOnboarding(repository:repo,validator:FixtureValidator(),music:music,writeJournal:journal)
                let req=try MusicWriteRequest(requestID:UUID(),intent:intent,name:"Synthetic playlist",playlistID:music.id,songIDs:intent == .updatePlaylistTags ? nil:wanted,tags:intent == .updatePlaylistTags ? ["流行","摇滚"]:nil)
                let first=try await owner.consumeWrite(repo.reference,request:req)
                let expected: MusicWriteResult.State = mode == .incomplete ? .incompleteRead : mode == .notDispatched ? .notDispatched : [.success,.lostAfter].contains(mode) ? .verified : .readbackFailed
                precondition(first.state == expected,"\(intent)/\(mode): \(first.state)")
                let calls=music.writes
                let persisted=try FileMusicWriteJournal(directory:directory).inspect()!
                if mode == .incomplete { precondition(persisted.records[req.requestID.uuidString] == nil) } else { precondition(persisted.records[req.requestID.uuidString]?.request == req) }
                let query=try MusicWriteRequest(requestID:req.requestID,intent:req.intent,name:req.name,playlistID:req.playlistID,songIDs:req.songIDs,tags:req.tags,reconcileOnly:true)
                _=try await owner.consumeWrite(repo.reference,request:query)
                precondition(music.writes == calls,"same UUID effect replay")
                var conflict=req
                conflict=try .init(requestID:req.requestID,intent:intent,name:"Different playlist",playlistID:music.id,songIDs:req.songIDs,tags:req.tags)
                let other=try await owner.consumeWrite(repo.reference,request:conflict)
                if mode != .incomplete { precondition(other.state == .requestConflict) }
                precondition(music.writes == calls)
                count += 1
            }
        }
        for scenario in ["detail_null_created_tags", "lost_after_effect", "created_null", "created_missing", "created_unavailable", "created_mismatch", "contents_changed", "known_detail_conflict", "partial_inventory_target_present"] {
            let mode: BatchMusic.Mode = scenario == "lost_after_effect" ? .lostAfter : scenario == "created_mismatch" || scenario == "known_detail_conflict" ? .partial : scenario == "contents_changed" ? .damagedExisting : .success
            let repo=try FixtureRepository(),music=BatchMusic(mode,songs:[songID(1),songID(3)])
            music.detailTagsAvailable = scenario == "known_detail_conflict"
            music.createdTagsAvailable = scenario != "created_null"
            music.createdTargetAvailable = scenario != "created_missing"
            music.createdReadFails = scenario == "created_unavailable"
            music.createdComplete = scenario != "partial_inventory_target_present"
            if scenario == "known_detail_conflict" { music.createdTagsOverride = ["华语","流行"] }
            let journal=FileMusicWriteJournal(directory:root.appendingPathComponent(UUID().uuidString))
            let owner=CredentialOnboarding(repository:repo,validator:FixtureValidator(),music:music,writeJournal:journal)
            let req=try MusicWriteRequest(requestID:UUID(),intent:.updatePlaylistTags,name:"Synthetic playlist",playlistID:music.id,tags:["华语","流行"])
            let result=try await owner.consumeWrite(repo.reference,request:req)
            let verified=["detail_null_created_tags","lost_after_effect","partial_inventory_target_present"].contains(scenario)
            let expected: MusicWriteResult.State = verified ? .verified : scenario == "created_missing" ? .targetMismatch : .readbackFailed
            precondition(result.state == expected,"tag source \(scenario): \(result.state)")
            if verified { precondition(result.readbackState == "verified_tags_from_created" && result.readbackProviderResult?.fields["tags"] == .array([.text("华语"),.text("流行")])) }
            if scenario == "known_detail_conflict" || scenario == "contents_changed" { precondition(music.postEffectCreatedReads == 0) }
            let calls=music.writes
            _=try await owner.reconcileWrite(repo.reference,requestID:req.requestID)
            precondition(music.writes == calls,"tag reconciliation resent effect")
            count += 1
        }
        // Load an already-submitted, unverified old request and reconcile it
        // through the public service method. The original effect is never sent.
        do {
            let repo=try FixtureRepository(),music=BatchMusic(.success,songs:[songID(1),songID(3)])
            music.detailTagsAvailable=false;music.tags=["华语","流行"]
            let journal=FileMusicWriteJournal(directory:root.appendingPathComponent(UUID().uuidString)),epoch=UUID()
            let req=try MusicWriteRequest(requestID:UUID(),intent:.updatePlaylistTags,name:"Synthetic playlist",playlistID:music.id,tags:["华语","流行"])
            let songs=music.songs.map{MusicReadSong(songID:$0,name:"Synthetic song",url:nil,visible:true)}
            let digest=try MusicWriteRequest.contentsDigest(songs)
            try journal.transaction { ledger in
                ledger.epochs[repo.reference.id.uuidString]=epoch
                ledger.records[req.requestID.uuidString]=MusicWriteRecord(request:req,reference:repo.reference.id,epoch:epoch,baseline:[music.id],contentDigest:digest,effectDisposition:.submitted,returnedPlaylistID:music.id)
            }
            let owner=CredentialOnboarding(repository:repo,validator:FixtureValidator(),music:music,writeJournal:journal)
            let result=try await owner.reconcileWrite(repo.reference,requestID:req.requestID)
            precondition(result.state == "verified" && result.readbackVerified && result.readbackState == "verified_tags_from_created" && music.writes == 0)
            let persisted=try journal.inspect()
            precondition(persisted?.records[req.requestID.uuidString]?.result?.readbackVerified == true)
            _=try await owner.reconcileWrite(repo.reference,requestID:req.requestID);precondition(music.writes == 0)
            count += 1
        }
        let id=songID(9999)
        for intent in [MusicWriteRequest.Intent.addSongs,.reorderSongs,.removeSongs] {
            for ids in [[],[songID(1),songID(1)], ["invalid"]] {
                do { _=try MusicWriteRequest(requestID:UUID(),intent:intent,name:"Synthetic",playlistID:id,songIDs:ids);preconditionFailure("invalid array admitted") } catch CredentialError.invalidInput {}
                count += 1
            }
        }
        // Only remove has a published numerical maximum; add/reorder accept 501.
        for intent in [MusicWriteRequest.Intent.addSongs,.reorderSongs] { _=try MusicWriteRequest(requestID:UUID(),intent:intent,name:"Synthetic",playlistID:id,songIDs:(1...501).map(songID)); count += 1 }
        do { _=try MusicWriteRequest(requestID:UUID(),intent:.removeSongs,name:"Synthetic",playlistID:id,songIDs:(1...501).map(songID)); preconditionFailure("remove501 accepted") } catch CredentialError.invalidInput {}; count += 1
        print("PASS native batch cases=\(count); real network=0 writes=0")
    }
}
