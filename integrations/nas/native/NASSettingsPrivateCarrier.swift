import Foundation
import Darwin

// Private carrier bound to the enclosing host's actual registered peer. Task25
// owns the public backend/capture port and all UI semantics. This leaf supplies
// actual cross-language calls/cache, not another public bridge or resolver.
private final class NASControllerReplyWaiter: @unchecked Sendable {
    private let lock = NSLock(), ready = DispatchSemaphore(value: 0)
    private var result: Result<Data, ARLNASFault>?
    func complete(_ value: Result<Data, ARLNASFault>) {
        let signal = lock.withLock { () -> Bool in
            guard result == nil else { return false }; result = value; return true
        }
        if signal { ready.signal() }
    }
    func wait(until deadline: UInt64) throws -> Data {
        guard ready.wait(timeout: DispatchTime(uptimeNanoseconds: deadline)) == .success else {
            throw ARLNASFault.transportTimeout
        }
        return try lock.withLock { try result!.get() }
    }
}

// One reader owns the stream and routes each reply to a waiter belonging to
// this exact channel instance. The writer lock spans only a bounded send,
// never a reply wait. An occupied run cannot hold Stop's capture behind it.
private final class NASControllerChannelState: @unchecked Sendable {
    private let lock = NSLock(), writer = NSLock(), finished = DispatchGroup()
    private let verify: @Sendable () throws -> Void
    private var fd: Int32
    private var closed = false
    private var pending: [String: NASControllerReplyWaiter] = [:]
    init(registeredFD: Int32, verify: @escaping @Sendable () throws -> Void) throws {
        fd = fcntl(registeredFD, F_DUPFD_CLOEXEC, 10); self.verify = verify
        guard fd >= 0 else { throw ARLNASFault.callerRejected }
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { Darwin.close(fd); throw ARLNASFault.transportFailed }
        finished.enter()
        Thread.detachNewThread { [self] in readReplies() }
    }
    func exchange(_ frame: Data) throws -> Data {
        try verify()
        let value = try flatObject(frame, limit: 32768)
        let key = try Self.key(value)
        let waiter = NASControllerReplyWaiter()
        try lock.withLock {
            guard !closed, pending[key] == nil, pending.count < 4 else { throw ARLNASFault.operationInProgress }
            pending[key] = waiter
        }
        let seconds: Double = value["phase"] as? String == "run" ? 8 : 2
        let deadline = try NASBoundedIO.deadline(seconds: seconds)
        do {
            try writer.withLock {
                try verify()
                let sending = lock.withLock { closed ? -1 : fcntl(fd, F_DUPFD_CLOEXEC, 10) }
                guard sending >= 0 else { throw ARLNASFault.transportFailed }
                defer { Darwin.close(sending) }
                try NASBoundedIO.write(frame + Data([10]), to: sending,
                    deadline: min(deadline, try NASBoundedIO.deadline(seconds: 2)), socket: true)
            }
            let raw = try waiter.wait(until: deadline)
            try verify(); return raw
        } catch { stop(); throw error }
    }
    func stop() {
        let waiting = lock.withLock { () -> [NASControllerReplyWaiter] in
            guard !closed else { return [] }; closed = true
            if fd >= 0 { shutdown(fd, SHUT_RDWR) }
            let values = Array(pending.values); pending.removeAll(); return values
        }
        for waiter in waiting { waiter.complete(.failure(.userCancelled)) }
    }
    func join() { _ = finished.wait(timeout: .now() + 1) }
    private static func key(_ value: [String: Any]) throws -> String {
        guard integer(value["schema_version"]) == 1, value["service"] as? String == NASReadScope.service,
              let id = value["request_id"] as? String, UUID(uuidString: id)?.uuidString.lowercased() == id,
              let phase = value["phase"] as? String, ["snapshot", "capture", "run"].contains(phase)
        else { throw ARLNASFault.bindingMismatch }
        return id + ":" + phase
    }
    private func readReplies() {
        defer {
            stop()
            lock.withLock { if fd >= 0 { Darwin.close(fd); fd = -1 } }
            finished.leave()
        }
        var buffer = Data(), bytes = [UInt8](repeating: 0, count: 4096)
        do {
            while !lock.withLock({ closed }) {
                var item = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let status = poll(&item, 1, 100)
                if status == 0 || (status < 0 && errno == EINTR) { continue }
                guard status > 0, item.revents & Int16(POLLIN) != 0 else { throw ARLNASFault.transportFailed }
                let count = Darwin.read(fd, &bytes, bytes.count)
                if count < 0 && [EAGAIN, EINTR].contains(errno) { continue }
                guard count > 0 else { throw ARLNASFault.transportFailed }
                buffer.append(contentsOf: bytes[..<count])
                guard buffer.count <= 65536 else { throw ARLNASFault.bindingMismatch }
                while let newline = buffer.firstIndex(of: 10) {
                    let raw = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
                    try verify()
                    let key = try Self.key(flatObject(raw, limit: 32768))
                    let waiter = lock.withLock { pending.removeValue(forKey: key) }
                    guard let waiter else { throw ARLNASFault.bindingMismatch }
                    try verify(); waiter.complete(.success(raw))
                }
                guard buffer.count <= 32768 else { throw ARLNASFault.bindingMismatch }
            }
        } catch { stop() }
    }
}

final class NASPrivateControllerWire: @unchecked Sendable {
    private let state: NASControllerChannelState
    init(registeredFD: Int32, verify: @escaping @Sendable () throws -> Void) throws {
        state = try NASControllerChannelState(registeredFD: registeredFD, verify: verify)
    }
    func exchange(_ frame: Data) throws -> Data { try state.exchange(frame) }
    func close() { state.stop(); state.join() }
    deinit { state.stop(); state.join() }
}

// Private cache fence only. Actual Stop authority belongs to the bridge's
// captured run revalidation. Capture is side-effect free with respect to this
// fence; a confirmed applied Stop fences only captures preceding that Stop.
struct NASValidStopReplyFence {
    private(set) var lastCapture: UInt64 = 0
    private(set) var cancelledThrough: UInt64 = 0
    mutating func capture() -> UInt64 { lastCapture += 1; return lastCapture }
    func accepts(_ sequence: UInt64) -> Bool {
        sequence > cancelledThrough && sequence <= lastCapture
    }
    mutating func completedStop(_ sequence: UInt64, outcome: ARLNASActionOutcome) {
        guard accepts(sequence), outcome == .applied else { return }
        cancelledThrough = max(cancelledThrough, sequence - 1)
    }
}

enum NASControllerCachePhase: UInt8 { case initialization, capture, run }

// One immutable registered channel owns this cache. Stop cancellation and
// snapshot publication are separate decisions: capture eligibility is never
// proof that an old controller snapshot can replace a newer observed version.
struct NASControllerSnapshotCache {
    private(set) var snapshot: ARLNASSetupSnapshot = .unsupported
    private(set) var operationWatermark: UInt64 = 0
    private var phaseWatermark: NASControllerCachePhase = .initialization
    private var hasPublished = false
    @discardableResult
    mutating func publish(_ candidate: ARLNASSetupSnapshot, operation: UInt64,
                          phase: NASControllerCachePhase) -> Bool {
        guard candidate.revision >= snapshot.revision,
              candidate.currentConfigurationGeneration >= snapshot.currentConfigurationGeneration
        else { return false }
        let advancesVersion = candidate.revision > snapshot.revision
            || candidate.currentConfigurationGeneration > snapshot.currentConfigurationGeneration
        if hasPublished, !advancesVersion {
            guard candidate.configuration == snapshot.configuration,
                  candidate.readScope == snapshot.readScope,
                  operation >= operationWatermark else { return false }
            if operation == operationWatermark {
                guard phase.rawValue >= phaseWatermark.rawValue else { return false }
                if phase == phaseWatermark, candidate != snapshot { return false }
            }
        }
        hasPublished = true  // the unsupported sentinel is not an observed controller version
        // A higher actual version may arrive from an earlier operation. Keep
        // the newer operation watermark so equal-version old phases still lose.
        if operation > operationWatermark {
            operationWatermark = operation; phaseWatermark = phase
        } else if operation == operationWatermark, phase.rawValue > phaseWatermark.rawValue {
            phaseWatermark = phase
        }
        snapshot = candidate
        return true
    }
    @MainActor
    @discardableResult
    mutating func projectAndPublish(_ value: [String: Any], operation: UInt64,
                                   phase: NASControllerCachePhase) throws -> ARLNASSetupSnapshot {
        let current = try NASSettingsPrivateCarrier.project(value)
        publish(current, operation: operation, phase: phase)
        return current
    }
    @MainActor
    mutating func completedReply(_ value: [String: Any], request: ARLNASActionRequest,
                                operation: UInt64, outcome: ARLNASActionOutcome) throws -> ARLNASActionReply {
        let current = try projectAndPublish(value, operation: operation, phase: .run)
        return .init(request: request, outcome: outcome, snapshot: current)
    }
}

@MainActor
final class NASSettingsPrivateCarrier {
    private let wire: NASPrivateControllerWire
    private var cache = NASControllerSnapshotCache()
    private var stopFence = NASValidStopReplyFence()
    init(wire: NASPrivateControllerWire) { self.wire = wire }
    func cachedSnapshot() -> ARLNASSetupSnapshot { cache.snapshot }
    func initializeFromControllerCache() throws {
        let id = UUID().uuidString.lowercased()
        let raw = try wire.exchange(frame(id: id, phase: "snapshot", request: "{}"))
        let value = try reply(raw, id: id, phase: "snapshot", request: "{}")
        guard value["outcome"] as? String == "cached" else { throw ARLNASFault.providerInvalid }
        try cache.projectAndPublish(value, operation: 0, phase: .initialization)
    }
    func boundPort() -> ARLNASBoundControllerPort {
        ARLNASBoundControllerPort(cachedSnapshot: { [weak self] in self?.cachedSnapshot() ?? .unsupported },
            captureAfterClick: { [weak self] request in
                guard let self else { throw ARLNASFault.hostNotConfigured }; return try self.capture(request)
            })
    }
    private func capture(_ request: ARLNASActionRequest) throws -> any ARLNASCapturedControllerAction {
        let sequence = stopFence.capture()  // ordering only, including held/failed captures
        let id = UUID().uuidString.lowercased(), text = try Self.requestText(request)
        let value = try reply(wire.exchange(frame(id: id, phase: "capture", request: text)), id: id, phase: "capture", request: text)
        try cache.projectAndPublish(value, operation: sequence, phase: .capture)
        if let failure = value["failure"] as? String { throw ARLNASControllerResultProjection.fault(failure) }
        guard value["outcome"] as? String == "captured" else { throw ARLNASFault.providerInvalid }
        return NASPrivateCapturedAction(request: request, id: id, text: text, sequence: sequence, owner: self)
    }
    fileprivate func run(_ request: ARLNASActionRequest, id: String, text: String, sequence: UInt64) async -> ARLNASActionReply {
        do {
            let bytes = try frame(id: id, phase: "run", request: text), channel = wire
            guard !Task.isCancelled, stopFence.accepts(sequence) else { throw ARLNASFault.userCancelled }
            let raw = try await Task.detached { try channel.exchange(bytes) }.value
            guard !Task.isCancelled, stopFence.accepts(sequence) else { throw ARLNASFault.userCancelled }
            let value = try reply(raw, id: id, phase: "run", request: text)
            guard let outcome = value["outcome"] as? String else { throw ARLNASFault.providerInvalid }
            let projected = ARLNASControllerResultProjection.outcome(outcome, failure: value["failure"] as? String)
            let exactReply = try cache.completedReply(value, request: request, operation: sequence, outcome: projected)
            // Only the bridge's confirmed valid Stop completion advances the
            // local late-reply fence. Captures issued after this Stop remain
            // eligible; an invalid Stop cannot fence a replacement operation.
            if request.action == .stop, projected == .applied {
                stopFence.completedStop(sequence, outcome: projected)
            }
            // Preserve the actual exact reply even when its old snapshot is
            // ineligible for publication into the channel's current cache.
            return exactReply
        } catch let fault as ARLNASFault {
            return .init(request: request, outcome: .held(fault), snapshot: cache.snapshot)
        } catch {
            return .init(request: request, outcome: .failed(.providerInvalid), snapshot: cache.snapshot)
        }
    }
    private func frame(id: String, phase: String, request: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["schema_version": 1, "service": NASReadScope.service,
            "request_id": id, "phase": phase, "request_json": request], options: [.sortedKeys, .withoutEscapingSlashes])
    }
    private func reply(_ raw: Data, id: String, phase: String, request: String) throws -> [String: Any] {
        let value = try flatObject(raw, limit: 32768)
        guard Set(value.keys) == ["schema_version", "service", "request_id", "phase", "request_json", "outcome", "failure", "snapshot_json"],
              integer(value["schema_version"]) == 1, value["service"] as? String == NASReadScope.service,
              value["request_id"] as? String == id, value["phase"] as? String == phase,
              value["request_json"] as? String == request else { throw ARLNASFault.bindingMismatch }
        return value
    }
    private static func requestText(_ request: ARLNASActionRequest) throws -> String {
        let config = request.configuration
        var scope: Any = NSNull()
        if let read = request.readScope {
            scope = ["source_ref": read.sourceRef.rawValue, "credential_ref": read.credentialRef.rawValue,
                "credential_generation": read.credentialGeneration.rawValue, "config_fingerprint": read.configFingerprint.rawValue,
                "root_descriptor_digest": read.rootDescriptorDigest.rawValue, "config_generation": read.configGeneration] as [String: Any]
        }
        let value: [String: Any] = ["action": request.action.rawValue,
            "expected_snapshot_revision": request.expectedSnapshotRevision,
            "expected_configuration_generation": request.expectedConfigurationGeneration, "read_scope": scope,
            "configuration": ["address": config.address, "port": config.port, "transport": config.transport.rawValue,
                "share": config.share, "root": config.root, "application_scope": config.applicationScope.rawValue,
                "connection_timeout_seconds": config.advanced.connectionTimeoutSeconds,
                "automatic_read_retries": config.advanced.automaticReadRetries,
                "maximum_concurrent_reads": config.advanced.maximumConcurrentReads,
                "require_encryption": config.requireEncryption]]
        return String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
    }
    // Internal for the no-socket fixture to execute the exact production DTO
    // projection plus publication path. This is no new public/wire capability.
    static func project(_ reply: [String: Any]) throws -> ARLNASSetupSnapshot {
        guard let text = reply["snapshot_json"] as? String,
              let value = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let revision = integer(value["revision"]), revision >= 0,
              let generation = integer(value["current_configuration_generation"]), generation >= 0,
              let provider = value["provider"] as? String, let state = ARLNASProviderState(rawValue: provider),
              let avail = value["availability"] as? [String: Any] else { throw ARLNASFault.providerInvalid }
        func admission(_ key: String) throws -> ARLNASAdmission {
            guard let record = avail[key] as? [String: Any], let state = record["state"] as? String else { throw ARLNASFault.providerInvalid }
            if state == "allowed" { return .allowed }
            guard let code = record["fault"] as? String else { throw ARLNASFault.providerInvalid }
            if state == "held" { return .held(ARLNASControllerResultProjection.fault(code)) }
            if state == "unsupported" { return .unsupported(ARLNASControllerResultProjection.fault(code)) }
            throw ARLNASFault.providerInvalid
        }
        func fact(_ key: String) throws -> ARLNASFact {
            guard let record = value[key] as? [String: Any], let state = record["state"] as? String else { throw ARLNASFault.providerInvalid }
            if state == "unknown" { return .unknown }; if state == "verified" { return .verified }
            guard let code = record["fault"] as? String else { throw ARLNASFault.providerInvalid }
            let fault = ARLNASControllerResultProjection.fault(code)
            switch state { case "held": return .held(fault); case "failed": return .failed(fault); case "unsupported": return .unsupported(fault); default: throw ARLNASFault.providerInvalid }
        }
        var configuration: ARLNASConfiguration?
        if let raw = value["configuration"] as? [String: Any] {
            guard let host = raw["address"] as? String, let transport = raw["transport"] as? String,
                  let kind = ARLNASTransport(rawValue: transport), let share = raw["share"] as? String,
                  let root = raw["root"] as? String, let port = integer(raw["port"]),
                  let timeout = integer(raw["connection_timeout_seconds"]), raw["require_encryption"] as? Bool == true,
                  integer(raw["automatic_read_retries"]) == 0, integer(raw["maximum_concurrent_reads"]) == 1,
                  raw["application_scope"] as? String == "read_only" else { throw ARLNASFault.invalidConfiguration }
            configuration = try .init(address: host, transport: kind, share: share, root: root, applicationScope: .readOnly,
                advanced: .init(connectionTimeoutSeconds: Int(timeout)), port: Int(port))
        }
        var scope: ARLNASReadScope?
        if let raw = value["read_scope"] as? [String: Any] {
            guard let source = raw["source_ref"] as? String, let ref = raw["credential_ref"] as? String,
                  let credential = raw["credential_generation"] as? String,
                  let config = raw["config_fingerprint"] as? String, let root = raw["root_descriptor_digest"] as? String,
                  let number = integer(raw["config_generation"]), number > 0 else { throw ARLNASFault.bindingMismatch }
            scope = try .init(sourceRef: .init(source), credentialRef: .init(ref), configFingerprint: .init(config),
                rootDescriptorDigest: .init(root), configGeneration: UInt64(number), credentialGeneration: .init(credential))
        }
        // Held packet never publishes native identity/session/access from a DTO.
        guard state != .available, value["connection_epoch"] is NSNull else { throw ARLNASFault.callerRejected }
        return try .init(revision: UInt64(revision), provider: state,
            availability: .init(saveConfiguration: admission("save_configuration"), saveCredential: admission("save_credential"),
                testConnection: admission("test_connection"), testRead: admission("test_read"), reconnect: admission("reconnect"), stop: admission("stop")),
            configuration: configuration, currentConfigurationGeneration: UInt64(generation), readScope: scope,
            configurationSaved: fact("configuration_saved"), credentialReferenceSaved: fact("credential_reference_saved"),
            credentialAvailable: fact("credential_available"), connected: fact("connected"), readable: fact("readable"), writable: fact("writable"))
    }
}

@MainActor
private final class NASPrivateCapturedAction: ARLNASCapturedControllerAction {
    let request: ARLNASActionRequest
    private let id: String
    private let text: String
    private let sequence: UInt64
    private let owner: NASSettingsPrivateCarrier
    private var used = false
    init(request: ARLNASActionRequest, id: String, text: String, sequence: UInt64, owner: NASSettingsPrivateCarrier) {
        self.request = request; self.id = id; self.text = text; self.sequence = sequence; self.owner = owner
    }
    func run() async -> ARLNASActionReply {
        guard !used else { return .init(request: request, outcome: .held(.manualIntentRequired), snapshot: owner.cachedSnapshot()) }
        used = true; return await owner.run(request, id: id, text: text, sequence: sequence)
    }
}
