import Foundation
import CoreFoundation
import Darwin
import OSLog
import CryptoKit
import ARLCredentialOnboarding

/// RuntimeStore owns this server and passes its existing service. No second
/// CredentialOnboarding, repository, Keychain store, or management RPC exists.
final class CredentialReadOwnerServer: @unchecked Sendable {
    typealias AppleCall = @Sendable (OwnerReadRequest) async throws -> Data
    typealias NASCall = @Sendable (OwnerReadRequest) async throws -> Data
    private let stop = OwnerReadStop()
    private let lifecycle = OwnerReadLifecycle()
    private var worker: Task<Void, Never>?
    var snapshot: OwnerReadLifecycle.Snapshot { lifecycle.snapshot }
    private init(service: CredentialOnboarding, appleCall: AppleCall?, nasCall: NASCall?) {
        let stop = self.stop, lifecycle = self.lifecycle
        let work = Task.detached(priority: .utility) {
            let authority: OwnerReadAuthority
            do { authority = try OwnerReadAuthority.load(role: .owner) }
            catch { lifecycle.fail(.identity); stop.cancel(); return }
            do { try Self.run(service: service, appleCall: appleCall, nasCall: nasCall, authority: authority, stop: stop, lifecycle: lifecycle) }
            catch {
                if lifecycle.snapshot.failure == nil {
                    lifecycle.fail(error as? OwnerReadFault == .busy ? .taskPending :
                        error as? OwnerReadFault == .cleanupUnproven ? .cleanupPending : .transport)
                }
                stop.cancel(); lifecycle.cancel()
            }
        }
        worker = work; lifecycle.observeWorker(work)
    }
    static func start(service: CredentialOnboarding, enabled: Bool, appleCall: AppleCall? = nil, nasCall: NASCall? = nil) -> CredentialReadOwnerServer? {
        guard enabled else { return nil }
        return .init(service: service, appleCall: appleCall, nasCall: nasCall)
    }
    /// Explicit local UI recovery only. A timeout does not release either task
    /// or listener ownership; no new owner may start until snapshot.drained.
    func stopAndDrain(seconds: Double = 2) async -> Bool {
        stop.cancel(); lifecycle.cancel(); worker?.cancel()
        let deadline = OwnerReadSocket.now + seconds
        while !snapshot.drained && OwnerReadSocket.now < deadline {
            do { try await Task.sleep(for: .milliseconds(20)) } catch { return false }
        }
        return snapshot.drained
    }
    deinit { stop.cancel(); lifecycle.cancel(); worker?.cancel() }

    private static func run(service: CredentialOnboarding, appleCall: AppleCall?, nasCall: NASCall?, authority: OwnerReadAuthority, stop: OwnerReadStop, lifecycle: OwnerReadLifecycle) throws {
        do { try authority.verifySelf() } catch { lifecycle.fail(.identity); throw error }
        let listener: (fd: Int32, device: dev_t, inode: ino_t)
        do { listener = try OwnerReadSocket.listener() }
        catch {
            let unproven = error as? OwnerReadFault == .cleanupUnproven
            if unproven { lifecycle.listenerClosed(cleanupProven: false) }
            lifecycle.fail(unproven ? .cleanupPending : .listener); throw error
        }
        lifecycle.listening()
        defer {
            let closed = close(listener.fd) == 0
            let removed = OwnerReadSocket.removeOwnSocket(device: listener.device, inode: listener.inode)
            lifecycle.listenerClosed(cleanupProven: closed && removed)
        }
        while !stop.cancelled {
            var poller = pollfd(fd: listener.fd, events: Int16(POLLIN), revents: 0)
            let count = poll(&poller, 1, 50)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw OwnerReadFault.unavailable }
            if count == 0 { continue }
            let fd = accept(listener.fd, nil, nil)
            if fd < 0 && (errno == EAGAIN || errno == EINTR) { continue }
            guard fd >= 0 else { throw OwnerReadFault.unavailable }
            // Serial admission bounds active SDK operations to one; backlog is 1.
            defer { _ = shutdown(fd, SHUT_RDWR); close(fd) }
            do {
                try OwnerReadSocket.configure(fd)
                try serve(fd: fd, service: service, appleCall: appleCall, nasCall: nasCall, authority: authority, stop: stop, lifecycle: lifecycle)
            } catch OwnerReadFault.busy {
                // An SDK task which has not acknowledged cancellation prevents
                // another admission. Close the listener rather than accumulate work.
                throw OwnerReadFault.busy
            } catch OwnerReadFault.cleanupUnproven {
                throw OwnerReadFault.cleanupUnproven
            } catch {
                if lifecycle.snapshot.failure == .cleanupPending { throw OwnerReadFault.cleanupUnproven }
                continue
            }
        }
    }

    private final class Outcome: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Result<Data, OwnerReadFault>?
        func complete(_ value: Result<Data, OwnerReadFault>) { lock.withLock { self.value = value } }
        var result: Result<Data, OwnerReadFault>? { lock.withLock { value } }
    }
    private static func serve(fd: Int32, service: CredentialOnboarding, appleCall: AppleCall?, nasCall: NASCall?, authority: OwnerReadAuthority, stop: OwnerReadStop, lifecycle: OwnerReadLifecycle) throws {
        let peer = try OwnerReadPeer(fd: fd, authority: authority)
        let generation = UUID().uuidString
        let admissionDeadline = OwnerReadSocket.now + 2
        try OwnerReadSocket.writeFrame(OwnerReadWire.hello(generation), fd: fd, limit: 1024,
                                       deadline: admissionDeadline, cancelled: { stop.cancelled })
        let raw = try OwnerReadSocket.readFrame(fd, limit: OwnerReadWire.requestLimit,
                                               deadline: admissionDeadline, cancelled: { stop.cancelled })
        let request = try OwnerReadWire.request(raw, generation: generation)
        let logStarted=ProcessInfo.processInfo.systemUptime
        var logFields:[String:Any] = ["owner_call_id":request.callID,"tool_sha256":ARLConnectionLog.fingerprint(request.tool) ?? ""],logFailed=true
        ARLConnectionLog.production.record("owner","owner_request",logFields)
        defer { logFields["elapsed_ms"]=max(0,Int((ProcessInfo.processInfo.systemUptime-logStarted)*1000));logFields["failed"]=logFailed;ARLConnectionLog.production.record("owner","owner_finished",logFields) }
        try peer.verify()
        guard !stop.cancelled, !OwnerReadSocket.interrupted(fd) else { throw OwnerReadFault.cancelled }
        guard let operation = lifecycle.reserveOperation() else { throw OwnerReadFault.busy }
        let result = Outcome()
        let work = Task.detached(priority: .utility) {
            let started = ProcessInfo.processInfo.systemUptime
            do { result.complete(.success(try await dispatch(request, service: service, appleCall: appleCall, nasCall: nasCall))) }
            catch {
                var fault: OwnerReadFault = error is MusicBusinessLogFailure ? .businessLogUnavailable :
                    (error as? MusicReadRuntimeFailure) == .cleanupUnproven ? .cleanupUnproven :
                    (error as? CredentialError) == .busy ? .busy :
                    error is CancellationError ? .cancelled : (error as? OwnerReadFault) ?? .provider
                do {
                    let body = try JSONSerialization.data(withJSONObject: ["state":"owner_failed","failure_stage":"owner","error":fault.rawValue])
                    try await service.recordMusicBoundary(tool: request.tool, callID: UUID(uuidString:request.callID)!,
                                                          argumentsJSON: request.argumentsJSON, responseJSON: body, elapsedMS: max(0,Int((ProcessInfo.processInfo.systemUptime-started)*1000)))
                } catch { fault = .businessLogUnavailable }
                result.complete(.failure(fault))
            }
        }
        lifecycle.retain(work, for: operation)
        defer { work.cancel() }
        let deadline = OwnerReadSocket.now + OwnerReadWire.seconds(for: request.tool) - 2
        var signatureDeadline = OwnerReadSocket.now
        var interrupted: OwnerReadFault?
        while result.result == nil || !lifecycle.operationEnded(operation) {
            if stop.cancelled || OwnerReadSocket.interrupted(fd) { interrupted = .cancelled; break }
            if OwnerReadSocket.now >= deadline { interrupted = .deadline; break }
            do {
                try peer.checkBirth()
                if OwnerReadSocket.now >= signatureDeadline {
                    try peer.verify(); signatureDeadline = OwnerReadSocket.now + 1
                }
            } catch { interrupted = .identity; break }
            // Also wakes immediately on disconnect/extra frames. No IO occurs on
            // the MainActor, and the SDK task carries structured cancellation.
            var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            _ = poll(&poller, 1, 25)
        }
        if let interrupted {
            work.cancel()
            let drainDeadline = OwnerReadSocket.now + 2
            while !lifecycle.operationEnded(operation) && OwnerReadSocket.now < drainDeadline {
                var p = pollfd(fd: -1, events: 0, revents: 0); _ = poll(&p, 1, 10)
            }
            guard lifecycle.operationEnded(operation), result.result != nil else { throw OwnerReadFault.busy }
            if case .failure(.cleanupUnproven)? = result.result {
                lifecycle.fail(.cleanupPending); throw OwnerReadFault.cleanupUnproven
            }
            throw interrupted // Never send a late result after timeout/cancellation.
        }
        if case .failure(.cleanupUnproven)? = result.result { lifecycle.fail(.cleanupPending) }
        guard !stop.cancelled, !OwnerReadSocket.interrupted(fd), OwnerReadSocket.now < deadline,
              let outcome = result.result else { throw OwnerReadFault.cancelled }
        try peer.verify()
        let reply: Data
        switch outcome {
        case .success(let data): reply = try OwnerReadWire.response(request, payload: data, error: nil)
        case .failure(let error): reply = try OwnerReadWire.response(request, payload: nil, error: error)
        }
        try OwnerReadSocket.writeFrame(reply, fd: fd, limit: OwnerReadWire.responseLimit,
                                       deadline: min(deadline, OwnerReadSocket.now + 1),
                                       cancelled: { stop.cancelled || OwnerReadSocket.interrupted(fd) })
        // The client rechecks LOCAL_PEERTOKEN after reading the reply. Closing
        // immediately can invalidate that audit-token query while the complete
        // reply is still buffered. Keep the authenticated peer alive until the
        // client closes, within the existing deadline and a one-second bound.
        let closeDeadline = min(deadline, OwnerReadSocket.now + 1)
        while !stop.cancelled && !OwnerReadSocket.interrupted(fd) && OwnerReadSocket.now < closeDeadline {
            try peer.checkBirth()
            var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            _ = poll(&poller, 1, 10)
        }
        if case .failure(.cleanupUnproven) = outcome { throw OwnerReadFault.cleanupUnproven }
        if case .success = outcome { logFailed=false }
    }

    // Decoding and projection stay native. The socket cannot select a key,
    // credential reference, purpose, API path or vendor command.
    private static func dispatch(_ request: OwnerReadRequest, service: CredentialOnboarding, appleCall: AppleCall?, nasCall: NASCall?) async throws -> Data {
        if NASCapability.names.contains(request.tool) {
            guard let nasCall else { throw OwnerReadFault.held }
            return try await nasCall(request)
        }
        if AppleCapability.names.contains(request.tool) || AppleProductCapability.names.contains(request.tool) {
            guard let appleCall else { throw OwnerReadFault.held }
            return try await appleCall(request)
        }
        try Task.checkCancellation()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let businessStarted = ProcessInfo.processInfo.systemUptime
        try await service.recordMusicBoundary(tool: request.tool, callID: UUID(uuidString: request.callID)!,
                                              argumentsJSON: request.argumentsJSON, responseJSON: nil, elapsedMS: 0)
        let diagnostic = MusicSearchOwnerDiagnostic(request)
        var diagnosticResponse: Data?
        defer { diagnostic?.finish(diagnosticResponse) }
        let output: Data
        if OwnerReadWire.travel.contains(request.tool) {
            let typed: TravelReadRequest
            do { typed = try TravelReadRequest(toolName: request.tool, argumentsJSON: request.argumentsJSON) }
            catch { throw OwnerReadFault.invalid }
            let snapshot = await service.snapshot(purpose: typed.purpose)
            guard let reference = snapshot.reference else { throw OwnerReadFault.unconfigured }
            try Task.checkCancellation()
            output = try encoder.encode(try await service.consumeRead(reference, request: typed))
        } else if OwnerReadWire.musicLibraryNames.contains(request.tool) {
            let typed = try MusicLibraryReadRequest(toolName:request.tool,argumentsJSON:request.argumentsJSON)
            let snapshot = await service.snapshot(purpose:.neteaseMusic)
            guard let reference=snapshot.reference else {throw OwnerReadFault.unconfigured}
            output = try encoder.encode(try await service.consumeRead(reference,request:MusicReadRequest.library(typed)))
        } else if request.tool == OwnerReadWire.musicAggregate {
            let args = try OwnerReadJSON.object(request.argumentsJSON, limit: OwnerReadWire.requestLimit)
            guard args["offset"] == nil else { throw OwnerReadFault.invalid }
            let query: MusicAggregateQuery
            do { query = try MusicAggregateQuery(arguments: args) } catch { throw OwnerReadFault.invalid }
            let snapshot = await service.snapshot(purpose: .neteaseMusic)
            guard let reference = snapshot.reference else { throw OwnerReadFault.unconfigured }
            output = try await MusicReadRequestContext.$requestID.withValue(UUID(uuidString: request.callID)) {
                try encoder.encode(try await service.aggregateMusicSearch(reference, query: query))
            }
        } else if request.tool == OwnerReadWire.musicCurrentCloudAppend {
            let args = try OwnerReadJSON.object(request.argumentsJSON, limit: OwnerReadWire.requestLimit)
            let parsed = try OwnerReadWire.currentCloudIntent(args)
            let typed = MusicCurrentCloudAppendRequest(supersedesRequestID: UUID(uuidString: parsed.supersedes)!, pcID: parsed.pcID, selectionID: UUID(uuidString: parsed.selection)!)
            let snapshot = await service.snapshot(purpose: .neteaseMusic)
            guard let reference = snapshot.reference else { throw OwnerReadFault.unconfigured }
            output = try encoder.encode(try await service.appendCurrentCloudSong(reference, request: typed))
        } else if request.tool == OwnerReadWire.musicStatus {
            guard try OwnerReadJSON.object(request.argumentsJSON, limit: OwnerReadWire.requestLimit).isEmpty else { throw OwnerReadFault.invalid }
            output = try encoder.encode(try await service.musicConnectionStatus())
        } else if request.tool == OwnerReadWire.musicReconcile || request.tool == OwnerReadWire.musicAppendRecovery {
            let args = try OwnerReadJSON.object(request.argumentsJSON, limit: OwnerReadWire.requestLimit)
            guard Set(args.keys) == ["request_id"], let text = args["request_id"] as? String, text.utf8.count == 36,
                  let id = UUID(uuidString: text) else { throw OwnerReadFault.invalid }
            let snapshot = await service.snapshot(purpose: .neteaseMusic)
            if let reference = snapshot.reference {
                if request.tool == OwnerReadWire.musicAppendRecovery {
                    output = try encoder.encode(try await service.recoverAppendOnce(reference, requestID: id))
                } else {
                    if let cover = try await service.reconcileCover(reference, requestID: id) { output = try encoder.encode(cover) }
                    else { output = try encoder.encode(try await service.reconcileWrite(reference, requestID: id)) }
                }
            } else {
                output = try OwnerReadWire.encode(["state": "requires_setup", "request_id": id.uuidString,
                    "readback_verified": false, "automatic_replay": false, "new_submission_allowed": false,
                    "configuration_ui": "ARL > 服务连接 > 网易云音乐"], limit: OwnerReadWire.responseLimit)
            }
        } else if request.tool == MusicPlaylistCoverCapability.name {
            let args = try OwnerReadJSON.object(request.argumentsJSON, limit: OwnerReadWire.requestLimit)
            let rawID = try MusicPlaylistCoverCapability.validate(args)
            let typed: MusicPlaylistCoverRequest
            do { typed = try .init(requestID: UUID(uuidString: rawID)!, playlistID: args["playlist_id"] as! String,
                imageURL: args["image_url"] as? String, imageReference: args["image_ref"] as? String,
                reconcileOnly: args["reconcile_only"] as? Bool ?? false) } catch { throw OwnerReadFault.invalid }
            let snapshot = await service.snapshot(purpose: .neteaseMusic)
            if let reference = snapshot.reference { output = try encoder.encode(try await service.consumeCover(reference, request: typed, resumeNotDispatched: MusicPlaylistCoverCapability.requestsRecovery(args))) }
            else { output = try OwnerReadWire.encode(["state":"requires_setup","request_id":rawID,"playlist_id":typed.playlistID,
                "readback_verified":false,"automatic_replay":false,"new_submission_allowed":false], limit: OwnerReadWire.responseLimit) }
        } else if OwnerReadWire.musicBatchWrites.contains(request.tool) {
            let args = try OwnerReadJSON.object(request.argumentsJSON, limit: OwnerReadWire.requestLimit)
            let parsed = try OwnerReadWire.batchIntent(request.tool, args)
            let typed: MusicWriteRequest
            do { typed = try .init(requestID: parsed.id, intent: MusicWriteRequest.Intent(rawValue: parsed.intent)!, name: parsed.name, playlistID: parsed.playlist,
                songIDs: parsed.intent == "update_playlist_tags" ? nil : parsed.items, tags: parsed.intent == "update_playlist_tags" ? parsed.items : nil, reconcileOnly: args["reconcile_only"] as? Bool ?? false) }
            catch { throw OwnerReadFault.invalid }
            let snapshot = await service.snapshot(purpose: .neteaseMusic)
            if let reference = snapshot.reference { output = try encoder.encode(try await service.consumeWrite(reference, request: typed)) }
            else { output = try OwnerReadWire.encode(["state":snapshot.state == .localStorageUnavailable ? "owner_unavailable":"requires_setup", "request_id":parsed.id.uuidString,"ready":false,"configuration_ui":"ARL > 服务连接 > 网易云音乐"], limit:OwnerReadWire.responseLimit) }
        } else if OwnerReadWire.musicMetadataWrites.contains(request.tool) {
            let args = try OwnerReadJSON.object(request.argumentsJSON, limit: OwnerReadWire.requestLimit)
            let parsed = try OwnerReadWire.metadataIntent(request.tool, args)
            let typed: MusicWriteRequest
            do { typed = try .init(requestID: parsed.id, intent: parsed.rename ? .updatePlaylistName : .updatePlaylistDescription,
                name: parsed.name, playlistID: parsed.playlist, value: parsed.value, reconcileOnly: args["reconcile_only"] as? Bool ?? false) }
            catch { throw OwnerReadFault.invalid }
            let snapshot = await service.snapshot(purpose: .neteaseMusic)
            if let reference = snapshot.reference { output = try encoder.encode(try await service.consumeWrite(reference, request: typed)) }
            else { output = try OwnerReadWire.encode(["state": snapshot.state == .localStorageUnavailable ? "owner_unavailable" : "requires_setup",
                "request_id": parsed.id.uuidString, "ready": false, "configuration_ui": "ARL > 服务连接 > 网易云音乐"], limit: OwnerReadWire.responseLimit) }
        } else if OwnerReadWire.musicWrites.contains(request.tool) {
            let args = try OwnerReadJSON.object(request.argumentsJSON, limit: OwnerReadWire.requestLimit)
            let create = request.tool == "mio_netease_playlist_create"
            let keys: Set<String> = create ? ["request_id", "intent", "name"] : ["request_id", "intent", "playlist_name", "playlist_id", "song_id"]
            guard keys.isSubset(of: Set(args.keys)), Set(args.keys).isSubset(of: keys.union(["reconcile_only"])),
                  let rawID = args["request_id"] as? String, rawID.utf8.count == 36,
                  let id = UUID(uuidString: rawID), args["intent"] as? String == (create ? "create_playlist" : "append_song"),
                  let name = args[create ? "name" : "playlist_name"] as? String
            else { throw OwnerReadFault.invalid }
            if let value = args["reconcile_only"] {
                guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw OwnerReadFault.invalid }
            }
            let typed: MusicWriteRequest
            do { typed = try .init(requestID: id, intent: create ? .createPlaylist : .appendSong, name: name,
                                  playlistID: args["playlist_id"] as? String, songID: args["song_id"] as? String,
                                  reconcileOnly: (args["reconcile_only"] as? Bool) ?? false) }
            catch { throw OwnerReadFault.invalid }
            let snapshot = await service.snapshot(purpose: .neteaseMusic)
            if let reference = snapshot.reference {
                output = try encoder.encode(try await service.consumeWrite(reference, request: typed))
            } else {
                output = try OwnerReadWire.encode(["state": snapshot.state == .localStorageUnavailable ? "owner_unavailable" : "requires_setup", "request_id": id.uuidString,
                    "ready": false, "configuration_ui": "ARL > 服务连接 > 网易云音乐"], limit: OwnerReadWire.responseLimit)
            }
        } else {
            let args = try OwnerReadJSON.object(request.argumentsJSON, limit: OwnerReadWire.requestLimit)
            let typed: MusicReadRequest
            var pageOffset: Int?
            if ["mio_netease_playlist_list", "mio_netease_playlist_describe"].contains(request.tool), let value = args["offset"] {
                guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                      number.doubleValue.rounded() == number.doubleValue, (0...9_007_199_254_740_991).contains(number.doubleValue)
                else { throw OwnerReadFault.invalid }
                pageOffset = number.intValue
            }
            switch request.tool {
            case "mio_netease_playlist_list":
                guard Set(args.keys).isSubset(of: ["offset"]) else { throw OwnerReadFault.invalid }
                typed = pageOffset.map { .userPlaylistsPage(offset: $0) } ?? .userPlaylists
            case "mio_netease_playlist_describe":
                guard Set(args.keys).isSubset(of: ["playlist_id", "offset"]), let id = args["playlist_id"] as? String,
                      OwnerReadAuthority.matches(id, "^[a-fA-F0-9]{32}$") else { throw OwnerReadFault.invalid }
                typed = pageOffset.map { .playlistDetailPage(playlistID: id, offset: $0) } ?? .playlistDetail(playlistID: id)
            case "mio_netease_song_search":
                guard Set(args.keys).isSubset(of: ["keyword", "offset"]), let text = args["keyword"] as? String,
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 100,
                      !text.hasPrefix("-"), !text.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 })
                else { throw OwnerReadFault.invalid }
                var offset = 0
                if let value = args["offset"] {
                    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                          number.doubleValue >= 0, number.doubleValue <= 9_007_199_254_740_991,
                          number.doubleValue.rounded() == number.doubleValue else { throw OwnerReadFault.invalid }
                    offset = number.intValue
                }
                typed = .search(keyword: text, offset: offset)
            default: throw OwnerReadFault.unsupported
            }
            let snapshot = await service.snapshot(purpose: .neteaseMusic)
            guard let reference = snapshot.reference else { throw OwnerReadFault.unconfigured }
            try Task.checkCancellation()
            output = try await MusicReadRequestContext.$requestID.withValue(UUID(uuidString: request.callID)) {
                try encoder.encode(try await service.consumeRead(reference, request: typed))
            }
        }
        try Task.checkCancellation()
        // The complete encoded owner envelope is checked by OwnerReadWire.response.
        guard output.count <= OwnerReadWire.responseLimit else { throw OwnerReadFault.limit }
        try await service.recordMusicBoundary(tool: request.tool, callID: UUID(uuidString: request.callID)!,
                                              argumentsJSON: request.argumentsJSON, responseJSON: output,
                                              elapsedMS: max(0,Int((ProcessInfo.processInfo.systemUptime-businessStarted)*1000)))
        diagnosticResponse = output
        return output
    }
}

// Fixed fields only: no request values, candidate records, account IDs or auth envelopes.
private struct MusicSearchOwnerDiagnostic {
    private static let logger = Logger(subsystem: "local.arl.control", category: "netease-search-request")
    let id: String
    let tool: String
    let argumentsSHA256: String
    let started: TimeInterval
    init?(_ request: OwnerReadRequest) {
        guard [OwnerReadWire.musicAggregate, "mio_netease_song_search"].contains(request.tool) else { return nil }
        id = request.callID; tool = request.tool
        argumentsSHA256 = SHA256.hash(data: request.argumentsJSON).map { String(format: "%02x", $0) }.joined()
        started = ProcessInfo.processInfo.systemUptime
        emit(event: "started", response: nil)
    }
    func finish(_ data: Data?) { emit(event: data == nil ? "not_completed" : "returned", response: data) }
    private func emit(event: String, response: Data?) {
        var record: [String: Any] = ["schema": 1, "request_id": id, "tool": tool, "event": event,
            "arguments_sha256": argumentsSHA256, "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            "elapsed_ms": max(0, Int((ProcessInfo.processInfo.systemUptime - started) * 1000))]
        if let response {
            record["response_bytes"] = response.count
            if let value = try? JSONSerialization.jsonObject(with: response) as? [String: Any],
               let payload = value["payload"] as? [String: Any] {
                record["returned_songs"] = (payload["songs"] as? [Any])?.count ?? 0
                record["complete"] = payload["complete"] as? Bool ?? false
                record["next_cursor_present"] = ((payload["search"] as? [String: Any])?["next_cursor"] as? String) != nil
            }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return }
        Self.logger.notice("netease_search_request_v1 \(text, privacy: .public)")
    }
}
