import Foundation
import Darwin
import CryptoKit
import Security

enum NASRuntimeResources {
    static func verify(bundleURL: URL, gate: any DeploymentGate) throws -> URL {
        try gate.verify()
        guard let bundle = Bundle(url: bundleURL), let resources = bundle.resourceURL,
              let expected = bundle.object(forInfoDictionaryKey: "ARLNASRuntimeInventorySHA256") as? String,
              MusicRuntimeResources.validHash(expected) else { throw CredentialError.deploymentNotApproved }
        let root = resources.appendingPathComponent("NASRuntime")
        let manifestURL = root.appendingPathComponent("inventory.json")
        let size = try manifestURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard (1...4_000_000).contains(size) else { throw CredentialError.identityMismatch }
        let data = try MusicRuntimeResources.read(root: root, relative: "inventory.json", bytes: size)
        guard MusicRuntimeResources.hash(data) == expected,
              let manifest = try JSONSerialization.jsonObject(with: data) as? [String: [String: Any]],
              manifest["python/bin/python3.12"] != nil, manifest["Runtime/nas_host.py"] != nil,
              manifest.count < 15000 else { throw CredentialError.identityMismatch }
        for (name, row) in manifest {
            guard let bytes = MusicRuntimeResources.integer(row["bytes"]), bytes >= 0,
                  let sha = row["sha256"] as? String, MusicRuntimeResources.validHash(sha),
                  let mode = MusicRuntimeResources.integer(row["mode"]) else { throw CredentialError.identityMismatch }
            let raw: Data
            if bytes == 0 {
                guard !name.hasPrefix("/"), name.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw CredentialError.identityMismatch }
                let parent = try MusicRuntimeResources.directory(root.appendingPathComponent(name).deletingLastPathComponent().path)
                defer { Darwin.close(parent) }
                let fd = openat(parent, URL(fileURLWithPath: name).lastPathComponent, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
                guard fd >= 0 else { throw CredentialError.identityMismatch }; defer { Darwin.close(fd) }
                var info = stat(); var byte: UInt8 = 0
                guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size == 0,
                      Int(info.st_mode & 0o7777) == mode, Darwin.read(fd, &byte, 1) == 0 else { throw CredentialError.identityMismatch }
                raw = Data()
            } else { raw = try MusicRuntimeResources.read(root: root, relative: name, bytes: bytes, mode: mode) }
            guard MusicRuntimeResources.hash(raw) == sha else { throw CredentialError.identityMismatch }
        }
        try gate.verify()
        return root
    }
}

// A reaped worker is a runtime failure; only an explicit stop is cancellation.
// Kept internal so the exact classification can be exercised without an App.
enum NASPipeLiveness {
    static func check(stopped: Bool, childRunning: Bool) throws {
        guard !stopped else { throw CancellationError() }
        guard childRunning else { throw NASRuntimeFailure.unavailable }
    }
}

private final class NASOwnedPipe: @unchecked Sendable {
    private let stateLock = NSLock(), exchangeLock = NSLock()
    private let child = MusicReadOwnedChild()
    private let input = Pipe(), output = Pipe()
    private let gate: any DeploymentGate
    private let repository: any CredentialRepository
    private let identity: NASCredentialIdentity
    private let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    private let deadline = ProcessInfo.processInfo.systemUptime + 120
    private let directory: URL
    private var secret: Data
    private var stopped = false
    private var sequence = 0
    private var leaseSent = false
    private var authorizationSequence = 0
    private var readBuffer = Data()
    private var scope: [String: Any]?
    private var uploadAuthorization: NASUploadAuthorization?
    private var caller: [String: Any] = [:]
    private let config: NASConnectionConfiguration?
    private let endpoint: NASServerEndpoint?
    private var metadataTarget: [String: String] = [:]

    init(root: URL, bundleURL: URL, configuration: NASConnectionConfiguration? = nil, endpoint: NASServerEndpoint? = nil,
         identity: NASCredentialIdentity, secret: CredentialInput,
         repository: any CredentialRepository, gate: any DeploymentGate) throws {
        guard (configuration == nil) != (endpoint == nil) else { throw CredentialError.invalidInput }
        self.config = configuration; self.endpoint = endpoint; self.identity = identity; self.repository = repository; self.gate = gate
        self.secret = try secret.copyBytes(for: .nasSMB)
        directory = URL(fileURLWithPath: "/private/tmp/arl-nas-" + UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            try verify()
            guard let executable = Bundle(url: bundleURL)?.executableURL else { throw CredentialError.identityMismatch }
            let executableHash = MusicRuntimeResources.hash(try Data(contentsOf: executable))
            let profile = MusicRuntimeResources.hash(try Data(contentsOf: root.appendingPathComponent("inventory.json")))
            var code: SecCode?; var staticCode: SecStaticCode?; var requirement: SecRequirement?; var requirementText: CFString?
            guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
                  SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
                  SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess, let requirement,
                  SecRequirementCopyString(requirement, [], &requirementText) == errSecSuccess, let requirementText
            else { throw CredentialError.identityMismatch }
            let requirementHash = MusicRuntimeResources.hash(Data((requirementText as String).utf8))
            // Descriptors are bound to this native pipe; live native gate and repository
            // checks below, not these strings, authorize each callback.
            caller = ["subject": "local.arl.control", "uid": Int(getuid()), "pid": Int(getpid()),
                      "executable_sha256": executableHash, "designated_requirement_sha256": requirementHash,
                      "profile_sha256": profile, "registration_epoch": UInt64.random(in: 1...UInt64(Int64.max))]
            try child.run(executable: root.appendingPathComponent("python/bin/python3.12"),
                arguments: ["-I", "-B", root.appendingPathComponent("Runtime/nas_host.py").path],
                environment: ["PATH": "", "HOME": directory.path, "TMPDIR": directory.path, "LANG": "C", "LC_ALL": "C"],
                directory: directory, input: input, output: output, reaped: {})
            try input.fileHandleForReading.close(); try output.fileHandleForWriting.close()
            guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else { throw CredentialError.storageUnavailable }
            for fd in [input.fileHandleForWriting.fileDescriptor, output.fileHandleForReading.fileDescriptor] {
                guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0 else { throw CredentialError.storageUnavailable }
            }
        } catch { stop(); throw error }
    }

    private func verify() throws {
        guard !stateLock.withLock({ stopped }) else { throw CancellationError() }
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw NASRuntimeFailure.expired }
        try gate.verify()
        guard let metadata = try repository.metadata(.nasSMB),
              NASCredentialIdentity(metadata) == identity else { throw CredentialError.staleReference }
        guard !stateLock.withLock({ stopped }), ProcessInfo.processInfo.systemUptime < deadline else { throw CancellationError() }
    }
    private func wait(_ fd: Int32, events: Int16, until: Double) throws {
        while ProcessInfo.processInfo.systemUptime < until {
            try NASPipeLiveness.check(stopped: stateLock.withLock({ stopped }), childRunning: child.isRunning)
            var item = pollfd(fd: fd, events: events, revents: 0)
            let value = poll(&item, 1, 50)
            if value < 0 && errno == EINTR { continue }
            guard value >= 0 else { throw CredentialError.storageUnavailable }
            if value > 0 {
                guard item.revents & events != 0 else { throw CredentialError.storageUnavailable }
                return
            }
        }
        throw CredentialError.busy
    }
    private func send(_ value: [String: Any], until: Double) throws {
        var data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
        defer { data.resetBytes(in: 0..<data.count) }
        data.append(10)
        guard data.count <= 2 * 1024 * 1024 else { throw CredentialError.invalidInput }
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                try wait(input.fileHandleForWriting.fileDescriptor, events: Int16(POLLOUT), until: until)
                let n = Darwin.write(input.fileHandleForWriting.fileDescriptor, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if n < 0 && [EAGAIN, EINTR].contains(errno) { continue }
                guard n > 0 else { throw CredentialError.storageUnavailable }
                offset += n
            }
        }
    }
    private func read(until: Double) throws -> [String: Any] {
        while true {
            if let index = readBuffer.firstIndex(of: 10) {
                var line = Data(readBuffer[..<index]); readBuffer.removeSubrange(...index)
                defer { line.resetBytes(in: 0..<line.count) }
                guard let result = try JSONSerialization.jsonObject(with: line) as? [String: Any] else { throw CredentialError.uncertainLocalState }
                return result
            }
            try wait(output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), until: until)
            var bytes = [UInt8](repeating: 0, count: 16384)
            let count = Darwin.read(output.fileHandleForReading.fileDescriptor, &bytes, bytes.count)
            if count < 0 && [EAGAIN, EINTR].contains(errno) { continue }
            guard count > 0 else { throw NASRuntimeFailure.unavailable }
            readBuffer.append(contentsOf: bytes[..<count])
            guard readBuffer.count <= 2 * 1024 * 1024 else { throw CredentialError.uncertainLocalState }
        }
    }
    private func expectedScope() throws -> NSDictionary? {
        let bytes: Data
        if let config { bytes = try config.scopeJSON(identity:identity) }
        else if let endpoint { bytes = try endpoint.scopeJSON(identity:identity,target:metadataTarget) }
        else { throw CredentialError.invalidInput }
        return try JSONSerialization.jsonObject(with:bytes) as? NSDictionary
    }
    private func authorize(_ frame: [String: Any], until: Double) throws {
        try verify()
        guard let kind = frame["kind"] as? String, ["authorize", "lease", "upload_check", "upload_consume"].contains(kind),
              Set(frame.keys) == Set(["kind", "sequence", "nonce", "stage", "scope", "caller"] + (kind.hasPrefix("upload_") ? ["plan_digest"] : [])),
              frame["nonce"] as? String == nonce,
              let requestSequence = MusicRuntimeResources.integer(frame["sequence"]), requestSequence == authorizationSequence + 1,
              let stage = frame["stage"] as? String,
              (kind.hasPrefix("upload_")
                ? stage.range(of: "^[a-z_]{1,128}$", options: .regularExpression) != nil
                : ["reserve", "lease", "connect", "connect_effect", "reply", "provider_reply", "request", "request_reply", "inventory_metadata"].contains(stage)),
              let actualCaller = frame["caller"] as? NSDictionary, actualCaller == caller as NSDictionary,
              let currentScope = frame["scope"] as? [String: Any],
              let expectedScope = try expectedScope(), expectedScope == currentScope as NSDictionary
        else { throw CredentialError.identityMismatch }
        authorizationSequence = requestSequence
        if kind.hasPrefix("upload_") {
            guard let uploadAuthorization, frame["plan_digest"] as? String == uploadAuthorization.planDigest
            else { throw CredentialError.staleReference }
            try uploadAuthorization.authorize(consume: kind == "upload_consume")
        }
        if let scope, config != nil {
            guard (scope as NSDictionary) == currentScope as NSDictionary else { throw CredentialError.staleReference }
        } else { scope = currentScope }
        var reply: [String: Any] = ["kind": "authorization", "sequence": requestSequence, "nonce": nonce,
                                    "ok": true, "remaining_seconds": min(max(0, deadline - ProcessInfo.processInfo.systemUptime), uploadAuthorization?.remaining ?? 120)]
        if kind == "lease" {
            guard !leaseSent else { throw CredentialError.staleReference }
            leaseSent = true
            reply["credential"] = stateLock.withLock { secret.base64EncodedString() }
        }
        try verify(); try send(reply, until: until)
        if kind == "lease" {
            stateLock.withLock { secret.resetBytes(in: 0..<secret.count); secret.removeAll(keepingCapacity: false) }
            reply.removeValue(forKey: "credential")
        }
    }
    func exchange(_ action: String, upload: NASUploadProposal? = nil, journalDirectory: URL? = nil,
                  directoryPath: String? = nil, directoryCursor: String? = nil, serverShare: String? = nil,
                  fileRequest: NASFileRequest? = nil) throws -> [String: Any] {
        try exchangeLock.withLock {
            try verify()
            if endpoint != nil {
                guard upload == nil, ["server_connect","server_status","shares","preview_directories","stop"].contains(action) else { throw CredentialError.wrongPurpose }
                metadataTarget = [:]
                if action == "shares" { metadataTarget = ["operation":"shares","cursor":directoryCursor ?? ""] }
                if action == "server_status" { metadataTarget = ["operation":"status"] }
                if action == "preview_directories" {
                    guard let serverShare, let directoryPath else { throw CredentialError.invalidInput }
                    _ = try NASShareRecord(name:serverShare); try NASDirectoryPage.validatePath(directoryPath)
                    metadataTarget = ["operation":"directories","share":serverShare,"path":directoryPath,"cursor":directoryCursor ?? ""]
                }
            }
            if let upload {
                guard let config, action == "upload_new", upload.configuration == config, upload.identity == identity,
                      let scope, let journalDirectory, let epoch = caller["registration_epoch"] as? UInt64
                else { throw CredentialError.staleReference }
                uploadAuthorization = try NASUploadAuthorization(proposal: upload, scope: scope, epoch: epoch,
                    directory: journalDirectory, verify: { [self] in try verify() })
            }
            defer { uploadAuthorization = nil }
            sequence += 1
            let id = sequence
            // A file request composes several separately timed SMB calls and native
            // authorization callbacks. Its total budget never extends this pipe lease.
            let requestSeconds = ["files", "connect"].contains(action) ? 90.0 : Double((config?.timeoutSeconds ?? endpoint?.timeoutSeconds ?? 8) + 10)
            let until = min(deadline, ProcessInfo.processInfo.systemUptime + requestSeconds)
            var frame: [String: Any] = ["kind": action, "id": id, "nonce": nonce]
            if let fileRequest {
                guard config != nil, endpoint == nil, action == "files", upload == nil else { throw CredentialError.wrongPurpose }
                frame["request"] = try MusicStrictJSON.object(fileRequest.wireJSON, limit: 16384)
            }
            if let directoryPath {
                guard action == "directories" || action == "preview_directories" else { throw CredentialError.invalidInput }
                try NASDirectoryPage.validatePath(directoryPath)
                guard directoryCursor == nil || directoryCursor?.range(of: "^[0-9a-f]{32}$", options: .regularExpression) != nil
                else { throw CredentialError.invalidInput }
                frame["path"] = directoryPath
                frame["cursor"] = directoryCursor as Any? ?? NSNull()
            }
            if let uploadAuthorization {
                frame["plan"] = uploadAuthorization.plan
                frame["source"] = Data(uploadAuthorization.proposal.text.utf8).base64EncodedString()
                frame["journal"] = uploadAuthorization.journalDescriptor
            }
            if action == "connect" {
                guard let config, id == 1 else { throw CredentialError.staleReference }
                frame["caller"] = caller
                frame["credential_generation"] = identity.generation.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
                frame["config_generation"] = config.generation
                frame["config"] = ["source_ref": config.sourceRef, "transport": "smb", "host": config.host, "port": config.port,
                    "share": config.share, "root": config.root, "credential_ref": identity.reference.id.uuidString.lowercased(),
                    "enabled": true, "require_encryption": true, "connect_timeout_seconds": config.timeoutSeconds,
                    "operation_timeout_seconds": min(10, config.timeoutSeconds), "health_interval_seconds": 300] as [String: Any]
            }
            if let endpoint {
                frame["scope"] = try JSONSerialization.jsonObject(with:endpoint.scopeJSON(identity:identity,target:metadataTarget))
                if action == "server_connect" {
                    guard id == 1 else { throw CredentialError.staleReference }
                    frame["caller"] = caller
                    frame["endpoint"] = ["source_ref":endpoint.sourceRef,"host":endpoint.host,"port":endpoint.port,
                        "timeout_seconds":endpoint.timeoutSeconds,"generation":endpoint.generation,
                        "endpoint_fingerprint":endpoint.fingerprint,"require_encryption":true] as [String:Any]
                }
                if action == "shares" { frame["cursor"] = directoryCursor as Any? ?? NSNull() }
                if action == "preview_directories" {
                    frame["share"] = serverShare!; frame["path"] = directoryPath!; frame["cursor"] = directoryCursor as Any? ?? NSNull()
                }
            }
            do {
                try send(frame, until: until)
                while true {
                    let value = try read(until: until)
                    if let kind = value["kind"] as? String, ["authorize", "lease", "upload_check", "upload_consume"].contains(kind) {
                        try authorize(value, until: until); continue
                    }
                    try verify()
                    if value["kind"] as? String == "result", MusicRuntimeResources.integer(value["id"]) == id,
                       value["nonce"] as? String == nonce, value["ok"] as? Bool == false,
                       Set(value.keys) == ["kind", "id", "nonce", "ok", "error"], let error = value["error"] as? String {
                        throw NASRuntimeFailure(rawValue: error) ?? .transportFailed
                    }
                    guard value["kind"] as? String == "result", MusicRuntimeResources.integer(value["id"]) == id,
                          value["nonce"] as? String == nonce, value["ok"] as? Bool == true,
                          Set(value.keys) == ["kind", "id", "nonce", "ok", "value"],
                          let result = value["value"] as? [String: Any] else { throw CredentialError.storageUnavailable }
                    return result
                }
            } catch {
                let recoverable: Set<NASRuntimeFailure> = [.invalidRequest, .objectUnknown, .revisionChanged, .cursorExpired, .missing, .budgetExceeded, .nasSourceChanged, .nasBusy]
                if action != "files" || !recoverable.contains(error as? NASRuntimeFailure ?? .transportFailed) { stop() }
                throw error
            }
        }
    }
    func stop() {
        let first = stateLock.withLock { () -> Bool in
            if stopped { return false }; stopped = true
            secret.resetBytes(in: 0..<secret.count); secret.removeAll(keepingCapacity: false)
            return true
        }
        guard first else { return }
        _ = child.signal(SIGTERM, expected: nil)
        var until = ProcessInfo.processInfo.systemUptime + 1
        while child.isRunning && ProcessInfo.processInfo.systemUptime < until { child.pollExit(); usleep(10000) }
        if child.isRunning { _ = child.signal(SIGKILL, expected: nil) }
        until = ProcessInfo.processInfo.systemUptime + 1
        while child.isRunning && ProcessInfo.processInfo.systemUptime < until { child.pollExit(); usleep(10000) }
        // Preserve a directory if cleanup cannot be proved. Never start a replacement
        // in the same directory, nor target any PID after its exclusive reaper releases it.
        if !child.isRunning { try? FileManager.default.removeItem(at: directory) }
    }
    var cleanupProved: Bool { !child.isRunning }
    deinit { stop(); secret.resetBytes(in: 0..<secret.count) }
}

final class NASRuntimeClient: NASConnectionRuntime, @unchecked Sendable {
    private let lock = NSLock()
    private var pipe: NASOwnedPipe?
    private let gate: any DeploymentGate
    private let repository: any CredentialRepository
    private let bundleURL: URL
    private let journalDirectory: URL?
    init(gate: any DeploymentGate, repository: any CredentialRepository, bundleURL: URL, journalDirectory: URL? = nil) {
        self.gate = gate; self.repository = repository; self.bundleURL = bundleURL; self.journalDirectory = journalDirectory
    }
    private func state(_ data: Data) throws -> NASRuntimeState {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CredentialError.uncertainLocalState }
        guard Set(value.keys) == ["connected", "readable", "epoch", "failure", "scope"],
              let connected = value["connected"] as? Bool, let readable = value["readable"] as? Bool,
              !readable || connected else { throw CredentialError.uncertainLocalState }
        return .init(connected: connected, readable: readable, epoch: value["epoch"] as? String,
                     failure: value["failure"] as? String,
                     scopeJSON: (value["scope"] as? [String: Any]).flatMap { try? JSONSerialization.data(withJSONObject: $0) })
    }
    func connect(configuration: NASConnectionConfiguration, identity: NASCredentialIdentity,
                 secret: CredentialInput) async throws -> NASRuntimeState {
        await stop()
        guard lock.withLock({ pipe == nil }) else { throw CredentialError.busy }
        let root = try NASRuntimeResources.verify(bundleURL: bundleURL, gate: gate)
        let current = try NASOwnedPipe(root: root, bundleURL: bundleURL, configuration: configuration,
            identity: identity, secret: secret, repository: repository, gate: gate)
        lock.withLock { pipe = current }
        return try await withTaskCancellationHandler {
            let value = try await Task.detached { try JSONSerialization.data(withJSONObject: current.exchange("connect"), options: [.sortedKeys]) }.value
            try Task.checkCancellation()
            return try state(value)
        } onCancel: { current.stop() }
    }
    private func serverState(_ data: Data) throws -> NASServerState {
        guard let value=try JSONSerialization.jsonObject(with:data) as? [String:Any] else{throw CredentialError.uncertainLocalState}
        guard Set(value.keys) == ["authenticated","epoch","shares","next_cursor","failure"],
              let authenticated = value["authenticated"] as? Bool, let names = value["shares"] as? [String], names.count <= 128,
              authenticated || names.isEmpty else { throw CredentialError.uncertainLocalState }
        let shares = try names.map { try NASShareRecord(name:$0) }
        guard Set(names).count == names.count else { throw CredentialError.uncertainLocalState }
        let epoch = value["epoch"] as? String
        let cursor = value["next_cursor"] as? String
        guard epoch == nil || epoch?.range(of:"^[0-9a-f]{32}$",options:.regularExpression) != nil,
              cursor == nil || cursor?.range(of:"^[0-9a-f]{32}$",options:.regularExpression) != nil,
              !authenticated || epoch != nil else { throw CredentialError.uncertainLocalState }
        return .init(authenticated:authenticated,epoch:epoch,shares:shares,nextCursor:cursor,failure:value["failure"] as? String)
    }
    func authenticate(endpoint: NASServerEndpoint, identity: NASCredentialIdentity, secret: CredentialInput) async throws -> NASServerState {
        await stop(); guard lock.withLock({ pipe == nil }) else { throw CredentialError.busy }
        let root = try NASRuntimeResources.verify(bundleURL:bundleURL,gate:gate)
        let current = try NASOwnedPipe(root:root,bundleURL:bundleURL,endpoint:endpoint,identity:identity,secret:secret,repository:repository,gate:gate)
        lock.withLock { pipe = current }
        return try await withTaskCancellationHandler {
            let result = try await Task.detached { try JSONSerialization.data(withJSONObject:current.exchange("server_connect")) }.value
            try Task.checkCancellation(); return try serverState(result)
        } onCancel: { current.stop() }
    }
    func serverStatus() async -> NASServerState {
        guard let current = lock.withLock({ pipe }) else { return .init() }
        do {
            let result = try await Task.detached { try JSONSerialization.data(withJSONObject:current.exchange("server_status")) }.value
            return try serverState(result)
        } catch { current.stop(); return .init(failure:(error as? NASRuntimeFailure)?.rawValue ?? "nas_unavailable") }
    }
    func listShares(cursor: String?) async throws -> NASServerState {
        guard let current = lock.withLock({ pipe }) else { throw CredentialError.missing }
        return try await withTaskCancellationHandler {
            let result = try await Task.detached { try JSONSerialization.data(withJSONObject:current.exchange("shares",directoryCursor:cursor)) }.value
            try Task.checkCancellation(); return try serverState(result)
        } onCancel: { current.stop() }
    }
    func previewDirectories(share: String, path: String, cursor: String?) async throws -> NASDirectoryPage {
        guard let current = lock.withLock({ pipe }) else { throw CredentialError.missing }
        return try await withTaskCancellationHandler {
            let result = try await Task.detached {
                try JSONSerialization.data(withJSONObject:current.exchange("preview_directories",directoryPath:path,directoryCursor:cursor,serverShare:share))
            }.value
            try Task.checkCancellation(); return try NASDirectoryPage(data:result,expectedPath:path)
        } onCancel: { current.stop() }
    }
    func status() async -> NASRuntimeState {
        guard let current = lock.withLock({ pipe }) else { return .init() }
        do { return try state(await Task.detached { try JSONSerialization.data(withJSONObject: current.exchange("status"), options: [.sortedKeys]) }.value) }
        catch { current.stop(); return .init(failure: (error as? NASRuntimeFailure)?.rawValue ?? "nas_unavailable") }
    }
    func readDirectory() async throws -> Data {
        guard let current = lock.withLock({ pipe }) else { throw CredentialError.missing }
        return try await withTaskCancellationHandler {
            let value = try await Task.detached { try JSONSerialization.data(withJSONObject: current.exchange("list"), options: [.sortedKeys]) }.value
            try Task.checkCancellation()
            return value
        } onCancel: { current.stop() }
    }
    func fileOperation(_ request: NASFileRequest) async throws -> Data {
        guard let current = lock.withLock({ pipe }) else { throw CredentialError.missing }
        return try await withTaskCancellationHandler {
            let data = try await Task.detached {
                try JSONSerialization.data(withJSONObject: current.exchange("files", fileRequest: request), options: [.sortedKeys, .withoutEscapingSlashes])
            }.value
            try Task.checkCancellation()
            return data
        } onCancel: { current.stop() }
    }
    func browseDirectories(path: String, cursor: String?) async throws -> NASDirectoryPage {
        guard let current = lock.withLock({ pipe }) else { throw CredentialError.missing }
        return try await withTaskCancellationHandler {
            let bytes = try await Task.detached {
                try JSONSerialization.data(withJSONObject: current.exchange("directories", directoryPath: path, directoryCursor: cursor))
            }.value
            try Task.checkCancellation()
            return try NASDirectoryPage(data: bytes, expectedPath: path)
        } onCancel: { current.stop() }
    }
    func uploadNew(_ proposal: NASUploadProposal) async throws -> NASUploadResult {
        guard let current = lock.withLock({ pipe }), let journalDirectory else { throw CredentialError.deploymentNotApproved }
        return try await withTaskCancellationHandler {
            let data = try await Task.detached {
                try JSONSerialization.data(withJSONObject: current.exchange("upload_new", upload: proposal, journalDirectory: journalDirectory))
            }.value
            guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Set(value.keys) == ["status","failure","bytes_confirmed","content_sha256"],
                  let status = value["status"] as? String, ["committed","held","rejected","uncertain"].contains(status)
            else { throw CredentialError.uncertainLocalState }
            if status == "committed" {
                guard value["failure"] is NSNull, MusicRuntimeResources.integer(value["bytes_confirmed"]) == proposal.bytes,
                      value["content_sha256"] as? String == proposal.sha256 else { throw CredentialError.uncertainLocalState }
            }
            return .init(status: status, failure: value["failure"] as? String)
        } onCancel: { current.stop() }
    }
    func stop() async {
        let current = lock.withLock { pipe }
        await Task.detached { current?.stop() }.value
        lock.withLock { if let current, current.cleanupProved, pipe === current { pipe = nil } }
    }
}
