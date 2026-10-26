import Foundation
@testable import ARLCredentialOnboarding

private struct CoverValidator: CredentialValidator {
    func validate(_ secret:CredentialInput,purpose:CredentialPurpose,deadline:ContinuousClock.Instant) async -> ConnectionTestResult { .init(.credentialUnconfirmed) }
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

private struct CoverImages: MusicPlaylistCoverImageLoader {
    func load(_ url:URL) async throws -> Data {
        Data(base64Encoded:"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
    }
}
private final class CoverTransport: MusicReadTransport,MusicPlaylistCoverTransport,MusicWriteTransport,@unchecked Sendable {
    enum Mode: String,CaseIterable { case success,cdnRotation,unknown,mismatch,orderedDrift,preflightChanged,sameResourceDifferentPath,notSubmitted,rejected,readFailed }
    let id=String(repeating:"2",count:32),song=String(repeating:"1",count:32)
    let resource="1099511650000000123",mode:Mode
    let lock=NSLock()
    var writes=0,reads=0
    init(_ mode:Mode){self.mode=mode}
    func copy(_ secret:CredentialInput)throws -> CredentialInput {try .init(purpose:.neteaseMusic,data:secret.copyBytes(for:.neteaseMusic))}
    func sendRead(_ secret:CredentialInput,request:MusicReadRequest) async throws -> MusicReadRuntimeResult {
        try lock.withLock {
            reads+=1
            if mode == .readFailed, writes>0 {return .init(result:.init(state:.providerUnavailable,session:.present,payload:nil),credential:try copy(secret))}
            let changed=writes>0 && mode != .mismatch && mode != .rejected && mode != .notSubmitted
            let value=mode == .preflightChanged && reads>=3 ? "external-custom" : changed ? resource : "109951165474121408"
            let host=mode == .cdnRotation && reads>=3 ? "p1.music.126.net":"p2.music.126.net"
            let folder=mode == .sameResourceDifferentPath && reads>=3 ? "other-cover":"cover"
            let raw=MusicProviderRecord(fields:["coverImgUrl":.text("https://"+host+"/"+folder+"/"+value+".jpg")],omittedAuthenticationFields:[])
            let playlist=MusicReadPlaylist(playlistID:id,name:"Synthetic album",url:nil,trackCount:2,providerRecord:raw)
            let songRaw=MusicProviderRecord(fields:["coverImgUrl":.text("https://p2.music.126.net/album/source.jpg")],omittedAuthenticationFields:[])
            var songs=[MusicReadSong(songID:song,name:"one",url:nil,visible:true,providerRecord:songRaw),
                MusicReadSong(songID:String(repeating:"3",count:32),name:"two",url:nil,visible:true)]
            if mode == .orderedDrift,writes>0 {songs.reverse()}
            let payload:MusicReadPayload
            switch request {
            case .userPlaylists:payload = .init(songs:nil,playlists:[playlist],playlist:nil,complete:true)
            case .playlistDetail(let target):
                guard target==id else {throw CredentialError.invalidInput}
                payload = .init(songs:songs,playlists:nil,playlist:playlist,complete:true)
            default:throw CredentialError.invalidInput
            }
            return .init(result:.init(state:.authorizedRead,session:.present,payload:payload),credential:try copy(secret))
        }
    }
    func sendWrite(_ secret:CredentialInput,request:MusicWriteRequest) async throws -> MusicWriteEffect { preconditionFailure("unexpected legacy effect") }
    func sendCover(_ secret:CredentialInput,request:MusicPlaylistCoverRuntimeRequest) async throws -> MusicPlaylistCoverEffect {
        try lock.withLock {
            precondition(request.playlistID==id && request.sha256.count==64 && request.bytes>0)
            writes+=1
            if mode == .unknown {throw CredentialError.storageUnavailable}
            let response=MusicProviderRecord(fields:["code":.integer(200),"subCode":.integer(mode == .rejected ? 10004:200),
                "data":.object(["message":.text("full synthetic provider result"),"nullValue":.null])],omittedAuthenticationFields:[])
            return .init(state:mode == .notSubmitted ? "not_submitted":mode == .rejected ? "provider_rejected":"submitted",
                credential:try copy(secret),resourceID:mode == .notSubmitted ? nil:resource,providerResponse:response)
        }
    }
}
#if !COVER_MIO_BOUNDARY
@main enum MioPlaylistCoverWriteTests {
    static func check(_ ok:Bool,line:Int = #line){precondition(ok,"assertion \(line)")}
    static func main() async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent(UUID().uuidString)
        for mode in CoverTransport.Mode.allCases {
            let repo=try FixtureRepository(),transport=CoverTransport(mode),directory=root.appendingPathComponent(mode.rawValue)
            let old=FileMusicWriteJournal(directory:directory.appendingPathComponent("epochs"))
            let covers=FileMusicPlaylistCoverJournal(directory:directory.appendingPathComponent("covers"))
            func owner()->CredentialOnboarding {CredentialOnboarding(repository:repo,validator:CoverValidator(),musicReads:transport,musicWrites:transport,
                writeJournal:old,musicCovers:transport,coverJournal:covers,coverImages:CoverImages())}
            let request=try MusicPlaylistCoverRequest(requestID:UUID(),playlistID:transport.id,imageURL:"https://example.test/cover.jpg")
            let result=try await owner().consumeCover(repo.reference,request:request)
            let expected=[.success,.cdnRotation].contains(mode) ? "verified":[.preflightChanged,.sameResourceDifferentPath].contains(mode) ? "preflight_changed":
                mode == .notSubmitted ? "not_dispatched":mode == .rejected ? "provider_rejected":
                mode == .readFailed ? "readback_failed":"outcome_unknown"
            check(result.state==expected);check(result.readbackVerified == ([.success,.cdnRotation].contains(mode)))
            check(transport.writes == ([.preflightChanged,.sameResourceDifferentPath].contains(mode) ? 0:1))
            if ![.preflightChanged,.sameResourceDifferentPath].contains(mode) {
                let count=transport.writes
                let again=try await owner().consumeCover(repo.reference,request:request)
                check(again.state==expected && transport.writes==count)
                check(!again.automaticReplay && !again.newSubmissionAllowed)
                let conflict=try MusicPlaylistCoverRequest(requestID:request.requestID,playlistID:transport.id,imageURL:"https://example.test/other.jpg")
                check(try await owner().consumeCover(repo.reference,request:conflict).state == "request_conflict")
                if mode == .success {
                    let legacy=try MusicWriteRequest(requestID:request.requestID,intent:.createPlaylist,name:"Synthetic legacy")
                    check(try await owner().consumeWrite(repo.reference,request:legacy).state == .requestConflict)
                    let oldID=UUID(),oldRequest=try MusicWriteRequest(requestID:oldID,intent:.createPlaylist,name:"Existing legacy")
                    try old.transaction {ledger in
                        ledger.records[oldID.uuidString]=MusicWriteRecord(request:oldRequest,reference:repo.reference.id,
                            epoch:ledger.epochs[repo.reference.id.uuidString]!,baseline:[])
                    }
                    let clash=try MusicPlaylistCoverRequest(requestID:oldID,playlistID:transport.id,imageURL:"https://example.test/cover.jpg")
                    check(try await owner().consumeCover(repo.reference,request:clash).state == "request_conflict")
                    check(transport.writes==count)
                }
                if mode == .unknown {
                    try old.transaction {ledger in ledger.epochs[repo.reference.id.uuidString]=UUID()}
                    check(try await owner().consumeCover(repo.reference,request:request).state == "account_changed")
                }
            }
            let missing=try MusicPlaylistCoverRequest(requestID:UUID(),playlistID:transport.id,imageURL:"https://example.test/cover.jpg",reconcileOnly:true)
            let count=transport.writes
            check(try await owner().consumeCover(repo.reference,request:missing).state == "record_missing")
            check(transport.writes==count)
        }
        // Ref selection is resolved from this playlist's existing raw song record.
        let repo=try FixtureRepository(),t=CoverTransport(.success),dir=root.appendingPathComponent("reference")
        let owner=CredentialOnboarding(repository:repo,validator:CoverValidator(),musicReads:t,
            writeJournal:FileMusicWriteJournal(directory:dir.appendingPathComponent("epochs")),musicCovers:t,
            coverJournal:FileMusicPlaylistCoverJournal(directory:dir.appendingPathComponent("covers")),coverImages:CoverImages())
        let request=try MusicPlaylistCoverRequest(requestID:UUID(),playlistID:t.id,imageReference:t.song)
        check(try await owner.consumeCover(repo.reference,request:request).state == "verified")
        let missing=try MusicPlaylistCoverRequest(requestID:UUID(),playlistID:t.id,imageReference:String(repeating:"f",count:32))
        check(try await owner.consumeCover(repo.reference,request:missing).state == "image_reference_missing" && t.writes==1)
        print("{\"status\":\"PASS\",\"modes\":10,\"restart_no_replay\":true,\"unknown_not_guessed\":true,\"ordered_membership_checked\":true,\"url_and_ref\":true,\"real_network\":0,\"real_credentials\":0}")
    }
}

#else
@main enum MioPlaylistCoverMioBoundaryTests {
    static func main() throws {
        let list=try MioReadOwnerAdapter.respond(["jsonrpc":"2.0","id":1,"method":"tools/list"],ownerCall:{_,_ in preconditionFailure("catalog accessed owner")})
        let tools=(list["result"] as! [String:Any])["tools"] as! [[String:Any]]
        try validateMioPublishedDescriptors(tools)
        precondition(tools.filter{$0["name"] as? String == MusicPlaylistCoverCapability.name}.count==1)
        var tampered=tools
        let index=tampered.firstIndex{$0["name"] as? String == MusicPlaylistCoverCapability.name}!
        tampered[index]["description"]="different"
        do {try validateMioPublishedDescriptors(tampered);preconditionFailure("tampered descriptor accepted")} catch {}
        let id=UUID().uuidString,playlist=String(repeating:"2",count:32)
        let args:[String:Any]=["request_id":id,"playlist_id":playlist,"image_url":"https://example.test/cover.jpg"]
        let call:[String:Any]=["jsonrpc":"2.0","id":2,"method":"tools/call","params":["name":MusicPlaylistCoverCapability.name,"arguments":args]]
        let body:[String:Any]=["code":200,"data":["docId":NSNumber(value:UInt64(1099511650000000123)),
            "unfamiliar":["nullValue":NSNull(),"longExplanation":String(repeating:"完整业务返回 ",count:1000)]]]
        for state in ["verified","outcome_unknown","provider_rejected"] {
            let value:[String:Any]=["request_id":id,"playlist_id":playlist,"state":state,
                "readback_verified":state=="verified","automatic_replay":false,"new_submission_allowed":false,
                "provider_response":["fields":body,"omitted_authentication_fields":[]],"provider_response_complete":true]
            var count=0
            let reply=try MioReadOwnerAdapter.respond(call,ownerCall:{name,data in
                count+=1;precondition(name==MusicPlaylistCoverCapability.name)
                let forwarded=try OwnerReadJSON.object(data,limit:OwnerReadWire.requestLimit)
                precondition(NSDictionary(dictionary:args).isEqual(to:forwarded))
                return try OwnerReadWire.encode(value,limit:OwnerReadWire.responseLimit)
            })
            precondition(count==1)
            let result=reply["result"] as! [String:Any],structured=result["structuredContent"] as! [String:Any]
            let text=(result["content"] as! [[String:Any]])[0]["text"] as! String
            let decoded=try OwnerReadJSON.object(Data(text.utf8),limit:OwnerReadWire.responseLimit,maximumDepth:32)
            precondition(NSDictionary(dictionary:structured).isEqual(to:decoded))
            precondition(NSDictionary(dictionary:structured["provider_response"] as! [String:Any]).isEqual(to:value["provider_response"] as! [String:Any]))
            precondition(text.contains("1099511650000000123"))
            precondition(result["isError"] as? Bool == (state != "verified"))
        }
        var bad=args;bad["image_ref"]=String(repeating:"3",count:32)
        let rejected=try MioReadOwnerAdapter.respond(["jsonrpc":"2.0","id":3,"method":"tools/call",
            "params":["name":MusicPlaylistCoverCapability.name,"arguments":bad]],ownerCall:{_,_ in preconditionFailure("invalid inputs reached owner")})
        precondition((rejected["result"] as! [String:Any])["isError"] as? Bool == true)
        print("{\"status\":\"PASS\",\"mio_catalog_registered\":true,\"consumer_finite_registry\":true,\"url_no_sha\":true,\"full_text_equals_structured\":true,\"large_integer_preserved\":true,\"real_network\":0}")
    }
}
#endif
