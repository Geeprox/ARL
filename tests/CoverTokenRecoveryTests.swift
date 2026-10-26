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
    enum Mode: String,CaseIterable { case success,unknown,mismatch,orderedDrift,preflightChanged,notSubmitted,rejected,readFailed }
    let id=String(repeating:"2",count:32),song=String(repeating:"1",count:32)
    let resource="1099511650000000123"
    var mode:Mode
    let lock=NSLock()
    var generation=String(repeating:"a",count:64)
    func coverRuntimeGeneration() throws -> String { lock.withLock { generation } }
    var writes=0,reads=0
    var applied=false
    init(_ mode:Mode){self.mode=mode}
    func copy(_ secret:CredentialInput)throws -> CredentialInput {try .init(purpose:.neteaseMusic,data:secret.copyBytes(for:.neteaseMusic))}
    func sendRead(_ secret:CredentialInput,request:MusicReadRequest) async throws -> MusicReadRuntimeResult {
        try lock.withLock {
            reads+=1
            if mode == .readFailed, writes>0 {return .init(result:.init(state:.providerUnavailable,session:.present,payload:nil),credential:try copy(secret))}
            let changed=applied && mode != .mismatch && mode != .rejected && mode != .notSubmitted
            let value=mode == .preflightChanged && reads>=3 ? "external-custom" : changed ? resource : "109951165474121408"
            let raw=MusicProviderRecord(fields:["coverImgUrl":.text("https://p2.music.126.net/cover/"+value+".jpg")],omittedAuthenticationFields:[])
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
            applied = ![.notSubmitted,.rejected].contains(mode)
            let response=MusicProviderRecord(fields:["code":.integer(200),"subCode":.integer(mode == .rejected ? 10004:200),
                "data":.object(["message":.text("full synthetic provider result"),"nullValue":.null])],omittedAuthenticationFields:[])
            return .init(state:mode == .notSubmitted ? "not_submitted":mode == .rejected ? "provider_rejected":"submitted",
                credential:try copy(secret),resourceID:mode == .notSubmitted ? nil:resource,providerResponse:response,
                providerExchange: mode == .notSubmitted ? MusicProviderRecord(fields:[
                    "path":.text("/openapi/whale/nos/upload/token/docid"),"http_status":.integer(200),
                    "failure_stage":.text("provider"),"failure_code":.text("invalid_cover_token_reply"),
                    "cover_token_validation":.object(["boundary":.text("token_reply_before_nos"),"token_accepted":.boolean(false),"cover_update_dispatched":.boolean(false)])],omittedAuthenticationFields:[]) : nil)
        }
    }
}

@main @MainActor enum CoverTokenRecoveryTests {
    static var checks = 0
    @MainActor static func check(_ value: Bool, _ message: String = "", line: Int = #line) {
        checks += 1; precondition(value, "assertion \(line): " + message)
    }
    static func legacy(_ root: URL, _ original: MusicPlaylistCoverRecord, variant: String = "valid") throws {
        guard variant != "missing" else { return }
        let home = root.appendingPathComponent("music-business-v1.noindex")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions:0o700])
        FileManager.default.createFile(atPath: home.appendingPathComponent("business.lock.noindex").path, contents: Data(), attributes: [.posixPermissions:0o600])
        let image = Data(base64Encoded:"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
        let call = UUID().uuidString, foreignCall = UUID().uuidString, id = original.request.requestID.uuidString
        var rows: [[String: Any]] = [
            ["event":"runtime_request","operation":"playlist_cover","arguments":["playlist_id":original.request.playlistID,
                "image_sha256":MusicRuntimeResources.hash(image),"image_bytes":String(image.count),
                "image_path":root.appendingPathComponent("covers/" + id + ".png").path]],
            ["event":"runtime_complete","operation":"playlist_cover","state":"not_submitted"]]
        func frame(_ value: [String: Any]) throws -> [String: Any] {
            let bytes = try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys])
            return ["event":"business_record","record_id":UUID().uuidString,"part":variant == "bad_part" ? 1:0,
                    "parts":1,"sha256":MusicRuntimeResources.hash(bytes),"payload":bytes.base64EncodedString()]
        }
        rows.append(try frame(["event":"http_request","operation":"playlist_cover","method":"POST","path":"/openapi/whale/nos/upload/token/docid"]))
        rows.append(try frame(["event":"http_failure","operation":"playlist_cover","method":"POST","path":"/openapi/whale/nos/upload/token/docid",
            "http_status":200,"failure_stage":"provider","failure_code":"invalid_cover_token_reply"]))
        if variant == "dispatched" { rows.append(try frame(["event":"upload_response","operation":"playlist_cover","path":"/yyimgs/synthetic"])) }
        if variant == "incomplete" { rows.remove(at:1) }
        if ["foreign_cover_call", "missing_call", "invalid_call"].contains(variant) {
            var foreign = try frame(["event":"http_request", "operation":"playlist_cover", "method":"POST",
                "path":"/openapi/music/basic/playlist/cover/update"])
            foreign["fixture_call"] = variant == "missing_call" ? "missing":variant == "invalid_call" ? "invalid":foreignCall
            rows.append(foreign)
        }
        if ["foreign_read_complete", "foreign_read_unfinished", "foreign_read_hidden_update", "foreign_bad_part"].contains(variant) {
            rows.append(["event":"runtime_request", "operation":"playlist_detail", "arguments":["playlist_id":original.request.playlistID], "fixture_call":foreignCall])
            if variant != "foreign_read_unfinished" {
                rows.append(["event":"runtime_complete", "operation":"playlist_detail", "state":"authorized_read", "fixture_call":foreignCall])
            }
            var foreign = try frame(["event":"http_request", "operation":"playlist_detail", "method":"POST",
                "path":variant == "foreign_read_hidden_update" ? "/openapi/music/basic/playlist/cover/update":"/openapi/music/basic/playlist/detail"])
            foreign["fixture_call"] = foreignCall
            if variant == "foreign_bad_part" { foreign["part"] = 1 }
            rows.append(foreign)
        }
        if variant == "owner93_metadata" {
            rows.append(["event":"owner_request", "tool":"mio_netease_playlist_reconcile", "fixture_build":"93"])
            rows.append(["event":"owner_response", "tool":"mio_netease_playlist_reconcile", "fixture_build":"93"])
            rows.append(["event":"owner_request", "tool":"mio_netease_playlist_update_cover", "fixture_build":"94"])
        }
        if ["read_current_build", "cover_current_build"].contains(variant) {
            let op = variant == "read_current_build" ? "playlist_detail":"playlist_cover"
            rows.append(["event":"runtime_request", "operation":op, "fixture_call":foreignCall,"fixture_build":"94"])
            rows.append(["event":"runtime_complete", "operation":op, "state":op == "playlist_detail" ? "authorized_read":"not_submitted", "fixture_call":foreignCall,"fixture_build":"94"])
            var value = try frame(["event":"http_request", "operation":op, "method":"POST", "path":op == "playlist_detail" ? "/openapi/music/basic/playlist/detail":"/openapi/music/basic/playlist/cover/update"])
            value["fixture_call"] = foreignCall;value["fixture_build"] = "94";rows.append(value)
        }
        var data = Data()
        for var row in rows {
            row["request_id"] = id; row["call_id"] = call; row["schema"] = 1; row["build"] = variant == "wrong_build" ? "91":"92"
            if let build = row.removeValue(forKey:"fixture_build") as? String { row["build"] = build }
            if let marker = row.removeValue(forKey:"fixture_call") as? String {
                if marker == "missing" { row.removeValue(forKey:"call_id") }
                else { row["call_id"] = marker }
            }
            data.append(try JSONSerialization.data(withJSONObject:row,options:[.sortedKeys])); data.append(10)
        }
        FileManager.default.createFile(atPath:home.appendingPathComponent("business-1-fixture.jsonl.noindex").path,contents:data,attributes:[.posixPermissions:0o600])
    }
    @MainActor static func proofBoundary(_ root: URL) async throws {
        var cases: [[String: Any]] = []
        let scenarios = CommandLine.arguments[1] == "--owner-build" ? ["valid", "owner93_metadata", "read_current_build", "cover_current_build"] : ["valid", "foreign_cover_call", "missing_call", "invalid_call", "foreign_read_complete", "foreign_read_unfinished", "foreign_read_hidden_update", "foreign_bad_part"]
        for scenario in scenarios {
            let dir = root.appendingPathComponent(UUID().uuidString + "-" + scenario), repo = try FixtureRepository(), t = CoverTransport(.notSubmitted)
            let covers = FileMusicPlaylistCoverJournal(directory:dir.appendingPathComponent("covers"))
            let epochs = FileMusicWriteJournal(directory:dir.appendingPathComponent("epochs")), epoch = UUID()
            try epochs.transaction { $0.epochs[repo.reference.id.uuidString] = epoch }
            let request = try MusicPlaylistCoverRequest(requestID:UUID(),playlistID:t.id,imageURL:"https://example.test/cover.png")
            var record = MusicPlaylistCoverRecord(request:request,reference:repo.reference.id,epoch:epoch,
                baselineCover:"https://p1.music.126.net/cover/109951165474121408.jpg",baselineSongs:[t.song,String(repeating:"3",count:32)])
            record.effectState = "not_submitted"; record.result = MusicPlaylistCoverResult("not_dispatched",request:request)
            try covers.reserve(record); try legacy(dir,record,variant:scenario)
            let ledger = dir.appendingPathComponent("covers/covers.json"), before = try Data(contentsOf:ledger)
            var accepted = false
            do { _ = try covers.recoveryProof(request.requestID,generation:t.generation); accepted = true } catch {}
            let expected = ["valid", "foreign_read_complete", "owner93_metadata", "read_current_build"].contains(scenario)
            check(accepted == expected, scenario + " proof")
            let owner = CredentialOnboarding(repository:repo,validator:CoverValidator(),musicReads:t,musicWrites:t,
                writeJournal:epochs,musicCovers:t,coverJournal:covers,coverImages:CoverImages())
            let result = try await owner.consumeCover(repo.reference,request:request,resumeNotDispatched:true)
            check(result.state == (expected ? "not_dispatched":"recovery_blocked"),scenario + " owner")
            check(t.writes == (expected ? 1:0),scenario + " effects")
            check(try Data(contentsOf:ledger) == before,scenario + " original immutable")
            if !expected { check(try covers.inspectRecovery(request.requestID) == nil,scenario + " no claim") }
            cases.append(["case":scenario,"proof_accepted":accepted,"owner_state":result.state,"simulated_sendCover_calls":t.writes,
                          "claim_created":try covers.inspectRecovery(request.requestID) != nil,"original_ledger_unchanged":true])
        }
        let report: [String: Any] = ["state":"PASS", "cases":cases,"checks":checks,"real_network":0,"real_credentials":0]
        print(String(data:try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys]),encoding:.utf8)!)
    }
    @MainActor static func main() async throws {
        if CommandLine.arguments.count == 3, ["--proof-boundary", "--owner-build"].contains(CommandLine.arguments[1]) {
            try await proofBoundary(URL(fileURLWithPath:CommandLine.arguments[2])); return
        }
        if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--installed-readonly" {
            let home = URL(fileURLWithPath:CommandLine.arguments[2])
            let journal = FileMusicPlaylistCoverJournal(directory:home.appendingPathComponent("music-covers-v1.noindex"))
            let id = UUID(uuidString:"ff5d88ae-0d0d-4b2d-93bd-7e21c344ba2e")!
            let proof = try journal.recoveryProof(id,generation:CommandLine.arguments[3])
            print("{\"state\":\"REAL_ORIGINAL_PREUPLOAD_PROOF_ACCEPTED\",\"image_bytes\":\(proof.imageBytes),\"image_sha256\":\"\(proof.imageSHA256)\",\"business_calls\":0,\"credential_access\":0}")
            return
        }
        let root = URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent(UUID().uuidString)
        let png = Data(base64Encoded:"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
        for scenario in ["valid","unknown","missing","bad_part","dispatched","incomplete","wrong_build","image_changed","account_changed","preflight_changed","crash_claim"] {
            let dir = root.appendingPathComponent(scenario), repo = try FixtureRepository(), t = CoverTransport(.notSubmitted)
            let epochs = FileMusicWriteJournal(directory:dir.appendingPathComponent("epochs"))
            let covers = FileMusicPlaylistCoverJournal(directory:dir.appendingPathComponent("covers"))
            let request = try MusicPlaylistCoverRequest(requestID:UUID(),playlistID:t.id,imageURL:"https://example.test/cover.png")
            let epoch = UUID(); try epochs.transaction { $0.epochs[repo.reference.id.uuidString] = epoch }
            var record = MusicPlaylistCoverRecord(request:request,reference:repo.reference.id,epoch:epoch,
                baselineCover:"https://p1.music.126.net/cover/109951165474121408.jpg",baselineSongs:[t.song,String(repeating:"3",count:32)])
            record.effectState = "not_submitted"; record.result = MusicPlaylistCoverResult("not_dispatched",request:request)
            try covers.reserve(record)
            try legacy(dir,record,variant:scenario)
            let ledger = dir.appendingPathComponent("covers/covers.json"), before = try Data(contentsOf:ledger)
            func owner() -> CredentialOnboarding {
                CredentialOnboarding(repository:repo,validator:CoverValidator(),musicReads:t,musicWrites:t,
                    writeJournal:epochs,musicCovers:t,coverJournal:covers,coverImages:CoverImages())
            }
            check(try await owner().consumeCover(repo.reference,request:request).state == "not_dispatched")
            let query = try MusicPlaylistCoverRequest(requestID:request.requestID,playlistID:t.id,imageURL:request.imageURL!.absoluteString,reconcileOnly:true)
            check(try await owner().consumeCover(repo.reference,request:query,resumeNotDispatched:true).state == "not_dispatched")
            check(t.writes == 0)
            if scenario == "account_changed" { try epochs.transaction { $0.epochs[repo.reference.id.uuidString] = UUID() } }
            if scenario == "image_changed" {
                // Keep bytes valid but bind the immutable proof to another digest.
                let log = dir.appendingPathComponent("music-business-v1.noindex/business-1-fixture.jsonl.noindex")
                var text = try String(contentsOf:log,encoding:.utf8)
                text = text.replacingOccurrences(of:MusicRuntimeResources.hash(png),with:String(repeating:"0",count:64));try text.write(to:log,atomically:false,encoding:.utf8)
            }
            if scenario == "preflight_changed" { t.lock.withLock { t.mode = .preflightChanged; t.reads = 3 } }
            if scenario == "unknown" { t.lock.withLock { t.mode = .unknown } }
            if scenario == "crash_claim" {
                let proof = try covers.recoveryProof(request.requestID,generation:t.generation)
                _ = try covers.stageRecovery(png,id:request.requestID,generation:t.generation,proof:proof)
                var pending = record; pending.result = nil; pending.effectState = nil
                _ = try covers.reserveRecovery(pending,generation:t.generation,proof:proof)
            }
            let result = try await owner().consumeCover(repo.reference,request:request,resumeNotDispatched:true)
            let expected = scenario == "valid" ? "not_dispatched":scenario == "unknown" || scenario == "crash_claim" ? "outcome_unknown":
                scenario == "image_changed" ? "image_changed":scenario == "account_changed" ? "account_changed":scenario == "preflight_changed" ? "preflight_changed":"recovery_blocked"
            check(result.state == expected,scenario + ": " + result.state)
            check(t.writes == (["valid","unknown"].contains(scenario) ? 1:0),scenario)
            let count = t.writes
            _ = try await owner().consumeCover(repo.reference,request:request,resumeNotDispatched:true)
            check(t.writes == count)
            check(try Data(contentsOf:ledger) == before,"original immutable")
            if scenario == "valid" {
                let first = try covers.inspectRecovery(request.requestID)!.attempts[0]
                let encoder = JSONEncoder();encoder.outputFormatting = [.sortedKeys]
                let firstBytes = try encoder.encode(first)
                t.lock.withLock { t.generation = String(repeating:"b",count:64); t.mode = .success }
                check(try await owner().consumeCover(repo.reference,request:request).state == "not_dispatched")
                check(t.writes == 1)
                let next = try await owner().consumeCover(repo.reference,request:request,resumeNotDispatched:true)
                check(next.state == "verified" && next.recoveryAttempt == 2 && next.originalState == "not_dispatched")
                check(t.writes == 2)
                let history = try covers.inspectRecovery(request.requestID)!
                let retained = try encoder.encode(history.attempts[0]); check(history.attempts.count == 2 && retained == firstBytes,"attempt1 immutable")
                _ = try await owner().consumeCover(repo.reference,request:request,resumeNotDispatched:true)
                let after = try Data(contentsOf:ledger); check(t.writes == 2 && after == before)
            }
            if ["unknown","crash_claim"].contains(scenario) {
                t.lock.withLock { t.generation = String(repeating:"b",count:64); t.mode = .success }
                check(try await owner().consumeCover(repo.reference,request:request,resumeNotDispatched:true).state == "outcome_unknown")
                check(t.writes == count,"unknown blocked across versions")
            }
        }
        print("{\"state\":\"PASS\",\"checks\":\(checks),\"real_network\":0,\"real_credentials\":0}")
    }
}
