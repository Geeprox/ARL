import Foundation
import Darwin

private func check(_ value: Bool, _ message: String) { precondition(value, message) }
private func song(_ id: Int, pc: Int = 42, artist: String = "Expected Artist", album: String = "Expected Album") -> MusicReadSong {
    let key = String(format: "%032x", id)
    return .init(songID: key, name: "Selected Synthetic Song", url: nil, visible: true,
        metadata: .init(artists: [artist], album: album, recordingVersion: nil, durationMS: nil, unknownFields: []),
        privateCloudSong: true, playFlag: true,
        providerRecord: .init(fields: ["id":.text(key.uppercased()), "pcId":.integer(Int64(pc)), "originalId":.integer(Int64(1000+id))], omittedAuthenticationFields: []))
}
private struct Validator: CredentialValidator {
    func validate(_ secret: CredentialInput, purpose: CredentialPurpose, deadline: ContinuousClock.Instant) async -> ConnectionTestResult { .init(.credentialUnconfirmed) }
}
private final class Repository: CredentialRepository, @unchecked Sendable {
    let reference = CredentialReference(purpose: .neteaseMusic)
    private let lock = NSLock()
    private var stored: StoredMetadata
    private let bytes: Data
    init() throws { stored = .init(reference: reference); bytes = try MusicEnvelope.seed(appID: "SYNTHETIC-APP", privateKey: String(repeating: "S", count: 64)) }
    func metadata(_ purpose: CredentialPurpose) throws -> StoredMetadata? { lock.withLock { stored } }
    func lease(_ ref: CredentialReference) throws -> (metadata: StoredMetadata, secret: CredentialInput) {
        try lock.withLock { guard ref == reference else { throw CredentialError.staleReference }; return (stored, try .init(purpose: .neteaseMusic, data: bytes)) }
    }
    func commitLease(_ ref: CredentialReference, input: CredentialInput, result: ConnectionTestResult?, expectedGeneration: UUID) throws -> StoredMetadata {
        defer { input.clear() }
        return try lock.withLock { guard ref == reference, stored.generation == expectedGeneration else { throw CredentialError.staleReference }; stored = .init(reference: reference, state: result?.state ?? .savedUnverified, lastTest: result); return stored }
    }
    func create(_ input: CredentialInput, purpose: CredentialPurpose) throws -> StoredMetadata { input.clear(); throw CredentialError.alreadyConfigured }
    func replace(_ ref: CredentialReference, input: CredentialInput) throws -> StoredMetadata { input.clear(); throw CredentialError.deploymentNotApproved }
    func record(_ ref: CredentialReference, result: ConnectionTestResult, expectedGeneration: UUID) throws -> StoredMetadata { throw CredentialError.deploymentNotApproved }
    func remove(_ ref: CredentialReference) throws { throw CredentialError.deploymentNotApproved }
}
private final class Clock: @unchecked Sendable {
    private let lock = NSLock(); private var value: TimeInterval = 1000
    func now() -> TimeInterval { lock.withLock { value } }
    func advance(_ n: TimeInterval) { lock.withLock { value += n } }
}
private final class Transport: MusicReadTransport, MusicWriteTransport, @unchecked Sendable {
    let playlist = String(repeating: "a", count: 32)
    private let lock = NSLock()
    private var version = 2, wrongIdentity = false, fault = "", members = [4]
    private var clouds: [String?] = [], writes = 0
    func configure(version: Int? = nil, wrongIdentity: Bool? = nil, fault: String? = nil) { lock.withLock { if let version { self.version = version }; if let wrongIdentity { self.wrongIdentity = wrongIdentity }; if let fault { self.fault = fault } } }
    func setMembers(_ values: [Int]) { lock.withLock { members = values } }
    func counts() -> (clouds: [String?], writes: Int) { lock.withLock { (clouds, writes) } }
    private func copy(_ input: CredentialInput) throws -> CredentialInput { try .init(purpose: .neteaseMusic, data: input.copyBytes(for: .neteaseMusic)) }
    func sendRead(_ input: CredentialInput, request: MusicReadRequest) async throws -> MusicReadRuntimeResult {
        try lock.withLock {
            let payload: MusicReadPayload
            switch request {
            case .search: payload = .init(songs: [], playlists: nil, playlist: nil, complete: true, searchPage: .init(offset: 0, limit: 20, total: 0, continuationSupported: true, nextOffset: nil))
            case .cloudSongs(let cursor, let limit):
                clouds.append(cursor); check(cursor == nil || cursor == "synthetic-page-2", "no guessed cursor")
                let rows = cursor == nil ? [song(100, pc: 41)] : [song(version, artist: wrongIdentity ? "Other Artist" : "Expected Artist")]
                payload = .init(songs: rows, playlists: nil, playlist: nil, complete: cursor != nil,
                    cloudPage: .init(limit: limit, total: 2, hasMore: cursor == nil, nextCursor: cursor == nil ? "synthetic-page-2" : nil))
            case .userPlaylists:
                payload = .init(songs: nil, playlists: [.init(playlistID: playlist, name: "Selected playlist", url: nil, trackCount: members.count)], playlist: nil, complete: true)
            case .playlistDetail(let id):
                check(id == playlist, "selected playlist only")
                if fault == "readback" && writes > 0 { return .init(result: .init(state: .providerRejected, session: .present, payload: nil), credential: try copy(input)) }
                payload = .init(songs: members.map { song($0, pc: $0 == 4 ? 99 : 42) }, playlists: nil,
                    playlist: .init(playlistID: playlist, name: "Selected playlist", url: nil, trackCount: members.count), complete: true)
            default: throw CredentialError.invalidInput
            }
            return .init(result: .init(state: .authorizedRead, session: .present, payload: payload), credential: try copy(input))
        }
    }
    func sendWrite(_ input: CredentialInput, request: MusicWriteRequest) async throws -> MusicWriteEffect {
        try lock.withLock {
            writes += 1; check(request.playlistID == playlist && request.songID == String(format: "%032x", version), "fresh selected version only")
            if fault == "not_dispatched" { return .init(state: .notSubmitted, playlistID: nil, credential: try copy(input)) }
            if fault == "lost_before_effect" { throw CredentialError.storageUnavailable }
            members.append(version)
            return .init(state: .submitted, playlistID: playlist, credential: try copy(input))
        }
    }
}
private struct Setup {
    let repo: Repository, transport: Transport, clock: Clock, service: CredentialOnboarding, journal: FileMusicWriteJournal, parent: MusicWriteRequest, original: MusicWriteRecord, directory: URL
}
private final class Counts: @unchecked Sendable {
    private let lock = NSLock(); private var successes = 0
    func succeeded() { lock.withLock { successes += 1 } }
    func value() -> Int { lock.withLock { successes } }
}
@main enum MusicCloudResourceOperationTests {
    private static func setup(_ root: URL, _ label: String) throws -> Setup {
        let repo = try Repository(), transport = Transport(), clock = Clock(), directory = root.appendingPathComponent(label)
        let journal = FileMusicWriteJournal(directory: directory), epoch = UUID()
        let parent = try MusicWriteRequest(requestID: UUID(), intent: .appendSong, name: "Selected playlist", playlistID: transport.playlist, songID: String(format: "%032x", 1))
        let original = MusicWriteRecord(request: parent, reference: repo.reference.id, epoch: epoch, baseline: [transport.playlist], effectDisposition: .submitted)
        try journal.transaction { $0.epochs[repo.reference.id.uuidString] = epoch; $0.records[parent.requestID.uuidString] = original }
        try journal.recoveryTransaction { _, retries in
            var old = MusicWriteRecoveryRecord(request: parent, reference: repo.reference.id, epoch: epoch, reason: .duplicateSafeAppendOnce, decidedAt: Date())
            old.appendDecision = .init(contract: MusicWriteRecoveryRecord.AppendDecision.currentContract, priorAttemptCount: 0, decidedAt: Date()); old.attempts = [original]
            retries.records[parent.requestID.uuidString] = old
        }
        let service = CredentialOnboarding(repository: repo, validator: Validator(), musicReads: transport, musicWrites: transport, writeJournal: journal, musicSearchNow: { clock.now() })
        return .init(repo: repo, transport: transport, clock: clock, service: service, journal: journal, parent: parent, original: original, directory: directory)
    }
    private static func select(_ s: Setup) async throws -> MusicCloudSelection {
        let result = try await s.service.aggregateMusicSearch(s.repo.reference, query: .init(arguments: ["keyword":"Synthetic"]))
        return result.payload.songs.flatMap(\.sourceRecords).compactMap(\.cloudSelection).first { $0.resource.pcID == "42" }!
    }
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let s = try setup(root, "version-change"), selection = try await select(s)
        check(s.transport.counts().clouds.count == 2, "initial normal index scan")
        _ = try await select(s)
        check(s.transport.counts().clouds.count == 2, "ordinary search keeps12h throttle")
        let originalRecovery = try Data(contentsOf: s.directory.appendingPathComponent("recovery-ledger.json"))
        s.transport.configure(version: 3)
        let intent = MusicCurrentCloudAppendRequest(supersedesRequestID: s.parent.requestID, pcID: "42", selectionID: selection.selectionID)
        let result = try await s.service.appendCurrentCloudSong(s.repo.reference, request: intent)
        check(result.state == "verified" && result.resource?.songID == song(3).songID && result.result?.readbackVerified == true, "resolve same file current version and verify")
        check(s.transport.counts().writes == 1 && s.transport.counts().clouds == [nil,"synthetic-page-2","synthetic-page-2"], "only selected page is refreshed")
        let cachedAfterPoint = try await s.service.aggregateMusicSearch(s.repo.reference, query: .init(arguments:["keyword":"Synthetic"]))
        let currentSelections = cachedAfterPoint.payload.songs.flatMap(\.sourceRecords).compactMap(\.cloudSelection).filter { $0.resource.pcID == "42" }
        check(currentSelections.count == 1 && currentSelections[0].resource.songID == song(3).songID && s.transport.counts().clouds.count == 3,"only current version stays write-selectable; point refresh does not reset normal12h scan")
        let graph = try JSONSerialization.jsonObject(with:JSONEncoder().encode(cachedAfterPoint)) as! [String:Any]
        let graphPayload = graph["payload"] as! [String:Any]
        let graphSearch = graphPayload["search"] as! [String:Any]
        let graphStatuses = graphSearch["source_status"] as! [String:Any]
        let cloudStatus = graphStatuses["private_cloud"] as! [String:Any]
        check(cloudStatus["retained_unconfirmed_count"] as? Int == 1,"superseded cached row is explicitly retained unconfirmed")
        let current = try s.journal.inspect()!, child = current.cloudSuccessor(of: s.parent.requestID)!
        check(current.schema == 2 && current.records[s.parent.requestID.uuidString] == s.original, "legacy target/result preserved")
        check(child.cloudResource?.selectedResource.songID == song(2).songID && child.cloudResource?.resource.songID == song(3).songID, "selection and resolved version retained")
        check(try Data(contentsOf: s.directory.appendingPathComponent("recovery-ledger.json")) == originalRecovery, "old exhausted recovery unchanged")
        let restarted = CredentialOnboarding(repository: s.repo, validator: Validator(), musicReads: s.transport, musicWrites: s.transport, writeJournal: s.journal)
        let again = try await restarted.appendCurrentCloudSong(s.repo.reference, request: .init(supersedesRequestID: s.parent.requestID, pcID: "42", selectionID: UUID()))
        check(again.requestID == result.requestID && again.state == "verified" && s.transport.counts().writes == 1, "restart/token changes only reconcile successor")
        _ = try await s.service.recoverAppendOnce(s.repo.reference, requestID: s.parent.requestID)
        _ = try await s.service.recoverAppendOnce(s.repo.reference, requestID: child.request.requestID)
        check(s.transport.counts().writes == 1, "neither old nor new recovery can send again")
        let args: [String:Any] = ["intent":"append_current_cloud_song","supersedes_request_id":s.parent.requestID.uuidString,"pc_id":"42","selection_id":selection.selectionID.uuidString]
        let call: [String:Any] = ["jsonrpc":"2.0","id":1,"method":"tools/call","params":["name":OwnerReadWire.musicCurrentCloudAppend,"arguments":args]]
        let wire = try MioReadOwnerAdapter.respond(call, ownerCall: { name, _ in check(name == OwnerReadWire.musicCurrentCloudAppend,"actual typed entry"); return try JSONEncoder().encode(result) })
        let output = (wire["result"] as! [String:Any])["structuredContent"] as! [String:Any]
        check(output["state"] as? String == "verified" && output["supersedes_request_id"] as? String == s.parent.requestID.uuidString, "Mio lineage projection")
        var numericFlags = try JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as! [String:Any]
        numericFlags["automatic_replay"] = 0
        let malformed = try MioReadOwnerAdapter.respond(call, ownerCall: { _,_ in try JSONSerialization.data(withJSONObject:numericFlags) })
        check(((malformed["result"] as! [String:Any])["structuredContent"] as! [String:Any])["state"] as? String == "outcome_unknown","numeric false cannot replace boolean protocol flag")
        let uncertain = try MioReadOwnerAdapter.respond(call, ownerCall: { _,_ in throw CredentialError.storageUnavailable })
        let u = (uncertain["result"] as! [String:Any])["structuredContent"] as! [String:Any]
        check(u["state"] as? String == "outcome_unknown" && u["supersedes_request_id"] as? String == s.parent.requestID.uuidString && u["automatic_replay"] as? Bool == false, "Mio unknown retains stable parent locator")
        for mode in ["not_dispatched","lost_before_effect","readback"] {
            let item = try setup(root, mode), token = try await select(item)
            item.transport.configure(version: 3, fault: mode)
            let request = MusicCurrentCloudAppendRequest(supersedesRequestID: item.parent.requestID, pcID: "42", selectionID: token.selectionID)
            _ = try await item.service.appendCurrentCloudSong(item.repo.reference, request: request)
            _ = try await item.service.appendCurrentCloudSong(item.repo.reference, request: request)
            let retained = try item.journal.inspect()!.records[item.parent.requestID.uuidString]
            check(item.transport.counts().writes == 1 && retained == item.original, "every uncertain/non-dispatched reservation stays once-only")
        }
        let present = try setup(root,"file-present"), presentToken = try await select(present)
        present.transport.configure(version: 3); present.transport.setMembers([5])
        let noDuplicate = try await present.service.appendCurrentCloudSong(present.repo.reference, request: .init(supersedesRequestID: present.parent.requestID, pcID: "42", selectionID: presentToken.selectionID))
        check(noDuplicate.state == "already_present" && noDuplicate.result?.matchedSongID == song(5).songID && present.transport.counts().writes == 0,"same cloud file already present under another resource is not duplicated")
        let wrongPC = try setup(root,"wrong-pc"), wrongToken = try await select(wrongPC)
        let wrong = try await wrongPC.service.appendCurrentCloudSong(wrongPC.repo.reference, request: .init(supersedesRequestID: wrongPC.parent.requestID, pcID: "99", selectionID: wrongToken.selectionID))
        check(wrong.state == "resource_identity_mismatch" && wrongPC.transport.counts().clouds.count == 2 && wrongPC.transport.counts().writes == 0,"caller stable file binding cannot be changed by a token")
        let expired = try setup(root,"expired"), expiredToken = try await select(expired)
        expired.clock.advance(301)
        let e = try await expired.service.appendCurrentCloudSong(expired.repo.reference, request: .init(supersedesRequestID: expired.parent.requestID, pcID: "42", selectionID: expiredToken.selectionID))
        check(e.state == "selection_expired" && expired.transport.counts().writes == 0 && expired.transport.counts().clouds.count == 2,"expired token no effect or rescan")
        let mismatch = try setup(root,"identity"), mismatchToken = try await select(mismatch)
        mismatch.transport.configure(version: 3, wrongIdentity: true)
        let m = try await mismatch.service.appendCurrentCloudSong(mismatch.repo.reference, request: .init(supersedesRequestID: mismatch.parent.requestID, pcID: "42", selectionID: mismatchToken.selectionID))
        check(m.state == "resource_identity_mismatch" && mismatch.transport.counts().writes == 0,"same-name/different artist rejected")
        let changed = try setup(root,"account"), changedToken = try await select(changed)
        try changed.journal.transaction { $0.epochs[changed.repo.reference.id.uuidString] = UUID() }
        let a = try await changed.service.appendCurrentCloudSong(changed.repo.reference, request: .init(supersedesRequestID: changed.parent.requestID, pcID: "42", selectionID: changedToken.selectionID))
        check(a.state == "account_changed" && changed.transport.counts().writes == 0,"epoch change invalidates selection")
        let race = try setup(root,"race"), successes = Counts()
        let epoch = try race.journal.inspect()!.epochs[race.repo.reference.id.uuidString]!
        DispatchQueue.concurrentPerform(iterations: 2) { i in
            let file = FileMusicWriteJournal(directory: race.directory)
            let resource = MusicCloudResource(song(3+i))!, context = MusicCloudOperationContext(supersedesRequestID: race.parent.requestID, selectedResource: MusicCloudResource(song(2))!, resource: resource, observedAt: 1000)
            do {
                let request = try MusicWriteRequest(requestID: context.operationID(reference: race.repo.reference.id, epoch: epoch), intent: .appendSong, name: race.parent.name, playlistID: race.parent.playlistID, songID: resource.songID)
                try file.transaction { $0.records[request.requestID.uuidString] = .init(request: request, reference: race.repo.reference.id, epoch: epoch, baseline: [], cloudResource: context) }
                successes.succeeded()
            } catch {}
        }
        let raceCount = try race.journal.inspect()!.records.count
        check(successes.value() == 1 && raceCount == 2,"atomic competing versions reserve only one successor")
        let duplicateParent = try MusicWriteRequest(requestID: UUID(), intent: .appendSong, name: race.parent.name, playlistID: race.parent.playlistID, songID: song(20).songID)
        try race.journal.transaction { $0.records[duplicateParent.requestID.uuidString] = .init(request: duplicateParent, reference: race.repo.reference.id, epoch: epoch, baseline: []) }
        let beforeDuplicate = try Data(contentsOf: race.directory.appendingPathComponent("write-ledger.json"))
        let duplicateContext = MusicCloudOperationContext(supersedesRequestID: duplicateParent.requestID, selectedResource: MusicCloudResource(song(2))!, resource: MusicCloudResource(song(30))!, observedAt:1000)
        let duplicateRequest = try MusicWriteRequest(requestID:duplicateContext.operationID(reference:race.repo.reference.id,epoch:epoch),intent:.appendSong,name:race.parent.name,playlistID:race.parent.playlistID,songID:song(30).songID)
        var duplicateRejected = false
        do { try race.journal.transaction { $0.records[duplicateRequest.requestID.uuidString] = .init(request:duplicateRequest,reference:race.repo.reference.id,epoch:epoch,baseline:[],cloudResource:duplicateContext) } } catch { duplicateRejected = true }
        check(duplicateRejected,"same pc/playlist cannot reserve through another parent")
        check(try Data(contentsOf:race.directory.appendingPathComponent("write-ledger.json")) == beforeDuplicate,"rejected reservation leaves ledger intact")
        var downgraded = try JSONSerialization.jsonObject(with:beforeDuplicate) as! [String:Any]; downgraded["schema"] = 1
        try JSONSerialization.data(withJSONObject:downgraded).write(to:race.directory.appendingPathComponent("write-ledger.json"))
        var downgradeRejected = false
        do { _ = try race.journal.inspect() } catch { downgradeRejected = true }
        check(downgradeRejected,"current-resource metadata requires schema2")
        try beforeDuplicate.write(to:race.directory.appendingPathComponent("write-ledger.json"))
        var forged = args; forged["request_id"] = UUID().uuidString
        var callerUUIDRejected = false
        do { _ = try OwnerReadWire.currentCloudIntent(forged) } catch { callerUUIDRejected = true }
        check(callerUUIDRejected,"caller cannot replace operation UUID")
        let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))) as! [String:Any]
        for row in fixture["cases"] as! [[String:Any]] {
            let offset = row["offset"] as! Int, request: MusicReadRequest = offset == 0 ? .playlistDetail(playlistID: String(repeating:"1",count:32)) : .playlistDetailPage(playlistID:String(repeating:"1",count:32),offset:offset)
            let read = try MusicReadProtocol.decode(row["result"] as! [String:Any], for: request, correlationID: UUID(uuidString:"00000000-0000-4000-8000-000000000001"))
            if row["case"] as? String == "empty_zero" { check(read.payload?.complete == true && read.payload?.pagination?.terminalObservations?.count == 2,"native preserves terminal observations without failure") }
        }
        var invalidTerminal = (fixture["cases"] as! [[String:Any]])[0]["result"] as! [String:Any]
        var invalidPayload = invalidTerminal["payload"] as! [String:Any], invalidPagination = invalidPayload["pagination"] as! [String:Any]
        var invalidObservations = invalidPagination["terminal_observations"] as! [[String:Any]], invalidFields = invalidObservations[0]["fields"] as! [String:Any]
        invalidFields["offset"] = 1; invalidObservations[0]["fields"] = invalidFields; invalidPagination["terminal_observations"] = invalidObservations
        invalidPayload["pagination"] = invalidPagination; invalidTerminal["payload"] = invalidPayload
        var falseEndRejected = false
        do { _ = try MusicReadProtocol.decode(invalidTerminal,for:.playlistDetail(playlistID:String(repeating:"1",count:32))) } catch { falseEndRejected = true }
        check(falseEndRejected,"contradictory terminal observation cannot establish complete")
        print("{\"status\":\"PASS\",\"same_pc_resource_update\":true,\"point_page_only\":true,\"search_12h_throttle\":true,\"legacy_and_recovery_preserved\":true,\"restart_and_unknown_no_replay\":true,\"identity_epoch_expiry_gates\":true,\"atomic_successors\":1,\"Mio_projection\":true,\"native_terminal_cases\":6,\"real_network\":0,\"real_credentials\":0}")
    }
}
