import Foundation
import Darwin
import CryptoKit
import CoreFoundation

public enum MusicOperation: String, Sendable { case prepare, status, login }
/// Finite login-only diagnostics, never child output or provider error text.
enum MusicLoginRuntimeFailure: Error { case expired, runtimeExited }
struct MusicRuntimeResult: Sendable {
    let state: ConnectionState
    let credential: CredentialInput
    let readResult: MusicReadResult?
    let coverEffect: MusicPlaylistCoverEffect?
    let writeEffect: MusicWriteEffect?
    init(state: ConnectionState, credential: CredentialInput, readResult: MusicReadResult? = nil, writeEffect: MusicWriteEffect? = nil, coverEffect: MusicPlaylistCoverEffect? = nil) {
        self.state = state; self.credential = credential; self.readResult = readResult; self.writeEffect = writeEffect; self.coverEffect = coverEffect
    }
}
protocol MusicTransport: Sendable {
    func send(_ secret: CredentialInput, operation: MusicOperation,
              onLoginURL: @escaping @Sendable (URL) -> Void) async throws -> MusicRuntimeResult
}
private final class MusicCleanupTicket { var reserved = false; var reaped = false }
private final class MusicCancellation: @unchecked Sendable {
    private let lock = NSLock(); private var value = false
    func cancel() { lock.withLock { value = true } }
    var cancelled: Bool { lock.withLock { value } }
}

/// Signed inventory is the single size/hash source for the consumed resources.
/// This reader never starts a process or accesses a credential.
enum MusicRuntimeResources {
    static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let value = Int(number.stringValue), value >= 0 else { return nil }
        return value
    }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func validHash(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    static func directory(_ path: String) throws -> Int32 {
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw CredentialError.identityMismatch }
        do {
            for part in path.split(separator: "/") {
                guard part != ".", part != ".." else { throw CredentialError.identityMismatch }
                let next = openat(fd, String(part), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw CredentialError.identityMismatch }
                close(fd); fd = next
            }
            return fd
        } catch { close(fd); throw error }
    }
    static func read(root: URL, relative: String, bytes: Int, mode: Int? = nil) throws -> Data {
        guard bytes > 0, !relative.hasPrefix("/"), !relative.contains("\0"),
              relative.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else { throw CredentialError.identityMismatch }
        let parts = relative.split(separator: "/").map(String.init)
        var parent = try directory(root.path)
        defer { close(parent) }
        for part in parts.dropLast() {
            let next = openat(parent, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw CredentialError.identityMismatch }
            close(parent); parent = next
        }
        let name = parts.last!
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw CredentialError.identityMismatch }
        defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_size == off_t(bytes), mode.map({ Int(before.st_mode & 0o7777) == $0 }) ?? true
        else { throw CredentialError.identityMismatch }
        var data = Data(), buffer = [UInt8](repeating: 0, count: min(bytes, 65536))
        while data.count < bytes {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!, min($0.count, bytes - data.count)) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw CredentialError.identityMismatch }
            data.append(contentsOf: buffer.prefix(count))
        }
        var extra: UInt8 = 0
        var tail: Int
        repeat { tail = Darwin.read(fd, &extra, 1) } while tail < 0 && errno == EINTR
        var after = stat(), linked = stat()
        guard tail == 0, fstat(fd, &after) == 0, fstatat(parent, name, &linked, AT_SYMLINK_NOFOLLOW) == 0,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size, before.st_mode == after.st_mode,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
              linked.st_dev == after.st_dev, linked.st_ino == after.st_ino, linked.st_mode == after.st_mode
        else { throw CredentialError.identityMismatch }
        return data
    }
    static func verify(bundle: Bundle) throws -> [String: [String: Any]] {
        guard let root = bundle.resourceURL?.appendingPathComponent("ServiceRuntime"),
              let seal = bundle.object(forInfoDictionaryKey: "ARLServiceRuntimeManifestSHA256") as? String, validHash(seal),
              let bytes = integer(bundle.object(forInfoDictionaryKey: "ARLServiceRuntimeManifestBytes")), bytes > 0
        else { throw CredentialError.deploymentNotApproved }
        let raw = try read(root: root, relative: "inventory.json", bytes: bytes)
        guard hash(raw) == seal else { throw CredentialError.identityMismatch }
        let object = try MusicStrictJSON.object(raw, limit: bytes)
        guard let manifest = object as? [String: [String: Any]], !manifest.isEmpty else { throw CredentialError.identityMismatch }
        for (name, row) in manifest {
            guard !name.hasPrefix("/"), !name.contains("\0"),
                  name.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                  Set(row.keys) == ["bytes", "sha256", "mode"], let size = integer(row["bytes"]),
                  let mode = integer(row["mode"]), mode <= 0o777, mode & 0o222 == 0,
                  let digest = row["sha256"] as? String, validHash(digest), size >= 0
            else { throw CredentialError.identityMismatch }
        }
        for name in ["Runtime/node", "NetEase/dist/index.js", "Bridge/netease_bridge.cjs"] {
            _ = try verified(root: root, name: name, manifest: manifest)
        }
        return manifest
    }
    static func verified(root: URL, name: String, manifest: [String: [String: Any]]) throws -> Data {
        guard let row = manifest[name], let bytes = integer(row["bytes"]), bytes > 0,
              let mode = integer(row["mode"]), let digest = row["sha256"] as? String,
              name != "Runtime/node" || mode == 0o555 else { throw CredentialError.identityMismatch }
        let raw = try read(root: root, relative: name, bytes: bytes, mode: mode)
        guard hash(raw) == digest else { throw CredentialError.identityMismatch }
        return raw
    }
}

/// Only the signed native owner can lease a Keychain value to this private pipe.
/// The runtime receives no user HOME, inherited environment, credential argv or
/// generic command. The returned secret envelope never crosses a public API.
struct MusicRuntimeClient: MusicTransport, MusicReadTransport, MusicWriteTransport, MusicPlaylistCoverTransport, MusicProcessBarrier {
    let gate: any DeploymentGate
    let bundleURL: URL
    var businessJournal: MusicBusinessJournal? = nil
    // Internal fixture seams; the signed owner uses the shared owner/system reader.
    var processOwner: MusicReadProcessOwner = .shared
    var processIdentity: @Sendable (pid_t) -> proc_bsdinfo? = { MusicReadSystemIdentity.read($0) }
    var processSignalIdentity: @Sendable (pid_t) -> proc_bsdinfo? = { MusicReadSystemIdentity.read($0) }
    var readTimeout: TimeInterval = 45
    #if ARL_OWNER_FIXTURE
    var fixtureBeforeFirstWrite: @Sendable () -> Void = {}
    var fixtureScenario: @Sendable (String) -> String? = { _ in nil }
    #endif
    func cleanupStatus() -> MusicCleanupStatus { processOwner.status() }
    private func executeWithCleanup(_ secret: CredentialInput, operation: MusicOperation, readRequest: MusicReadRequest? = nil, writeRequest: MusicWriteRequest? = nil, coverRequest: MusicPlaylistCoverRuntimeRequest? = nil,
                                    cancellation: MusicCancellation, onLoginURL: @escaping @Sendable (URL) -> Void) throws -> MusicRuntimeResult {
        let trace=MusicDiagnostics.current ?? MusicDiagnosticTrace()
        return try MusicDiagnostics.$current.withValue(trace) {
        let ticket = MusicCleanupTicket()
        do {
            let reply = try execute(secret, operation: operation, readRequest: readRequest, writeRequest: writeRequest, coverRequest: coverRequest, cancellation: cancellation, ticket: ticket, onLoginURL: onLoginURL)
            guard ticket.reaped else { reply.credential.clear(); throw MusicReadRuntimeFailure.cleanupUnproven }
            return reply
        } catch {
            if ticket.reserved && !ticket.reaped { trace.record(.bridge,.cleanup_unproven);throw MusicReadRuntimeFailure.cleanupUnproven }
            if operation == .login,readRequest==nil,writeRequest==nil,coverRequest==nil {trace.loginRuntimeFailed(error)}
            else if trace.lastFailure==nil { trace.fail(error,phase:.bridge) }
            if operation == .login,readRequest==nil,writeRequest==nil,coverRequest==nil,!(error is CancellationError),
               error as? MusicLoginRuntimeFailure != .expired,error as? TransportFailure != .timeout,let detail=trace.lastFailure {
                throw MusicDiagnosticFailure(diagnostic:detail)
            }
            throw error
        }
        }
    }
    func send(_ secret: CredentialInput, operation: MusicOperation,
              onLoginURL: @escaping @Sendable (URL) -> Void) async throws -> MusicRuntimeResult {
        let cancellation = MusicCancellation()
        let trace=MusicDiagnostics.current
        return try await withTaskCancellationHandler {
            try await Task.detached {
                try MusicDiagnostics.$current.withValue(trace) {
                    try executeWithCleanup(secret, operation: operation, cancellation: cancellation, onLoginURL: onLoginURL)
                }
            }.value
        } onCancel: { cancellation.cancel() }
    }
    func sendRead(_ owned: CredentialInput, request: MusicReadRequest) async throws -> MusicReadRuntimeResult {
        try request.validate()
        let cancellation = MusicCancellation()
        let trace=MusicDiagnostics.current ?? MusicDiagnosticTrace(requestID: MusicReadRequestContext.requestID)
        let budget=MusicSearchReadDeadline.current
        let verification=MusicReadPurpose.verification
        return try await withTaskCancellationHandler {
            try await Task.detached {
                try MusicDiagnostics.$current.withValue(trace) {
                let reply = try MusicReadPurpose.$verification.withValue(verification) {
                try MusicSearchReadDeadline.$current.withValue(budget) {
                    try executeWithCleanup(owned, operation: .status, readRequest: request, cancellation: cancellation, onLoginURL: { _ in })
                } }
                guard let result = reply.readResult else { reply.credential.clear(); throw CredentialError.uncertainLocalState }
                return MusicReadRuntimeResult(result: result, credential: reply.credential)
                }
            }.value
        } onCancel: { cancellation.cancel() }
    }
    func sendWrite(_ owned: CredentialInput, request: MusicWriteRequest) async throws -> MusicWriteEffect {
        try request.validate()
        guard !request.reconcileOnly else { throw CredentialError.invalidInput }
        let cancellation = MusicCancellation()
        let trace = MusicDiagnostics.current
        return try await withTaskCancellationHandler {
            try await Task.detached {
                try MusicDiagnostics.$current.withValue(trace) {
                let reply = try executeWithCleanup(owned, operation: .status, writeRequest: request, cancellation: cancellation, onLoginURL: { _ in })
                guard let effect = reply.writeEffect else { reply.credential.clear(); throw CredentialError.uncertainLocalState }
                return effect
                }
            }.value
        } onCancel: { cancellation.cancel() }
    }
    func coverRuntimeGeneration() throws -> String {
        try gate.verify()
        guard let bundle = Bundle(url: bundleURL),
              let digest = try MusicRuntimeResources.verify(bundle: bundle)["Bridge/netease_bridge.cjs"]?["sha256"] as? String,
              MusicRuntimeResources.validHash(digest) else { throw CredentialError.identityMismatch }
        return digest
    }
    func sendCover(_ secret: CredentialInput, request: MusicPlaylistCoverRuntimeRequest) async throws -> MusicPlaylistCoverEffect {
        let cancellation = MusicCancellation(), trace = MusicDiagnostics.current
        return try await withTaskCancellationHandler {
            try await Task.detached {
                try MusicDiagnostics.$current.withValue(trace) {
                    let reply = try executeWithCleanup(secret, operation: .status, coverRequest: request, cancellation: cancellation, onLoginURL: { _ in })
                    guard let effect = reply.coverEffect else { reply.credential.clear(); throw CredentialError.uncertainLocalState }
                    return effect
                }
            }.value
        } onCancel: { cancellation.cancel() }
    }
    private func execute(_ secret: CredentialInput, operation: MusicOperation, readRequest: MusicReadRequest? = nil, writeRequest: MusicWriteRequest? = nil, coverRequest: MusicPlaylistCoverRuntimeRequest? = nil, cancellation: MusicCancellation, ticket: MusicCleanupTicket,
                         onLoginURL: @escaping @Sendable (URL) -> Void) throws -> MusicRuntimeResult {
        try gate.verify()
        if readRequest != nil, let budget = MusicSearchReadDeadline.current,
           ProcessInfo.processInfo.systemUptime >= budget { throw TransportFailure.timeout }
        guard secret.purpose == .neteaseMusic, let bundle = Bundle(url: bundleURL), let resources = bundle.resourceURL
        else { throw CredentialError.deploymentNotApproved }
        let root = resources.appendingPathComponent("ServiceRuntime")
        let manifest = try MusicRuntimeResources.verify(bundle: bundle)
        let callID = (MusicDiagnostics.current?.id ?? UUID()).uuidString
        let businessStarted = ProcessInfo.processInfo.systemUptime
        var bytes = try secret.copyBytes(for: .neteaseMusic)
        defer { bytes.resetBytes(in: 0..<bytes.count) }
        var request: [String: Any] = ["schema":1,"operation":(coverRequest == nil ? (writeRequest?.operation ?? readRequest?.operation ?? operation.rawValue) : "playlist_cover"),"call_id":callID,
                                     "credential":bytes.base64EncodedString(),"network_allowed":operation != .prepare]
        if let readRequest {
            try MusicEnvelope.validate(bytes, requireOfficial: true)
            request["arguments"] = readRequest.arguments
            if MusicReadPurpose.verification {
                var arguments = readRequest.arguments
                arguments["verification"] = "true"
                request["arguments"] = arguments
            }
        }
        if let writeRequest {
            try MusicEnvelope.validate(bytes, requireOfficial: true)
            request["arguments"] = writeRequest.arguments
        }
        if let coverRequest {
            try MusicEnvelope.validate(bytes, requireOfficial: true)
            guard MusicReadProtocol.validID(coverRequest.playlistID), coverRequest.bytes > 0,
                  MusicRuntimeResources.validHash(coverRequest.sha256) else { throw CredentialError.invalidInput }
            let image = try MusicRuntimeResources.read(root: coverRequest.fileURL.deletingLastPathComponent(),
                relative: coverRequest.fileURL.lastPathComponent, bytes: coverRequest.bytes, mode: 0o600)
            guard MusicRuntimeResources.hash(image) == coverRequest.sha256 else { throw CredentialError.identityMismatch }
            request["arguments"] = coverRequest.arguments
        }
        if businessJournal != nil, readRequest != nil || writeRequest != nil || coverRequest != nil { request["business_audit"] = true }
        try? businessJournal?.append(["event":"runtime_request", "operation":request["operation"]!, "arguments":request["arguments"] ?? [:]],
                                    requestID: MusicDiagnostics.current?.requestID, callID: UUID(uuidString: callID))
        var runtimeFinished = false
        defer {
            if !runtimeFinished {
                try? businessJournal?.append(["event":"runtime_interrupted","operation":request["operation"]!],
                                             requestID: MusicDiagnostics.current?.requestID, callID: UUID(uuidString: callID))
            }
        }
        var encoded = try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
        defer { encoded.resetBytes(in: 0..<encoded.count) }
        guard encoded.count <= 262144 else { throw CredentialError.invalidInput }
        let process = MusicReadOwnedChild(), input = Pipe(), output = Pipe()
        let node = root.appendingPathComponent("Runtime/node")
        let generation: UUID
        do { generation = try processOwner.reserve(process); ticket.reserved = true }
        catch {
            try? input.fileHandleForReading.close(); try? input.fileHandleForWriting.close()
            try? output.fileHandleForReading.close(); try? output.fileHandleForWriting.close()
            throw error
        }
        var launched = false
        var birth: proc_bsdinfo?
        var cleanupBirth: proc_bsdinfo?
        var pid: pid_t = 0
        func stop() {
            guard launched else { processOwner.neverLaunched(generation, process: process); ticket.reaped = true; return }
            _ = process.signal(SIGTERM, expected: birth ?? cleanupBirth, identity: processSignalIdentity)
            var end = ProcessInfo.processInfo.systemUptime + 1
            while process.isRunning && ProcessInfo.processInfo.systemUptime < end { process.pollExit(); usleep(10000) }
            _ = process.signal(SIGKILL, expected: birth ?? cleanupBirth, identity: processSignalIdentity)
            end = ProcessInfo.processInfo.systemUptime + 1
            while process.isRunning && ProcessInfo.processInfo.systemUptime < end { process.pollExit(); usleep(10000) }
            if !process.isRunning {
                processOwner.reaped(generation, process: process); ticket.reaped = true
            } else {
                processOwner.unproven(generation, process: process)
            }
        }
        // Registered before launch/identity checks: every throw closes every pipe end.
        defer {
            try? input.fileHandleForReading.close(); try? input.fileHandleForWriting.close()
            try? output.fileHandleForReading.close(); try? output.fileHandleForWriting.close()
            stop()
        }
        if cancellation.cancelled { throw CancellationError() }
        var arguments = ["--permission", "--allow-fs-read=" + root.path]
        if let coverRequest { arguments.append("--allow-fs-read=" + coverRequest.fileURL.path) }
        #if ARL_OWNER_FIXTURE
        if let scenario = fixtureScenario(coverRequest == nil ? (writeRequest?.operation ?? readRequest?.operation ?? operation.rawValue) : "playlist_cover") {
            guard scenario.utf8.count <= 48, scenario.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 95 }),
                  let expected = manifest["Fixture/Provider.cjs"]?["sha256"] as? String,
                  MusicRuntimeResources.hash(try MusicRuntimeResources.verified(root: root, name: "Fixture/Provider.cjs", manifest: manifest)) == expected else { throw CredentialError.identityMismatch }
            arguments += ["--require", root.appendingPathComponent("Fixture/Provider.cjs").path,
                          root.appendingPathComponent("Bridge/netease_bridge.cjs").path, scenario]
        } else { arguments.append(root.appendingPathComponent("Bridge/netease_bridge.cjs").path) }
        #else
        arguments.append(root.appendingPathComponent("Bridge/netease_bridge.cjs").path)
        #endif
        try process.run(executable: node,
                        arguments: arguments,
                        environment: ["PATH":"", "HOME":"/ARL-Virtual-Home", "XDG_CONFIG_HOME":"/ARL-Virtual-Home/.config",
                                      "LANG":"C", "LC_ALL":"C", "TMPDIR":"/ARL-Virtual-Home"],
                        directory: root, input: input, output: output,
                        reaped: { processOwner.reaped(generation, process: process) })
        launched = true; pid = process.processIdentifier
        // Admission and cleanup snapshots are separate. The child also retains
        // exclusive waitpid ownership, so an unavailable snapshot never permits
        // signalling a reused PID.
        cleanupBirth = MusicReadSystemIdentity.read(pid)
        birth = processIdentity(pid)
        guard let birth, birth.pbi_ppid == UInt32(getpid()), birth.pbi_uid == getuid(),
              cleanupBirth.map({ $0.pbi_start_tvsec == birth.pbi_start_tvsec && $0.pbi_start_tvusec == birth.pbi_start_tvusec }) ?? true
        else { throw CredentialError.identityMismatch }
        try input.fileHandleForReading.close(); try output.fileHandleForWriting.close()
        let readFD = output.fileHandleForReading.fileDescriptor, writeFD = input.fileHandleForWriting.fileDescriptor
        guard fcntl(writeFD,F_SETNOSIGPIPE,1) == 0,
              fcntl(readFD,F_SETFL,fcntl(readFD,F_GETFL)|O_NONBLOCK) == 0,
              fcntl(writeFD,F_SETFL,fcntl(writeFD,F_GETFL)|O_NONBLOCK) == 0 else { throw CredentialError.storageUnavailable }
        let deadline = min(ProcessInfo.processInfo.systemUptime + (coverRequest != nil ? 150 : operation == .login ? 300 : readRequest == nil && writeRequest == nil ? 15 : max(0.05, min(readTimeout, 45))),
                           readRequest == nil ? .infinity : MusicSearchReadDeadline.current ?? .infinity)
        #if ARL_OWNER_FIXTURE
        fixtureBeforeFirstWrite()
        #endif
        var sent = 0, inputClosed = false, buffer = Data(), total = 0, qrCount = 0, diagnosticCount = 0
        defer { buffer.resetBytes(in: 0..<buffer.count) }
        var result: MusicRuntimeResult?
        var businessPart = 0, businessParts = 0, businessRecordID: String?, businessHash = SHA256()
        var coverBytes = Data(), coverPart = 0, coverParts = 0, coverDigest: String?
        defer { coverBytes.resetBytes(in: 0..<coverBytes.count) }
        var normalBytes = 0
        var delivered = false
        defer { if !delivered { result?.credential.clear() } }
        while ProcessInfo.processInfo.systemUptime < deadline {
            if cancellation.cancelled { throw CancellationError() }
            if !inputClosed {
                let count = encoded.withUnsafeBytes { Darwin.write(writeFD,$0.baseAddress!.advanced(by:sent),encoded.count-sent) }
                if count > 0 { sent += count }
                else if count < 0 && errno != EAGAIN && errno != EINTR { throw CredentialError.storageUnavailable }
                if sent == encoded.count { try input.fileHandleForWriting.close(); inputClosed = true }
            }
            var chunk = [UInt8](repeating:0,count:4096)
            defer { chunk.withUnsafeMutableBufferPointer { $0.initialize(repeating: 0) } }
            let count = Darwin.read(readFD,&chunk,chunk.count)
            if count > 0 {
                total += count; guard businessJournal != nil || coverRequest != nil || readRequest != nil || total <= 524288 else { throw CredentialError.uncertainLocalState }
                buffer.append(contentsOf:chunk.prefix(count))
                while let newline = buffer.firstIndex(of:10) {
                    var line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
                    defer { line.resetBytes(in: 0..<line.count) }
                    guard line.count <= 262144,
                          let frame = try? MusicStrictJSON.object(line, limit: 262144, maximumDepth: 32),
                          let schema = frame["schema"] as? NSNumber, CFGetTypeID(schema) != CFBooleanGetTypeID(), schema.doubleValue == 1, frame["call_id"] as? String == callID,
                          let event = frame["event"] as? String, result == nil else { throw CredentialError.uncertainLocalState }
                    if event == "business_record" {
                        guard coverParts == 0, let businessJournal,
                              Set(frame.keys) == ["schema","call_id","event","record_id","part","parts","sha256","payload"],
                              let recordID = frame["record_id"] as? String, UUID(uuidString: recordID) != nil,
                              let part = MusicRuntimeResources.integer(frame["part"]),
                              let parts = MusicRuntimeResources.integer(frame["parts"]), parts > 0,
                              let digest = frame["sha256"] as? String, MusicRuntimeResources.validHash(digest),
                              let encodedPart = frame["payload"] as? String, let payload = Data(base64Encoded: encodedPart),
                              payload.count <= 65536, payload.base64EncodedString() == encodedPart
                        else { throw CredentialError.uncertainLocalState }
                        if part == 0 {
                            guard businessRecordID == nil else { throw CredentialError.uncertainLocalState }
                            businessRecordID = recordID; businessParts = parts; businessPart = 0; businessHash = SHA256()
                        }
                        guard recordID == businessRecordID, parts == businessParts, part == businessPart, part < parts
                        else { throw CredentialError.uncertainLocalState }
                        businessHash.update(data: payload); businessPart += 1
                        try? businessJournal.append(frame, requestID: MusicDiagnostics.current?.requestID, callID: UUID(uuidString: callID))
                        if businessPart == parts {
                            let actual = businessHash.finalize().map { String(format:"%02x",$0) }.joined()
                            guard actual == digest else { throw CredentialError.uncertainLocalState }
                            businessRecordID = nil
                        }
                        continue
                    }
                    if event == "cover_result_part" || event == "read_result_part" {
                        guard (event == "cover_result_part" ? coverRequest != nil : readRequest != nil), businessRecordID == nil,
                              Set(frame.keys) == ["schema","call_id","event","part","parts","sha256","payload"],
                              let part = MusicRuntimeResources.integer(frame["part"]),
                              let parts = MusicRuntimeResources.integer(frame["parts"]), parts > 0,
                              let digest = frame["sha256"] as? String, MusicRuntimeResources.validHash(digest),
                              let encodedPart = frame["payload"] as? String, var payload = Data(base64Encoded: encodedPart),
                              !payload.isEmpty, payload.count <= 65536, payload.base64EncodedString() == encodedPart
                        else { throw CredentialError.uncertainLocalState }
                        defer { payload.resetBytes(in: 0..<payload.count) }
                        if coverDigest == nil { coverDigest = digest; coverParts = parts }
                        guard digest == coverDigest, parts == coverParts, part == coverPart, part < parts,
                              part == parts - 1 || payload.count == 65536 else { throw CredentialError.uncertainLocalState }
                        guard coverBytes.count <= 32 * 1024 * 1024 - payload.count else { throw CredentialError.uncertainLocalState }
                        coverBytes.append(payload); coverPart += 1
                        continue
                    }
                    normalBytes += line.count
                    guard normalBytes <= 524288, businessRecordID == nil else { throw CredentialError.uncertainLocalState }
                    if event == "diagnostic" {
                        diagnosticCount += 1
                        let detail=try MusicDiagnostic.decode(frame,callID:callID,expectedSequence:diagnosticCount)
                        MusicDiagnostics.current?.accept(detail)
                    } else if event == "login_qr" {
                        qrCount += 1
                        guard readRequest == nil, writeRequest == nil, coverRequest == nil, operation == .login, qrCount == 1, Set(frame.keys) == ["schema","call_id","event","url"],
                              let raw = frame["url"] as? String, raw.utf8.count <= 4096, let url = URL(string:raw),
                              let validatedURL = MusicLoginURL.validated(url) else {
                            MusicDiagnostics.current?.record(.qr_delivery,.invalid_response,reason:.qr_frame_invalid)
                            throw CredentialError.uncertainLocalState
                        }
                        onLoginURL(validatedURL)
                        MusicDiagnostics.current?.record(.qr_delivery,.succeeded)
                    } else if coverRequest != nil {
                        guard event == "cover_complete", Set(frame.keys) == ["schema","call_id","event","operation","result_sha256","credential"],
                              frame["operation"] as? String == "playlist_cover", coverParts > 0, coverPart == coverParts,
                              frame["result_sha256"] as? String == coverDigest,
                              MusicRuntimeResources.hash(coverBytes) == coverDigest else { throw CredentialError.uncertainLocalState }
                        let raw = try MusicStrictJSON.object(coverBytes, limit: coverBytes.count, maximumDepth: 32)
                        guard Set(raw.keys) == ["state","resource_id","provider_response","provider_response_complete","provider_exchange","upload_receipts"],
                              let state = raw["state"] as? String, ["submitted","not_submitted","outcome_unknown","provider_rejected"].contains(state),
                              let complete = raw["provider_response_complete"] as? NSNumber, CFGetTypeID(complete) == CFBooleanGetTypeID(),
                              let receipts = raw["upload_receipts"] as? [Any],
                              let encoded = frame["credential"] as? String, var data = Data(base64Encoded: encoded),
                              data.base64EncodedString() == encoded else { throw CredentialError.uncertainLocalState }
                        defer { data.resetBytes(in: 0..<data.count) }
                        let resource = raw["resource_id"] as? String
                        guard raw["resource_id"] is NSNull || resource?.range(of: "^[1-9][0-9]{0,19}$", options: .regularExpression) != nil else { throw CredentialError.uncertainLocalState }
                        try MusicEnvelope.validate(data, requireOfficial: true)
                        let credential = try CredentialInput(purpose: .neteaseMusic, data: data)
                        let effect = MusicPlaylistCoverEffect(state: state, credential: credential, resourceID: resource,
                            providerResponse: raw["provider_response"] is NSNull ? nil : try MusicReadProtocol.providerRecord(raw["provider_response"]!),
                            providerResponseComplete: complete.boolValue,
                            providerExchange: raw["provider_exchange"] is NSNull ? nil : try MusicReadProtocol.providerRecord(raw["provider_exchange"]!),
                            uploadReceipts: try receipts.map { try MusicReadProtocol.providerRecord($0) })
                        result = .init(state: .sessionPresentUnverified, credential: credential, coverEffect: effect)
                    } else if let writeRequest {
                        guard event == "write_complete", Set(frame.keys) == ["schema","call_id","event","operation","result","credential"],
                              frame["operation"] as? String == writeRequest.operation,
                              let raw = frame["result"] as? [String: Any], Set(raw.keys).subtracting(["provider_result"]) == ["state","playlist_id"],
                              let state = raw["state"] as? String, let mapped = MusicWriteEffect.State(rawValue: state),
                              let encoded = frame["credential"] as? String,
                              var data = Data(base64Encoded: encoded), data.base64EncodedString() == encoded
                        else { throw CredentialError.uncertainLocalState }
                        defer { data.resetBytes(in: 0..<data.count) }
                        let playlistID = raw["playlist_id"] as? String
                        guard raw["playlist_id"] is NSNull || (playlistID.map { MusicReadProtocol.validID($0) && $0 == $0.lowercased() } ?? false),
                              (mapped != .notSubmitted || playlistID == nil),
                              writeRequest.intent == .createPlaylist || playlistID == nil || playlistID == writeRequest.playlistID
                        else { throw CredentialError.uncertainLocalState }
                        try MusicEnvelope.validate(data, requireOfficial: true)
                        let credential = try CredentialInput(purpose: .neteaseMusic, data: data)
                        let effect = MusicWriteEffect(state: mapped, playlistID: playlistID, credential: credential,
                                                      providerResult: try raw["provider_result"].map { try MusicReadProtocol.providerRecord($0) })
                        result = .init(state: .sessionPresentUnverified, credential: credential, writeEffect: effect)
                    } else if let readRequest {
                        let streamed = frame["result_sha256"] != nil
                        guard event == "read_complete", Set(frame.keys) == (streamed ? ["schema","call_id","event","operation","result_sha256","credential"] : ["schema","call_id","event","operation","result","credential"]),
                              frame["operation"] as? String == readRequest.operation,
                              let encoded = frame["credential"] as? String,
                              var data = Data(base64Encoded: encoded), data.base64EncodedString() == encoded
                        else { throw CredentialError.uncertainLocalState }
                        defer { data.resetBytes(in: 0..<data.count) }
                        let rawResult: [String:Any]
                        if streamed {
                            guard coverParts > 0,coverPart == coverParts,frame["result_sha256"] as? String == coverDigest,
                                  MusicRuntimeResources.hash(coverBytes) == coverDigest else { throw CredentialError.uncertainLocalState }
                            rawResult = try MusicStrictJSON.object(coverBytes,limit:coverBytes.count,maximumDepth:32)
                        } else {
                            guard coverParts == 0,let raw = frame["result"] as? [String:Any] else { throw CredentialError.uncertainLocalState }
                            rawResult = raw
                        }
                        try MusicEnvelope.validate(data, requireOfficial: true)
                        let readResult = try MusicReadProtocol.decode(rawResult, for: readRequest, correlationID: UUID(uuidString: callID),verification:MusicReadPurpose.verification)
                        result = .init(state: readResult.connectionState,
                                       credential: try CredentialInput(purpose: .neteaseMusic, data: data), readResult: readResult)
                    } else {
                        guard event == "complete", Set(frame.keys) == ["schema","call_id","event","state","credential"],
                              let state = frame["state"] as? String, let encoded = frame["credential"] as? String,
                              var data = Data(base64Encoded:encoded), data.base64EncodedString() == encoded else { throw CredentialError.uncertainLocalState }
                        defer { data.resetBytes(in: 0..<data.count) }
                        try MusicEnvelope.validate(data, requireOfficial: true)
                        let states: [String:ConnectionState] = ["saved_unverified":.savedUnverified,"login_required":.loginRequired,
                            "session_present_unverified":.sessionPresentUnverified,"login_expired":.loginExpired,"provider_unconfirmed":.credentialUnconfirmed]
                        let allowedStates: Set<String> = operation == .prepare ? ["saved_unverified","provider_unconfirmed"] :
                            operation == .status ? ["login_required","session_present_unverified","provider_unconfirmed"] :
                            ["session_present_unverified","login_expired","provider_unconfirmed"]
                        guard allowedStates.contains(state), let mapped = states[state] else { throw CredentialError.uncertainLocalState }
                        result = .init(state:mapped,credential:try CredentialInput(purpose:.neteaseMusic,data:data))
                    }
                }
                guard buffer.count <= 262144 else { throw CredentialError.uncertainLocalState }
            } else if count == 0 {
                guard buffer.isEmpty, businessRecordID == nil, let result else { throw CredentialError.uncertainLocalState }
                guard !process.isRunning else { usleep(10000); continue }
                process.pollExit()
                guard process.terminationStatus == 0 else {
                    result.credential.clear()
                    if operation == .login, readRequest == nil, writeRequest == nil, coverRequest == nil {
                        throw result.state == .loginExpired ? MusicLoginRuntimeFailure.expired : MusicLoginRuntimeFailure.runtimeExited
                    }
                    throw CredentialError.storageUnavailable
                }
                if operation == .login,readRequest==nil,writeRequest==nil,coverRequest==nil,result.state == .credentialUnconfirmed {
                    MusicDiagnostics.current?.loginUnconfirmed(qrDelivered:qrCount==1)
                }
                try? businessJournal?.append(["event":"runtime_complete","operation":request["operation"]!,
                                              "state":result.readResult?.state.rawValue ?? result.writeEffect?.state.rawValue ?? result.coverEffect?.state ?? result.state.rawValue,
                                              "elapsed_ms":max(0,Int((ProcessInfo.processInfo.systemUptime - businessStarted)*1000))],
                                             requestID: MusicDiagnostics.current?.requestID, callID: UUID(uuidString:callID))
                runtimeFinished = true; delivered = true
                return result
            } else if errno != EAGAIN && errno != EINTR { throw CredentialError.storageUnavailable }
            var descriptor = pollfd(fd:readFD,events:Int16(POLLIN|POLLHUP),revents:0)
            _ = poll(&descriptor,1,20)
        }
        throw TransportFailure.timeout
    }
}
