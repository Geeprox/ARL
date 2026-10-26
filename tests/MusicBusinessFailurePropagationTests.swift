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
    enum Mode { case auditFailureAfterEffect, notDispatched, success, lostAfterEffect, lostBeforeEffect, loggedOut, incomplete, ambiguousCreate, readFailed, notAdded, incompleteAfterWrite }
    private let lock = NSLock()
    let mode: Mode
    var rejectionCode: Int? = 401
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
            if mode == .notDispatched {
                let body: MusicProviderRecord? = try rejectionCode.map { code in
                    try MusicReadProtocol.providerRecord(["fields":["body":["code":code,"subCode":10007,"msg":String(repeating:"original submission rejection ",count:1000),"data":[["songId":song,"code":501,"msg":"per item rejected"]]]],"omitted_authentication_fields":[]])
                }
                return .init(state:.notSubmitted,playlistID:nil,credential:try copy(secret),providerResult:body)
            }
            if mode == .lostBeforeEffect { throw CredentialError.storageUnavailable }
            if request.intent == .createPlaylist { playlistExists = true } else if ![.readFailed,.notAdded,.incompleteAfterWrite].contains(mode) { hasSong = true }
            if mode == .auditFailureAfterEffect { throw MusicBusinessLogFailure.unavailable }
            if mode == .lostAfterEffect || mode == .ambiguousCreate { throw CredentialError.storageUnavailable }
            return .init(state: .submitted, playlistID: id, credential: try copy(secret))
        }
    }
}
@main enum MusicBusinessFailurePropagationTests {
    static func require(_ value: Bool, _ reason: String) { precondition(value,reason) }
    static func mio(_ result: some Encodable, request: MusicWriteRequest, reconcile: Bool = false) throws -> [String:Any] {
        let bytes=try JSONEncoder().encode(result)
        let args:[String:Any] = reconcile ? ["request_id":request.requestID.uuidString] :
            ["request_id":request.requestID.uuidString,"intent":"append_song","playlist_name":request.name,"playlist_id":request.playlistID!,"song_id":request.songID!]
        let call:[String:Any] = ["jsonrpc":"2.0","id":1,"method":"tools/call","params":["name":reconcile ? OwnerReadWire.musicReconcile : "mio_netease_playlist_append_song","arguments":args]]
        let reply=try MioReadOwnerAdapter.respond(call,ownerCall:{_,_ in bytes})
        let output=reply["result"] as! [String:Any],value=output["structuredContent"] as! [String:Any]
        let text=(output["content"] as! [[String:Any]])[0]["text"] as! String
        require(NSDictionary(dictionary:value).isEqual(to:try OwnerReadJSON.object(Data(text.utf8),limit:OwnerReadWire.responseLimit,maximumDepth:32)),"Mio text/structured mismatch")
        return value
    }
    static func code(_ value:[String:Any]) -> Int? {
        (((value["provider_result"] as? [String:Any])?["fields"] as? [String:Any])?["body"] as? [String:Any])?["code"] as? Int
    }
    static func main() async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
        let repository=try FixtureRepository(),transport=FixtureMusic(.auditFailureAfterEffect,existing:true)
        let journal=FileMusicWriteJournal(directory:root.appendingPathComponent("auditFailureAfterEffect"))
        let boundaryRoot=root.appendingPathComponent("raw-boundary.noindex")
        let businessJournal=MusicBusinessJournal(directory:boundaryRoot,minimumFreeBytes:0)
        let service=CredentialOnboarding(repository:repository,validator:FixtureValidator(),music:transport,writeJournal:journal,businessJournal:businessJournal)
        let boundaryID=UUID(),boundaryCall=UUID()
        let arguments=" { \"request_id\": \""+boundaryID.uuidString+"\", \"value\":987654321098765432109, \"accessToken\":\"SYNTHETIC-RAW-BUSINESS\" }\n"
        let response=" { \"code\":200, \"data\":[2.1234567890123456789], \"msg\":\"SYNTHETIC-RAW-BUSINESS\" }\n"
        try await service.recordMusicBoundary(tool:"mio_netease_playlist_describe",callID:boundaryCall,argumentsJSON:Data(arguments.utf8),responseJSON:nil,elapsedMS:0)
        try await service.recordMusicBoundary(tool:"mio_netease_playlist_describe",callID:boundaryCall,argumentsJSON:Data(arguments.utf8),responseJSON:Data(response.utf8),elapsedMS:12)
        let boundaryFile=try FileManager.default.contentsOfDirectory(at:boundaryRoot,includingPropertiesForKeys:nil).first{$0.lastPathComponent.hasPrefix("business-")}!
        let boundaryRows=try Data(contentsOf:boundaryFile).split(separator:10).map{try JSONSerialization.jsonObject(with:Data($0)) as! [String:Any]}
        require(boundaryRows.count==2 && boundaryRows.allSatisfy{$0["arguments_text"] as? String == arguments && $0["request_id"] as? String == boundaryID.uuidString},"owner arguments rewritten or correlation lost")
        require(boundaryRows[1]["response_text"] as? String == response,"owner response rewritten")
        print("{\"case\":\"raw_local_owner_boundary\",\"PASS\":true,\"exact_arguments_and_response\":true,\"real_credentials\":0,\"real_network\":0}")
        let request=try MusicWriteRequest(requestID:UUID(),intent:.appendSong,name:"Synthetic playlist",playlistID:transport.id,songID:transport.song)
        var logError=false
        do {_=try await service.consumeWrite(repository.reference,request:request)} catch is MusicBusinessLogFailure {logError=true}
        require(logError && transport.writes==1 && transport.reads==3,"log failure must surface without automatic readback or resend")
        let record=try journal.inspect()!.records[request.requestID.uuidString]!
        require(record.result==nil && record.effectDisposition==nil,"unknown reservation must remain pending")
        let before=try Data(contentsOf:root.appendingPathComponent("auditFailureAfterEffect/write-ledger.json"))
        let observed=try await service.consumeRead(repository.reference,request:.playlistDetail(playlistID:transport.id))
        require(observed.payload?.songs?.contains(where:{$0.songID==transport.song})==true,"independent read preserves actual business fact")
        require(try Data(contentsOf:root.appendingPathComponent("auditFailureAfterEffect/write-ledger.json"))==before && transport.writes==1,"read must not rewrite unknown effect or resend")
        let call:[String:Any] = ["jsonrpc":"2.0","id":2,"method":"tools/call","params":["name":"mio_netease_playlist_append_song","arguments":["request_id":request.requestID.uuidString,"intent":"append_song","playlist_name":request.name,"playlist_id":request.playlistID!,"song_id":request.songID!]]]
        let rejected=try MioReadOwnerAdapter.respond(call,ownerCall:{_,_ in throw OwnerReadExplicitRejection(fault:.businessLogUnavailable)})
        let fault=(rejected["result"] as! [String:Any])["structuredContent"] as! [String:Any]
        require(fault["state"] as? String == "outcome_unknown" && (fault["error"] as? [String:Any])?["code"] as? String == "business_log_unavailable","Mio must preserve explicit log fault and uncertain effect")
        require(fault["new_submission_allowed"] as? Bool == false && fault["automatic_replay"] as? Bool == false,"log failure cannot authorize a resend")
        print("{\"case\":\"log_failure_after_effect\",\"PASS\":true,\"business_song_present\":true,\"logging_error_reported\":true,\"unknown_ledger_unchanged\":true,\"writes\":1}")

        let repo=try FixtureRepository(),notSent=FixtureMusic(.notDispatched,existing:true)
        let store=FileMusicWriteJournal(directory:root.appendingPathComponent("notDispatched"))
        let owner=CredentialOnboarding(repository:repo,validator:FixtureValidator(),music:notSent,writeJournal:store)
        let intent=try MusicWriteRequest(requestID:UUID(),intent:.appendSong,name:"Synthetic playlist",playlistID:notSent.id,songID:notSent.song)
        let first=try await owner.consumeWrite(repo.reference,request:intent)
        require(first.state == .notDispatched && first.providerResult != nil,"native DTO lost provider body")
        let original=try store.inspect()!.records[intent.requestID.uuidString]!
        require(first.providerResult==original.providerResult,"native DTO differs from original stored response")
        let firstMio=try mio(first,request:intent)
        require(code(firstMio)==401,"Mio lost original native body")
        let actual=((firstMio["provider_result"] as! [String:Any])["fields"] as! [String:Any])["body"] as! [String:Any]
        require((actual["msg"] as? String)?.count==String(repeating:"original submission rejection ",count:1000).count && (actual["data"] as? [[String:Any]])?.first?["msg"] as? String == "per item rejected","full text/per-song fields lost")
        let query=try await owner.reconcileWrite(repo.reference,requestID:intent.requestID)
        require(code(try mio(query,request:intent,reconcile:true))==401,"original reconciliation lost stored body")
        let readonly=try MusicWriteRequest(requestID:intent.requestID,intent:intent.intent,name:intent.name,playlistID:intent.playlistID,songID:intent.songID,reconcileOnly:true)
        require(code(try mio(try await owner.consumeWrite(repo.reference,request:readonly),request:intent))==401 && notSent.writes==1,"readonly original lost body or resent")
        notSent.rejectionCode=402
        let latest=try await owner.consumeWrite(repo.reference,request:intent)
        require(code(try mio(latest,request:intent))==402 && notSent.writes==2,"latest explicit non-dispatch lost body")
        let latestQuery=try await owner.reconcileWrite(repo.reference,requestID:intent.requestID)
        require(code(try mio(latestQuery,request:intent,reconcile:true))==402,"recovery query fell back to stale original body")
        notSent.rejectionCode=nil
        _=try await owner.consumeWrite(repo.reference,request:intent)
        let emptyLatest=try await owner.reconcileWrite(repo.reference,requestID:intent.requestID)
        require(emptyLatest.providerResult==nil && notSent.writes==3,"missing latest body must not inherit historical reason")
        require(try store.inspect()!.records[intent.requestID.uuidString]!.providerResult==original.providerResult,"recovery changed original body")
        print("{\"case\":\"native_DTO_to_Mio_not_dispatched\",\"PASS\":true,\"original_and_latest_body_preserved\":true,\"no_stale_fallback\":true,\"real_network\":0,\"real_credentials\":0}")
    }
}
