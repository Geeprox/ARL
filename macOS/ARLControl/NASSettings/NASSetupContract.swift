import Foundation
import Dispatch

// Public DTOs carry configuration and finite metadata only. Native credentials
// stay in the separate, main-actor-only consumer seam at the end of this file.
public enum ARLNASFault: String, Error, Sendable, Encodable {
    case hostNotConfigured, nativeNASPurposeUnavailable, nativeResolverUnavailable
    case invalidConfiguration, configurationNotSaved, configurationChanged
    case credentialNotSaved, credentialEntryUnavailable, bindingMismatch
    case staleGeneration, callerRejected, manualIntentRequired, operationInProgress
    case authenticationRequired, userCancelled, connectionFailed, readDenied
    case writeUnsupported, writeDenied, writeOutcomeUncertain
    case disabled, sourceChanged, referenceMismatch, revoked, expired, budgetExhausted
    case ticketInvalid, providerInvalid, credentialsUnavailable, credentialInvalid
    case authenticationFailed, accessDenied, hostKeyMismatch, transportTimeout, transportFailed
    case protocolUnsupported, manualIntentExpired
}

public struct ARLNASOpaqueReference: Equatable, Sendable, Encodable {
    public let rawValue: String

    public init(_ value: String) throws {
        let bytes = value.utf8
        guard (1...128).contains(bytes.count), bytes.allSatisfy({
            (48...57).contains($0) || (65...90).contains($0) ||
            (97...122).contains($0) || $0 == 95 || $0 == 45
        }) else { throw ARLNASFault.bindingMismatch }
        rawValue = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct ARLNASSHA256Digest: Equatable, Sendable, Encodable {
    public let rawValue: String

    public init(_ value: String) throws {
        guard value.utf8.count == 64, value.utf8.allSatisfy({
            (48...57).contains($0) || (97...102).contains($0)
        }) else { throw ARLNASFault.bindingMismatch }
        rawValue = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct ARLNASCredentialGeneration: Equatable, Sendable, Encodable {
    public let rawValue: String

    public init(_ value: String) throws {
        guard value.utf8.count == 32, value.utf8.allSatisfy({
            (48...57).contains($0) || (97...102).contains($0)
        }) else { throw ARLNASFault.bindingMismatch }
        rawValue = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum ARLNASTransport: String, CaseIterable, Sendable, Encodable {
    case smb, sftp
}

public enum ARLNASApplicationScope: String, CaseIterable, Sendable, Encodable {
    case readOnly = "read_only"
    case readWriteRequested = "read_write_requested"
}

public struct ARLNASAdvancedOptions: Equatable, Sendable, Encodable {
    public let automaticReadRetries: Int
    public let connectionTimeoutSeconds: Int
    public let maximumConcurrentReads: Int

    public init(automaticReadRetries: Int = 0, connectionTimeoutSeconds: Int = 8,
                maximumConcurrentReads: Int = 1) throws {
        guard automaticReadRetries == 0,
              (1...30).contains(connectionTimeoutSeconds),
              maximumConcurrentReads == 1
        else { throw ARLNASFault.invalidConfiguration }
        self.automaticReadRetries = automaticReadRetries
        self.connectionTimeoutSeconds = connectionTimeoutSeconds
        self.maximumConcurrentReads = maximumConcurrentReads
    }
}

public struct ARLNASConfiguration: Equatable, Sendable, Encodable {
    public let address: String
    public let addressInput: String
    public let port: Int
    public let transport: ARLNASTransport
    public let share: String
    public let root: String
    public let applicationScope: ARLNASApplicationScope
    public let advanced: ARLNASAdvancedOptions
    public let requireEncryption: Bool = true

    public init(address: String, transport: ARLNASTransport, share: String,
                root: String, applicationScope: ARLNASApplicationScope,
                advanced: ARLNASAdvancedOptions, port: Int = 445) throws {
        // SFTP needs exact host-key and root-confinement fields, absent in this
        // deliberately SMB-only projection. It cannot be saved or tested here.
        guard transport == .smb else { throw ARLNASFault.protocolUnsupported }
        let parsed = try NASAddressInput(address, port: port)
        let hostBytes = parsed.host.utf8
        guard (1...253).contains(hostBytes.count), hostBytes.allSatisfy({
            (48...57).contains($0) || (65...90).contains($0) ||
            (97...122).contains($0) || [45, 46, 58, 91, 93].contains($0)
        }), (1...65535).contains(port), !share.isEmpty, share.utf8.count <= 255,
              !share.contains(where: { $0 == "/" || $0 == "\\" || $0.isNewline }),
              !share.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !root.hasPrefix("/"), root.utf8.count <= 1024,
              !root.contains("\\"), !root.contains("//"),
              !root.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !root.hasSuffix("/"),
              !root.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
        else { throw ARLNASFault.invalidConfiguration }
        self.addressInput = parsed.original
        self.address = parsed.host
        self.port = parsed.port
        self.transport = transport
        self.share = share
        self.root = root
        self.applicationScope = applicationScope
        self.advanced = advanced
    }
}

public struct ARLNASReadScope: Equatable, Sendable, Encodable {
    public static let serviceID = "arl.nas.read-session.v1"
    public let service: String = ARLNASReadScope.serviceID
    public let sourceRef: ARLNASOpaqueReference
    public let credentialRef: ARLNASOpaqueReference
    public let configFingerprint: ARLNASSHA256Digest
    public let rootDescriptorDigest: ARLNASSHA256Digest
    public let configGeneration: UInt64
    public let credentialGeneration: ARLNASCredentialGeneration

    public init(sourceRef: ARLNASOpaqueReference, credentialRef: ARLNASOpaqueReference,
                configFingerprint: ARLNASSHA256Digest,
                rootDescriptorDigest: ARLNASSHA256Digest, configGeneration: UInt64,
                credentialGeneration: ARLNASCredentialGeneration) throws {
        guard configGeneration > 0, configGeneration <= UInt64(Int64.max),
              sourceRef.rawValue.utf8.count <= 96 else { throw ARLNASFault.staleGeneration }
        self.sourceRef = sourceRef
        self.credentialRef = credentialRef
        self.configFingerprint = configFingerprint
        self.rootDescriptorDigest = rootDescriptorDigest
        self.configGeneration = configGeneration
        self.credentialGeneration = credentialGeneration
    }

    private enum CodingKeys: String, CodingKey {
        case service, sourceRef = "source_ref", credentialRef = "credential_ref"
        case configFingerprint = "config_fingerprint"
        case rootDescriptorDigest = "root_descriptor_digest"
        case configGeneration = "config_generation"
        case credentialGeneration = "credential_generation"
    }
}

// Passive host observations, not caller-provided identity and not authentication.
// The host owns the complete CallerPins and live HostAuthorizer.verify checks.
public struct ARLNASObservedCallerPins: Equatable, Sendable {
    public let executableDigest: ARLNASSHA256Digest
    public let designatedRequirementDigest: ARLNASSHA256Digest
    public let registrationEpoch: ARLNASOpaqueReference

    public init(executableDigest: ARLNASSHA256Digest,
                designatedRequirementDigest: ARLNASSHA256Digest,
                registrationEpoch: ARLNASOpaqueReference) {
        self.executableDigest = executableDigest
        self.designatedRequirementDigest = designatedRequirementDigest
        self.registrationEpoch = registrationEpoch
    }
}

public enum ARLNASManualAction: String, CaseIterable, Sendable, Encodable {
    case saveConfiguration = "save_configuration"
    case saveCredential = "save_credential"
    case testConnection = "test_connection"
    case testRead = "test_read"
    case testWrite = "test_write"
    case reconnect, stop
}

public enum ARLNASAdmission: Equatable, Sendable {
    case allowed
    case held(ARLNASFault)
    case unsupported(ARLNASFault)

    public var isAllowed: Bool {
        if case .allowed = self { return true }
        return false
    }

    public var fault: ARLNASFault? {
        switch self {
        case .allowed: return nil
        case .held(let fault), .unsupported(let fault): return fault
        }
    }
}

public struct ARLNASActionAvailability: Equatable, Sendable {
    public let saveConfiguration: ARLNASAdmission
    public let saveCredential: ARLNASAdmission
    public let testConnection: ARLNASAdmission
    public let testRead: ARLNASAdmission
    public let reconnect: ARLNASAdmission
    public let stop: ARLNASAdmission

    public init(saveConfiguration: ARLNASAdmission, saveCredential: ARLNASAdmission,
                testConnection: ARLNASAdmission, testRead: ARLNASAdmission,
                reconnect: ARLNASAdmission, stop: ARLNASAdmission = .held(.hostNotConfigured)) {
        self.saveConfiguration = saveConfiguration
        self.saveCredential = saveCredential
        self.testConnection = testConnection
        self.testRead = testRead
        self.reconnect = reconnect
        self.stop = stop
    }

    public func admission(for action: ARLNASManualAction) -> ARLNASAdmission {
        switch action {
        case .saveConfiguration: return saveConfiguration
        case .saveCredential: return saveCredential
        case .testConnection: return testConnection
        case .testRead: return testRead
        case .testWrite: return .unsupported(.writeUnsupported)
        case .reconnect: return reconnect
        case .stop: return stop
        }
    }
}

public enum ARLNASProviderState: String, Sendable {
    case available, held, unsupported
}

public enum ARLNASFact: Equatable, Sendable {
    case unknown
    case verified
    case held(ARLNASFault)
    case failed(ARLNASFault)
    case unsupported(ARLNASFault)
    case uncertainWrite
}

public enum ARLNASStatusField: CaseIterable, Hashable, Sendable {
    case configurationSaved, credentialReferenceSaved, credentialAvailable
    case connected, readable, writable
}

public struct ARLNASSetupSnapshot: Equatable, Sendable {
    public let revision: UInt64
    public let provider: ARLNASProviderState
    public let availability: ARLNASActionAvailability
    public let configuration: ARLNASConfiguration?
    public let currentConfigurationGeneration: UInt64
    public let readScope: ARLNASReadScope?
    public let observedCallerPins: ARLNASObservedCallerPins?
    public let connectionEpoch: ARLNASOpaqueReference?
    public let configurationSaved: ARLNASFact
    public let credentialReferenceSaved: ARLNASFact
    public let credentialAvailable: ARLNASFact
    public let connected: ARLNASFact
    public let readable: ARLNASFact
    public let writable: ARLNASFact

    public init(revision: UInt64, provider: ARLNASProviderState,
                availability: ARLNASActionAvailability,
                configuration: ARLNASConfiguration? = nil,
                currentConfigurationGeneration: UInt64 = 0,
                readScope: ARLNASReadScope? = nil,
                observedCallerPins: ARLNASObservedCallerPins? = nil,
                connectionEpoch: ARLNASOpaqueReference? = nil,
                configurationSaved: ARLNASFact = .unknown,
                credentialReferenceSaved: ARLNASFact = .unknown,
                credentialAvailable: ARLNASFact = .unknown,
                connected: ARLNASFact = .unknown, readable: ARLNASFact = .unknown,
                writable: ARLNASFact = .unsupported(.writeUnsupported)) {
        self.revision = revision
        self.provider = provider
        self.availability = availability
        self.configuration = configuration
        self.currentConfigurationGeneration = currentConfigurationGeneration
        self.readScope = readScope
        self.observedCallerPins = observedCallerPins
        self.connectionEpoch = connectionEpoch
        let hasCurrentConfig = configuration != nil && currentConfigurationGeneration > 0
            && currentConfigurationGeneration <= UInt64(Int64.max)
        self.configurationSaved = hasCurrentConfig ? configurationSaved : .unknown
        let isBound = hasCurrentConfig && readScope != nil && observedCallerPins != nil
            && readScope?.configGeneration == currentConfigurationGeneration
        self.credentialReferenceSaved = configuration == nil || readScope == nil
            ? .unknown : credentialReferenceSaved
        self.credentialAvailable = !isBound && credentialAvailable == .verified
            ? .unknown : credentialAvailable
        let hasSession = isBound && connectionEpoch != nil
        self.connected = !hasSession && connected == .verified ? .unknown : connected
        self.readable = !hasSession && readable == .verified ? .unknown : readable
        // This contract has no write service or authorization; never report success.
        self.writable = writable == .uncertainWrite ? .uncertainWrite : .unsupported(.writeUnsupported)
    }

    public func fact(for field: ARLNASStatusField) -> ARLNASFact {
        switch field {
        case .configurationSaved: return configurationSaved
        case .credentialReferenceSaved: return credentialReferenceSaved
        case .credentialAvailable: return credentialAvailable
        case .connected: return connected
        case .readable: return readable
        case .writable: return writable
        }
    }

    public static var unsupported: ARLNASSetupSnapshot {
        let unavailable = ARLNASAdmission.unsupported(.nativeNASPurposeUnavailable)
        return ARLNASSetupSnapshot(revision: 0, provider: .unsupported,
            availability: ARLNASActionAvailability(
                saveConfiguration: .held(.hostNotConfigured), saveCredential: unavailable,
                testConnection: unavailable, testRead: unavailable, reconnect: unavailable),
            credentialAvailable: .unsupported(.nativeNASPurposeUnavailable),
            connected: .unsupported(.nativeNASPurposeUnavailable),
            readable: .unsupported(.nativeNASPurposeUnavailable))
    }
}

public struct ARLNASActionRequest: Equatable, Sendable, Encodable {
    public let action: ARLNASManualAction
    public let configuration: ARLNASConfiguration
    public let expectedSnapshotRevision: UInt64
    public let expectedConfigurationGeneration: UInt64
    public let readScope: ARLNASReadScope?

    public init(action: ARLNASManualAction, configuration: ARLNASConfiguration,
                expectedSnapshotRevision: UInt64, expectedConfigurationGeneration: UInt64,
                readScope: ARLNASReadScope?) {
        self.action = action
        self.configuration = configuration
        self.expectedSnapshotRevision = expectedSnapshotRevision
        self.expectedConfigurationGeneration = expectedConfigurationGeneration
        self.readScope = readScope
    }
}

// An in-process indication of a specific click, never an RPC bearer credential.
// The receiving host must consume once AND independently authorize actual caller.
@MainActor
public final class ARLNASManualIntent {
    public static let maximumLifetimeSeconds: UInt64 = 30
    public let id: UUID
    public let request: ARLNASActionRequest
    public var action: ARLNASManualAction { request.action }
    private var wasConsumed = false
    private let deadlineUptimeNanoseconds: UInt64

    public var hasExpired: Bool {
        DispatchTime.now().uptimeNanoseconds >= deadlineUptimeNanoseconds
    }

    internal init(request: ARLNASActionRequest) {
        id = UUID()
        self.request = request
        let deadline = DispatchTime.now().uptimeNanoseconds.addingReportingOverflow(
            Self.maximumLifetimeSeconds * 1_000_000_000)
        deadlineUptimeNanoseconds = deadline.overflow ? 0 : deadline.partialValue
    }

    public func consume(for request: ARLNASActionRequest) -> Bool {
        guard !wasConsumed, !hasExpired, self.request == request else { return false }
        wasConsumed = true
        return true
    }
}

public enum ARLNASActionOutcome: Equatable, Sendable {
    case applied
    case held(ARLNASFault)
    case unsupported(ARLNASFault)
    case failed(ARLNASFault)
    case uncertainWrite

    public var fault: ARLNASFault? {
        switch self {
        case .applied: return nil
        case .held(let fault), .unsupported(let fault), .failed(let fault): return fault
        case .uncertainWrite: return .writeOutcomeUncertain
        }
    }
}

public struct ARLNASActionReply: Equatable, Sendable {
    public let request: ARLNASActionRequest
    public let outcome: ARLNASActionOutcome
    public let snapshot: ARLNASSetupSnapshot

    public init(request: ARLNASActionRequest, outcome: ARLNASActionOutcome,
                snapshot: ARLNASSetupSnapshot) {
        self.request = request
        self.outcome = outcome
        self.snapshot = snapshot
    }
}

public enum ARLNASGenerationSemantics: Sendable { case managerTransitions, configurationChanges }

@MainActor
public protocol ARLNASSetupBackend: AnyObject {
    var generationSemantics: ARLNASGenerationSemantics { get }
    // Cache read ONLY: no network, provider lookup, native calls, login or prompts.
    func cachedSnapshot() -> ARLNASSetupSnapshot
    func perform(_ request: ARLNASActionRequest,
                 manualIntent: ARLNASManualIntent) async -> ARLNASActionReply
}

public extension ARLNASSetupBackend {
    var generationSemantics: ARLNASGenerationSemantics { .managerTransitions }
}

@MainActor
public final class ARLNASUnsupportedBackend: ARLNASSetupBackend {
    public init() {}

    public func cachedSnapshot() -> ARLNASSetupSnapshot { .unsupported }

    public func perform(_ request: ARLNASActionRequest,
                        manualIntent: ARLNASManualIntent) async -> ARLNASActionReply {
        guard manualIntent.consume(for: request) else {
            return ARLNASActionReply(request: request, outcome: .held(.manualIntentRequired),
                                     snapshot: .unsupported)
        }
        let outcome: ARLNASActionOutcome = request.action == .saveConfiguration
            ? .held(.hostNotConfigured)
            : .unsupported(request.action == .testWrite
                ? .writeUnsupported : .nativeNASPurposeUnavailable)
        return ARLNASActionReply(request: request, outcome: outcome, snapshot: .unsupported)
    }
}

// Not Codable; not part of action DTOs, snapshots, logs, model or MCP boundaries.
// Swift Strings/frameworks may retain copies: clear() does NOT promise zeroization.
@MainActor
public final class ARLNASCredentialInput: CustomStringConvertible,
                                          CustomDebugStringConvertible, CustomReflectable {
    private var username: String
    private var password: String
    private var cleared = false

    public init(username: String, password: String) {
        self.username = username
        self.password = password
    }

    public var hasMaterial: Bool { !cleared && !username.isEmpty && !password.isEmpty }

    // Only the trusted native host consumer may use this synchronous in-process seam.
    // Do not return, log, serialize, persist or send either value to a model/RPC.
    @discardableResult
    public func consume(_ body: (_ username: String, _ password: String) -> Void) -> Bool {
        guard hasMaterial else { clear(); return false }
        defer { clear() }
        body(username, password)
        return true
    }

    public func clear() {
        username.removeAll(keepingCapacity: false)
        password.removeAll(keepingCapacity: false)
        cleared = true
    }

    nonisolated public var description: String { "<ARLNASCredentialInput: redacted>" }
    nonisolated public var debugDescription: String { description }
    nonisolated public var customMirror: Mirror {
        Mirror(self, children: ["material": "redacted"])
    }
}

@MainActor
public protocol ARLNASCredentialConsumer: AnyObject {
    // Must consume the one-shot intent and pass the host's live identity/scope
    // checks before handing material to an approved existing native NAS provider.
    // No such production provider is implemented or injected by this package.
    func save(_ input: ARLNASCredentialInput, request: ARLNASActionRequest,
              manualIntent: ARLNASManualIntent) async -> ARLNASActionReply
}
