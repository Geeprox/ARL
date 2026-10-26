import Foundation
import CryptoKit
import CoreFoundation

/// Endpoint and allowed root, never a URL containing credentials.
public struct NASConnectionConfiguration: Codable, Equatable, Sendable {
    public let sourceRef: String
    public let host: String
    public let port: Int
    public let share: String
    public let root: String
    public let timeoutSeconds: Int
    public let generation: UInt64
    public init(sourceRef: String, host: String, port: Int = 445, share: String,
                root: String, timeoutSeconds: Int = 8, generation: UInt64 = 1) throws {
        guard sourceRef.range(of: "^[A-Za-z0-9_-]{1,96}$", options: .regularExpression) != nil,
              (1...253).contains(host.utf8.count),
              host.range(of: "^[A-Za-z0-9][A-Za-z0-9.-]*$", options: .regularExpression) != nil,
              (1...65535).contains(port), (1...30).contains(timeoutSeconds), generation > 0, generation <= UInt64(Int64.max),
              !share.isEmpty, share.utf8.count <= 255,
              Self.relative(share, root: false), !share.contains("/"),
              Self.relative(root, root: true) else { throw CredentialError.invalidInput }
        self.sourceRef = sourceRef; self.host = host; self.port = port
        self.share = share; self.root = root; self.timeoutSeconds = timeoutSeconds; self.generation = generation
    }
    // Literal SMB names: no URL decoding occurs in the pinned runtime.
    private static func relative(_ value: String, root: Bool) -> Bool {
        if root && value.isEmpty { return true }
        return !value.isEmpty && value.utf8.count <= 1024
            && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            && !value.contains(where: { "\\:".contains($0) })
            && value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
                !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255
            }
    }
    func validated() throws -> Self {
        try .init(sourceRef: sourceRef, host: host, port: port, share: share, root: root, timeoutSeconds: timeoutSeconds, generation: generation)
    }
    public var fingerprint: String {
        let value = [sourceRef, host.lowercased(), String(port), share, root, String(timeoutSeconds)]
        let bytes = try! JSONEncoder().encode(value)
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    /// Exact non-secret descriptor for the existing Python manager contract.
    /// Descriptor construction does not confer admission.
    public func scopeJSON(identity: NASCredentialIdentity) throws -> Data {
        _ = try validated()
        guard identity.reference.purpose == .nasSMB else { throw CredentialError.wrongPurpose }
        func quoted(_ string: String) throws -> String {
            let raw = try JSONSerialization.data(withJSONObject: string, options: [.fragmentsAllowed, .withoutEscapingSlashes])
            let string = String(decoding: raw, as: UTF8.self)
            return string.utf16.map { $0 > 127 ? String(format: "\\u%04x", $0) : String(UnicodeScalar($0)!) }.joined()
        }
        var config: [String: String] = ["schema_version": "1", "source_ref": try quoted(sourceRef),
            "transport": "\"smb\"", "host": try quoted(host), "port": String(port), "share": try quoted(share),
            "root": try quoted(root), "credential_ref": try quoted(identity.reference.id.uuidString.lowercased()),
            "require_encryption": "true", "host_key_sha256": "null", "sftp_root_confined": "false",
            "connect_timeout_seconds": String(timeoutSeconds) + ".0",
            "operation_timeout_seconds": String(min(10, timeoutSeconds)) + ".0",
            "health_interval_seconds": "300.0", "backoff_initial_seconds": "1.0", "backoff_max_seconds": "60.0"]
        func hash(_ value: [String: String]) -> String {
            let text = "{" + value.keys.sorted().map { "\"" + $0 + "\":" + value[$0]! }.joined(separator: ",") + "}"
            return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        let configHash = hash(config)
        config = config.filter { ["transport", "host", "port", "share", "root", "require_encryption",
                                  "host_key_sha256", "sftp_root_confined"].contains($0.key) }
        return try JSONSerialization.data(withJSONObject: ["source_ref": sourceRef,
            "credential_ref": identity.reference.id.uuidString.lowercased(),
            "credential_generation": identity.generation.uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
            "config_generation": generation, "config_fingerprint": configHash, "root_descriptor_digest": hash(config)])
    }
}

public struct NASCredentialIdentity: Codable, Equatable, Sendable {
    public let reference: CredentialReference
    public let generation: UUID
    init(_ metadata: StoredMetadata) { reference = metadata.reference; generation = metadata.generation }
}

/// A validated private envelope. It is never a public DTO or logging object.
enum NASEnvelope {
    static func make(configuration: NASConnectionConfiguration, username: String, password: String) throws -> Data {
        _ = try configuration.validated()
        guard (1...256).contains(username.count), username.utf8.count <= 1024,
              !username.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              (1...8192).contains(password.count), password.utf8.count <= 32768,
              !password.contains("\0") else { throw CredentialError.invalidInput }
        return try JSONSerialization.data(withJSONObject: ["schema": 1,
            "endpoint_fingerprint": configuration.fingerprint, "username": username, "password": password],
            options: [.sortedKeys, .withoutEscapingSlashes])
    }
    static func make(endpoint: NASServerEndpoint, username: String, password: String) throws -> Data {
        _ = try endpoint.validated()
        guard (1...256).contains(username.count), username.utf8.count <= 1024,
              !username.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              (1...8192).contains(password.count), password.utf8.count <= 32768, !password.contains("\0")
        else { throw CredentialError.invalidInput }
        return try JSONSerialization.data(withJSONObject:["schema":2,"endpoint_fingerprint":endpoint.fingerprint,
            "username":username,"password":password],options:[.sortedKeys,.withoutEscapingSlashes])
    }
    static func validate(_ bytes: Data) throws {
        _ = try fields(bytes)
    }
    static func fields(_ bytes: Data) throws -> [String: Any] {
        guard bytes.count <= 65536,
              let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              Set(object.keys) == ["schema", "endpoint_fingerprint", "username", "password"],
              let schema = object["schema"] as? NSNumber, CFGetTypeID(schema) != CFBooleanGetTypeID(), (schema == 1 || schema == 2),
              let digest = object["endpoint_fingerprint"] as? String,
              digest.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              let username = object["username"] as? String, let password = object["password"] as? String,
              (1...256).contains(username.count), username.utf8.count <= 1024,
              !username.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              (1...8192).contains(password.count), password.utf8.count <= 32768,
              !password.contains("\0") else { throw CredentialError.invalidInput }
        return object
    }
}

public enum NASRuntimeFailure: String, Error, Sendable {
    case authenticationFailed = "nas_auth_failed", accessDenied = "nas_access_denied"
    case timeout = "nas_timeout", transportFailed = "nas_transport_failed", unavailable = "nas_unavailable"
    case dependencyMissing = "nas_dependency_missing", expired, cancelled, revoked
    case callerUnverified = "caller_unverified", sourceChanged = "source_changed"
    case credentialsUnavailable = "credentials_unavailable", credentialInvalid = "credential_invalid"
    case providerInvalid = "provider_invalid", referenceMismatch = "reference_mismatch"
    case invalidRequest = "nas_invalid_request", invalidReply = "invalid_reply"
    case objectUnknown = "nas_object_unknown", revisionChanged = "nas_revision_changed"
    case cursorExpired = "nas_cursor_expired", missing = "nas_missing", budgetExceeded = "nas_budget_exceeded"
    case nasSourceChanged = "nas_source_changed", nasBusy = "nas_busy"
}

public struct NASRuntimeState: Sendable, Equatable {
    public let connected: Bool
    public let readable: Bool
    public let epoch: String?
    public let failure: String?
    public let scopeJSON: Data?
    public init(connected: Bool = false, readable: Bool = false, epoch: String? = nil,
                failure: String? = nil, scopeJSON: Data? = nil) {
        self.connected = connected; self.readable = readable; self.epoch = epoch
        self.failure = failure; self.scopeJSON = scopeJSON
    }
}

/// Module-private effects interface: only the bundled runtime may consume a lease.
/// No arbitrary callback or return-secret method is exposed from the SDK.
protocol NASConnectionRuntime: Sendable {
    func connect(configuration: NASConnectionConfiguration, identity: NASCredentialIdentity,
                 secret: CredentialInput) async throws -> NASRuntimeState
    func status() async -> NASRuntimeState
    func readDirectory() async throws -> Data
    func fileOperation(_ request: NASFileRequest) async throws -> Data
    func browseDirectories(path: String, cursor: String?) async throws -> NASDirectoryPage
    func uploadNew(_ proposal: NASUploadProposal) async throws -> NASUploadResult
    func stop() async
    func authenticate(endpoint: NASServerEndpoint, identity: NASCredentialIdentity, secret: CredentialInput) async throws -> NASServerState
    func serverStatus() async -> NASServerState
    func listShares(cursor: String?) async throws -> NASServerState
    func previewDirectories(share: String, path: String, cursor: String?) async throws -> NASDirectoryPage
}

extension NASConnectionRuntime {
    func fileOperation(_ request: NASFileRequest) async throws -> Data { throw CredentialError.deploymentNotApproved }
    func authenticate(endpoint: NASServerEndpoint, identity: NASCredentialIdentity, secret: CredentialInput) async throws -> NASServerState { throw CredentialError.deploymentNotApproved }
    func serverStatus() async -> NASServerState { .init(failure:"nas_unavailable") }
    func listShares(cursor: String?) async throws -> NASServerState { throw CredentialError.deploymentNotApproved }
    func previewDirectories(share: String, path: String, cursor: String?) async throws -> NASDirectoryPage { throw CredentialError.deploymentNotApproved }
    func browseDirectories(path: String, cursor: String?) async throws -> NASDirectoryPage { throw CredentialError.deploymentNotApproved }
    func uploadNew(_ proposal: NASUploadProposal) async throws -> NASUploadResult { throw CredentialError.deploymentNotApproved }
}

/// Shares the existing login-Keychain repository, exact ACL, receipts and no-prompt
/// environment. Construction and cached state never inspect the Keychain.
public actor NASCredentialService {
    private let repository: any CredentialRepository
    private let runtime: (any NASConnectionRuntime)?
    private let enabled: Bool
    private var operation = UUID()
    private var busy = false
    private var active: NASCredentialIdentity?
    private var activeConfiguration: NASConnectionConfiguration?
    private var serverIdentity: NASCredentialIdentity?
    private var serverEndpoint: NASServerEndpoint?
    private var pendingUpload: NASUploadProposal?
    private var archiveMount: NASArchiveMount?
    init(repository: any CredentialRepository, runtime: (any NASConnectionRuntime)? = nil, enabled: Bool = false) {
        self.repository = repository; self.runtime = runtime; self.enabled = enabled
    }
    public func savedIdentity() throws -> NASCredentialIdentity? {
        guard enabled else { throw CredentialError.deploymentNotApproved }
        return try repository.metadata(.nasSMB).map(NASCredentialIdentity.init)
    }
    /// Uses the existing server credential, only for the explicitly selected
    /// Moments destination. No secret return value or consumer callback exists.
    public func connectArchive(_ destination: NASArchiveDestination) async throws -> NASArchiveMount {
        guard enabled, !busy else { throw CredentialError.busy }
        try destination.validated(); try current(destination.identity)
        if let mount = archiveMount, mount.destination == destination {
            do { try mount.verifyEncryption(); return mount } catch { archiveMount = nil }
        }
        busy = true; defer { busy = false }
        let repository = self.repository, identity = destination.identity
        let lease = try repository.lease(identity.reference); defer { lease.secret.clear() }
        guard NASCredentialIdentity(lease.metadata) == identity else { throw CredentialError.staleReference }
        var bytes = try lease.secret.copyBytes(for: .nasSMB); defer { bytes.resetBytes(in: 0..<bytes.count) }
        let envelope = try NASEnvelope.fields(bytes)
        guard (envelope["schema"] as? NSNumber)?.intValue == 2,
              envelope["endpoint_fingerprint"] as? String == destination.endpoint.fingerprint,
              let username = envelope["username"] as? String, let password = envelope["password"] as? String
        else { throw CredentialError.wrongPurpose }
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/ARL/Moments/mounts/" + destination.id.uuidString.lowercased())
        let mount = try await Task.detached(priority: .utility) {
            try NASArchiveMount.connect(destination: destination, root: root, username: username, password: password) {
                guard let current = try repository.metadata(.nasSMB), NASCredentialIdentity(current) == identity else { throw CredentialError.staleReference }
            }
        }.value
        try current(identity); try Task.checkCancellation()
        archiveMount = mount
        return mount
    }
    public func save(configuration: NASConnectionConfiguration, username: String, password: String,
                     replacing: NASCredentialIdentity?) async throws -> NASCredentialIdentity {
        guard enabled else { throw CredentialError.deploymentNotApproved }
        guard !busy else { throw CredentialError.busy }
        let input = try CredentialInput(purpose: .nasSMB,
            data: NASEnvelope.make(configuration: configuration, username: username, password: password))
        defer { input.clear() }
        busy = true; defer { busy = false }
        operation = UUID(); let captured = operation
        await runtime?.stop(); active = nil; activeConfiguration = nil; serverIdentity = nil; serverEndpoint = nil; pendingUpload = nil
        try Task.checkCancellation()
        guard operation == captured else { throw CancellationError() }
        let metadata: StoredMetadata
        if let replacing {
            try current(replacing)
            metadata = try repository.replace(replacing.reference, input: input)
        } else {
            guard try repository.metadata(.nasSMB) == nil else { throw CredentialError.alreadyConfigured }
            metadata = try repository.create(input, purpose: .nasSMB)
        }
        return NASCredentialIdentity(metadata)
    }
    private func current(_ identity: NASCredentialIdentity) throws {
        guard identity.reference.purpose == .nasSMB,
              let metadata = try repository.metadata(.nasSMB),
              NASCredentialIdentity(metadata) == identity else { throw CredentialError.staleReference }
    }
    public func connect(configuration: NASConnectionConfiguration, identity: NASCredentialIdentity) async throws -> NASRuntimeState {
        guard enabled, let runtime else { throw CredentialError.deploymentNotApproved }
        guard !busy else { throw CredentialError.busy }
        _ = try configuration.validated()
        busy = true; defer { busy = false }
        operation = UUID(); let captured = operation
        await runtime.stop(); active = nil; activeConfiguration = nil; serverIdentity = nil; serverEndpoint = nil; pendingUpload = nil
        try Task.checkCancellation()
        guard operation == captured else { throw CancellationError() }
        try current(identity)
        let lease = try repository.lease(identity.reference)
        defer { lease.secret.clear() }
        guard NASCredentialIdentity(lease.metadata) == identity else { throw CredentialError.staleReference }
        var bytes = try lease.secret.copyBytes(for: .nasSMB)
        defer { bytes.resetBytes(in: 0..<bytes.count) }
        let envelope = try NASEnvelope.fields(bytes)
        let expected = (envelope["schema"] as? NSNumber)?.intValue == 2
            ? try NASServerEndpoint(sourceRef: configuration.sourceRef, host: configuration.host, port: configuration.port,
                timeoutSeconds: configuration.timeoutSeconds, generation: configuration.generation).fingerprint
            : configuration.fingerprint
        guard envelope["endpoint_fingerprint"] as? String == expected else { throw CredentialError.wrongPurpose }
        do {
            let state = try await runtime.connect(configuration: configuration, identity: identity, secret: lease.secret)
            try Task.checkCancellation()
            guard operation == captured else { throw CancellationError() }
            try current(identity)
            active = state.connected ? identity : nil
            activeConfiguration = state.connected ? configuration : nil
            pendingUpload = nil
            return state
        } catch { await runtime.stop(); active = nil; throw error }
    }
    public func saveServer(endpoint: NASServerEndpoint, username: String, password: String,
                           replacing: NASCredentialIdentity?) async throws -> NASCredentialIdentity {
        guard enabled else { throw CredentialError.deploymentNotApproved }
        guard !busy else { throw CredentialError.busy }
        let input = try CredentialInput(purpose:.nasSMB, data:NASEnvelope.make(endpoint:endpoint,username:username,password:password))
        defer { input.clear() }
        busy = true; defer { busy = false }
        operation = UUID(); let captured = operation
        await runtime?.stop(); active = nil; activeConfiguration = nil; serverIdentity = nil; serverEndpoint = nil; pendingUpload = nil
        try Task.checkCancellation(); guard operation == captured else { throw CancellationError() }
        let metadata: StoredMetadata
        if let replacing { try current(replacing); metadata = try repository.replace(replacing.reference,input:input) }
        else { guard try repository.metadata(.nasSMB) == nil else { throw CredentialError.alreadyConfigured }; metadata = try repository.create(input,purpose:.nasSMB) }
        return NASCredentialIdentity(metadata)
    }
    public func authenticateServer(endpoint: NASServerEndpoint, identity: NASCredentialIdentity) async throws -> NASServerState {
        guard enabled, let runtime else { throw CredentialError.deploymentNotApproved }
        guard !busy else { throw CredentialError.busy }
        busy = true; defer { busy = false }
        operation = UUID(); let captured = operation
        await runtime.stop(); active = nil; activeConfiguration = nil; serverIdentity = nil; serverEndpoint = nil; pendingUpload = nil
        try current(identity); try Task.checkCancellation()
        let lease = try repository.lease(identity.reference); defer { lease.secret.clear() }
        guard NASCredentialIdentity(lease.metadata) == identity else { throw CredentialError.staleReference }
        var bytes = try lease.secret.copyBytes(for:.nasSMB); defer { bytes.resetBytes(in:0..<bytes.count) }
        let envelope = try NASEnvelope.fields(bytes)
        guard (envelope["schema"] as? NSNumber)?.intValue == 2,
              envelope["endpoint_fingerprint"] as? String == endpoint.fingerprint else { throw CredentialError.wrongPurpose }
        do {
            let value = try await runtime.authenticate(endpoint:endpoint,identity:identity,secret:lease.secret)
            try Task.checkCancellation(); guard operation == captured else { throw CancellationError() }; try current(identity)
            serverIdentity = value.authenticated ? identity : nil; serverEndpoint = value.authenticated ? endpoint : nil
            return value
        } catch { await runtime.stop(); throw error }
    }
    public func serverStatus() async -> NASServerState {
        guard enabled, let runtime, let identity = serverIdentity else { return .init() }
        let captured = operation
        do {
            try current(identity); let value = await runtime.serverStatus()
            guard captured == operation, serverIdentity == identity else { return .init(failure:"cancelled") }
            try current(identity); return value
        } catch { await runtime.stop(); serverIdentity = nil; serverEndpoint = nil; return .init(failure:"source_changed") }
    }
    public func listServerShares(cursor: String? = nil) async throws -> NASServerState {
        guard enabled, !busy, let runtime, let identity = serverIdentity else { throw CredentialError.missing }
        busy = true; defer { busy = false }; let captured = operation
        try current(identity); try Task.checkCancellation()
        let value = try await runtime.listShares(cursor:cursor)
        try Task.checkCancellation(); guard captured == operation, serverIdentity == identity else { throw CancellationError() }
        try current(identity); return value
    }
    public func previewServerDirectories(share: String, path: String, cursor: String? = nil) async throws -> NASDirectoryPage {
        guard enabled, !busy, let runtime, let identity = serverIdentity else { throw CredentialError.missing }
        _ = try NASShareRecord(name:share); try NASDirectoryPage.validatePath(path)
        busy = true; defer { busy = false }; let captured = operation
        try current(identity); try Task.checkCancellation()
        let value = try await runtime.previewDirectories(share:share,path:path,cursor:cursor)
        try Task.checkCancellation(); guard captured == operation, serverIdentity == identity, value.path == path else { throw CancellationError() }
        try current(identity); return value
    }
    public func status() async -> NASRuntimeState {
        guard enabled, let runtime else { return .init(failure: "unsupported") }
        guard let identity = active else { return .init() }
        do {
            try current(identity)
            let captured = operation
            let result = await runtime.status()
            guard operation == captured, active == identity else { return .init(failure: "cancelled") }
            try current(identity)
            return result
        } catch { await runtime.stop(); active = nil; return .init(failure: "source_changed") }
    }
    public func readDirectory() async throws -> Data {
        guard enabled, let runtime, let identity = active else { throw CredentialError.missing }
        guard !busy else { throw CredentialError.busy }
        busy = true; defer { busy = false }
        let captured = operation
        do {
            try current(identity)
            let result = try await runtime.readDirectory()
            try Task.checkCancellation()
            guard operation == captured, active == identity else { throw CancellationError() }
            try current(identity)
            return result
        } catch { await runtime.stop(); active = nil; throw error }
    }
    /// Revalidate a cached read against the same live configuration, identity
    /// and epoch. No credential resolution, file read, reconnect or scope save.
    public func validateReadContext(sourceRef:String,generation:UInt64,epoch:String) async throws {
        guard enabled,let runtime,let identity=active,let configuration=activeConfiguration,
              configuration.sourceRef==sourceRef,configuration.generation==generation else {throw NASRuntimeFailure.sourceChanged}
        guard !busy else {throw CredentialError.busy}
        busy=true;defer{busy=false}
        let captured=operation
        try current(identity);try Task.checkCancellation()
        let state=await runtime.status()
        try current(identity);try Task.checkCancellation()
        guard operation==captured,active==identity,activeConfiguration==configuration,
              state.connected,state.readable,state.epoch==epoch else {throw NASRuntimeFailure.sourceChanged}
    }
    public func consumeFileRead(_ request: NASFileRequest) async throws -> Data {
        guard enabled, let runtime, let identity = active, let configuration = activeConfiguration else { throw CredentialError.missing }
        guard !busy else { throw CredentialError.busy }
        busy = true; defer { busy = false }
        let captured = operation
        do {
            try current(identity); try Task.checkCancellation()
            let before = await runtime.status()
            guard captured == operation, active == identity, activeConfiguration == configuration,
                  before.connected, before.readable, let epoch = before.epoch else { throw NASRuntimeFailure.sourceChanged }
            try current(identity); try Task.checkCancellation()
            let value = try await runtime.fileOperation(request)
            try Task.checkCancellation(); try current(identity)
            guard captured == operation, active == identity, activeConfiguration == configuration else { throw CancellationError() }
            try request.validateResult(value, configuration: configuration, epoch: epoch)
            return value
        } catch {
            // Finite request errors keep a healthy session; authority/cancellation failures close it.
            let recoverable: Set<NASRuntimeFailure> = [.invalidRequest, .objectUnknown, .revisionChanged, .cursorExpired, .missing, .budgetExceeded, .nasSourceChanged, .nasBusy]
            if operation == captured, !recoverable.contains(error as? NASRuntimeFailure ?? .transportFailed) {
                await runtime.stop(); active = nil; activeConfiguration = nil
            }
            throw error
        }
    }

    public func browseDirectories(path: String, cursor: String? = nil) async throws -> NASDirectoryPage {
        guard enabled, let runtime, let identity = active else { throw CredentialError.missing }
        guard !busy else { throw CredentialError.busy }
        try NASDirectoryPage.validatePath(path)
        busy = true; defer { busy = false }
        let captured = operation
        do {
            try current(identity); try Task.checkCancellation()
            let result = try await runtime.browseDirectories(path: path, cursor: cursor)
            try Task.checkCancellation()
            guard operation == captured, active == identity, result.path == path else { throw CancellationError() }
            try current(identity)
            return result
        } catch {
            if operation == captured { await runtime.stop(); active = nil }
            throw error
        }
    }
    public func prepareUploadTest(directory: String) throws -> NASUploadProposal {
        guard enabled, !busy, let identity = active, let config = activeConfiguration else { throw CredentialError.missing }
        try current(identity)
        let proposal = try NASUploadProposal(configuration: config, identity: identity, directory: directory)
        pendingUpload = proposal
        return proposal
    }
    /// Called only by the native exact-target confirmation flow. The opaque
    /// proposal must be the same live object prepared by this owner.
    public func uploadTestAfterConfirmation(_ proposal: NASUploadProposal) async throws -> NASUploadResult {
        guard enabled, !busy, let runtime, pendingUpload === proposal, active == proposal.identity,
              activeConfiguration == proposal.configuration, ProcessInfo.processInfo.systemUptime < proposal.expires
        else { throw CredentialError.staleReference }
        pendingUpload = nil; busy = true
        defer { busy = false }
        try current(proposal.identity); try Task.checkCancellation()
        let captured = operation
        do {
            let result = try await runtime.uploadNew(proposal)
            guard captured == operation else { throw CancellationError() }
            try current(proposal.identity); try Task.checkCancellation()
            return result
        } catch {
            await runtime.stop(); active = nil; activeConfiguration = nil
            // A lost response can never authorize a retry or imply no effect.
            return .init(status: "uncertain", failure: "io_uncertain")
        }
    }
    public func stop() async {
        activeConfiguration = nil; pendingUpload = nil
        operation = UUID(); active = nil; serverIdentity = nil; serverEndpoint = nil
        await runtime?.stop()
    }
}
