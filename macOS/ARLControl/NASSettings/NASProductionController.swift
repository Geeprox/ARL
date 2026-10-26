import Foundation
import Darwin
import SwiftUI
import CryptoKit
import Security
import ARLCredentialOnboarding

/// Concrete in-process controller. UI intent, credential owner and manager scope
/// remain separate; neither a cached configuration nor a Boolean grants access.
@MainActor
protocol NASUploadUIOwner: AnyObject {
    func prepareUploadTest(directory: String) async throws -> NASUploadProposal
    func uploadTestAfterConfirmation(_ proposal: NASUploadProposal) async throws -> NASUploadResult
}

@MainActor
final class NASProductionController: ARLNASSetupBackend, ARLNASCredentialConsumer, NASUploadUIOwner, NASDirectoryUIOwner, NASServerSetupOwner, NASFileUIOwner, NASArchivePickerOwner {
    private struct Record: Codable {
        var schema = 1
        var configuration: NASConnectionConfiguration
        var identity: NASCredentialIdentity?
        var credentialFingerprint: String?
        var revision: UInt64
        var originalAddress: String?
    }
    private struct ServerRecord: Codable {
        var schema = 2
        var endpoint: NASServerEndpoint
        var originalAddress: String
        var identity: NASCredentialIdentity
        var revision: UInt64
    }
    private var serverRecord: ServerRecord?
    private var serverState=NASServerState()
    private var serverDeadline:Double=0
    private var serverDirectory: NASDirectoryPage?
    private var previewShare: String?
    private var serverIntentID: UUID?
    private var shareNames: [NASShareRecord]=[]
    private var serverPath:URL {path.deletingLastPathComponent().appendingPathComponent("server-login-v2.json")}
    var generationSemantics: ARLNASGenerationSemantics { .configurationChanges }
    private let owner: NASCredentialService
    private let path: URL
    private let enabled: Bool
    private let pins: ARLNASObservedCallerPins?
    private var record: Record?
    private var revision: UInt64 = 0
    private var state = NASRuntimeState()
    private var serial = UUID()
    private var fileOperationID: UUID?
    private var polling: Task<Void, Never>?
    private var failure: ARLNASFault?
    private var failureDiagnostic: String?

    init(owner: NASCredentialService, home: URL, enabled: Bool) {
        self.owner = owner; self.enabled = enabled
        path = home.appendingPathComponent("nas/settings-v1.json")
        pins = enabled ? Self.ownPins() : nil
        guard enabled else { return }
        if let data = try? Self.read(path), let value = try? JSONDecoder().decode(Record.self, from: data),
           value.schema == 1, value.revision < UInt64(Int64.max),
           let address = try? NASAddressInput(value.originalAddress ?? value.configuration.host, port: value.configuration.port),
           address.host == value.configuration.host, address.port == value.configuration.port,
           value.identity == nil || value.identity?.reference.purpose == .nasSMB,
           let checked = try? NASConnectionConfiguration(sourceRef: value.configuration.sourceRef,
                host: value.configuration.host, port: value.configuration.port, share: value.configuration.share,
                root: value.configuration.root, timeoutSeconds: value.configuration.timeoutSeconds,
                generation: value.configuration.generation), checked == value.configuration {
            record = value; revision = value.revision
        }
        if let data=try? Self.read(serverPath),let saved=try? JSONDecoder().decode(ServerRecord.self,from:data),
           saved.schema==2,saved.identity.reference.purpose == .nasSMB,saved.revision < UInt64(Int64.max),
           let address=try? NASAddressInput(saved.originalAddress,port:saved.endpoint.port),
           address.host==saved.endpoint.host,address.port==saved.endpoint.port,
           let checked=try? NASServerEndpoint(sourceRef:saved.endpoint.sourceRef,host:saved.endpoint.host,port:saved.endpoint.port,timeoutSeconds:saved.endpoint.timeoutSeconds,generation:saved.endpoint.generation),checked==saved.endpoint {
            serverRecord=saved;revision=max(revision,saved.revision)
        }
    }
    private static func ownPins() -> ARLNASObservedCallerPins? {
        var code: SecCode?, staticCode: SecStaticCode?, requirement: SecRequirement?, text: CFString?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess, let requirement,
              SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text,
              let executable = Bundle.main.executableURL, let bytes = try? Data(contentsOf: executable) else { return nil }
        func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
        return try? .init(executableDigest: .init(digest(bytes)), designatedRequirementDigest: .init(digest(Data((text as String).utf8))),
                          registrationEpoch: .init(UUID().uuidString.lowercased()))
    }
    private static func read(_ path: URL) throws -> Data {
        guard path.standardizedFileURL.path == path.resolvingSymlinksInPath().path else { throw ARLNASFault.invalidConfiguration }
        let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,
              ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 32768 else { throw ARLNASFault.invalidConfiguration }
        return try Data(contentsOf: path)
    }
    private func persist<T:Encodable>(_ value: T,to target:URL?=nil) throws {
        let path=target ?? self.path
        guard path.standardizedFileURL.path == path.resolvingSymlinksInPath().path else { throw ARLNASFault.invalidConfiguration }
        let directory = path.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700 else { throw ARLNASFault.invalidConfiguration }
        if FileManager.default.fileExists(atPath: path.path) { _ = try Self.read(path) }
        let bytes = try JSONEncoder().encode(value)
        let temporary = directory.appendingPathComponent(".settings-" + UUID().uuidString.lowercased())
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw ARLNASFault.invalidConfiguration }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let handle = try FileHandle(forWritingTo: temporary)
        do { try handle.write(contentsOf: bytes); try handle.synchronize(); try handle.close() }
        catch { try? handle.close(); throw error }
        guard rename(temporary.path, path.path) == 0 else { throw ARLNASFault.invalidConfiguration }
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ARLNASFault.invalidConfiguration }
        defer { Darwin.close(fd) }
        guard fsync(fd) == 0 else { throw ARLNASFault.invalidConfiguration }
    }
    private func credentialMatchesScope() -> Bool {
        guard let record,record.identity != nil else{return false}
        if record.credentialFingerprint==record.configuration.fingerprint{return true}
        guard let serverRecord,record.identity==serverRecord.identity,
              let endpoint=try? NASServerEndpoint(sourceRef:record.configuration.sourceRef,host:record.configuration.host,port:record.configuration.port,timeoutSeconds:record.configuration.timeoutSeconds,generation:record.configuration.generation)
        else{return false}
        return record.credentialFingerprint==endpoint.fingerprint && endpoint.fingerprint==serverRecord.endpoint.fingerprint
    }
    func serverSetupSnapshot() -> NASServerSetupSnapshot {
        if serverState.authenticated && ProcessInfo.processInfo.systemUptime >= serverDeadline {
            serverState = .init(failure:"expired");serverDirectory=nil;previewShare=nil;shareNames=[]
        }
        let granted=record.map {$0.configuration.host+":"+String($0.configuration.port)+"/"+$0.configuration.share+($0.configuration.root.isEmpty ? "" : "/"+$0.configuration.root)}
        return .init(address:serverRecord?.originalAddress ?? "",port:serverRecord?.endpoint.port ?? 445,
            timeoutSeconds:serverRecord?.endpoint.timeoutSeconds ?? 8,saved:serverRecord != nil,
            state:serverState,directory:serverDirectory,share:previewShare,authorizedScope:granted,
            busy:serverIntentID != nil,fault:failure,diagnostic:failureDiagnostic)
    }
    func archiveDestination() async throws -> NASArchiveDestination {
        guard enabled, pins != nil, serverIntentID == nil, fileOperationID == nil,
              let saved = serverRecord,
              let page = serverDirectory, let share = previewShare,
              shareNames.contains(where: { $0.name == share }) else { throw ARLNASFault.bindingMismatch }
        // A user may confirm a previously browsed location after the short
        // metadata session expires. This only records a selection. connectArchive
        // independently obtains a current credential lease and proves the real
        // encrypted mount before any write; cached metadata is never authority.
        let identity = try await owner.savedIdentity()
        guard identity == saved.identity, serverRecord?.identity == saved.identity,
              serverDirectory?.path == page.path, previewShare == share else { throw ARLNASFault.sourceChanged }
        return try NASArchiveDestination(endpoint: saved.endpoint, identity: saved.identity, share: share, directory: page.path)
    }
    func connectArchive(_ destination: NASArchiveDestination) async throws -> NASArchiveMount {
        guard enabled, pins != nil, let saved = serverRecord,
              destination.endpoint == saved.endpoint, destination.identity == saved.identity else { throw ARLNASFault.sourceChanged }
        return try await owner.connectArchive(destination)
    }
    func beginServerAction(_ action:NASServerSetupAction) -> NASServerSetupIntent? {
        guard enabled,pins != nil else{failure = .hostNotConfigured;return nil}
        guard action == .stop || (serverIntentID == nil && fileOperationID == nil) else{failure = .operationInProgress;return nil}
        guard revision < UInt64(Int64.max) else{failure = .staleGeneration;return nil}
        let intent=NASServerSetupIntent(action:action,revision:revision)
        serverIntentID=intent.id;failure=nil;failureDiagnostic=nil
        return intent
    }
    func performServerAction(_ intent:NASServerSetupIntent,input:ARLNASCredentialInput?) async {
        defer{input?.clear();if serverIntentID==intent.id {serverIntentID=nil}}
        guard serverIntentID==intent.id,intent.revision==revision,intent.consume() else{failure = .manualIntentExpired;return}
        polling?.cancel();serial=UUID();let captured=serial
        func current() throws {
            guard serverIntentID==intent.id,serial==captured else{throw CancellationError()}
            try Task.checkCancellation()
        }
        var username="",password="";defer{username="";password=""}
        do {
            try current()
            switch intent.action {
            case .save(let address,let port,let timeout):
                let normalized=try NASAddressInput(address,port:port)
                let endpoint=try NASServerEndpoint(sourceRef:serverRecord?.endpoint.sourceRef ?? UUID().uuidString.lowercased(),host:normalized.host,port:normalized.port,timeoutSeconds:timeout,generation:(serverRecord?.endpoint.generation ?? 0)+1)
                guard let input,input.consume({username=$0;password=$1}) else{throw ARLNASFault.credentialInvalid}
                let replacing=try await owner.savedIdentity();try current()
                let identity=try await owner.saveServer(endpoint:endpoint,username:username,password:password,replacing:replacing);try current()
                let next=ServerRecord(endpoint:endpoint,originalAddress:address,identity:identity,revision:revision+1)
                try persist(next,to:serverPath);serverRecord=next;revision=next.revision
                serverState = .init();state = .init();serverDirectory=nil;previewShare=nil;shareNames=[]
            case .login:
                guard let saved=serverRecord else{throw ARLNASFault.credentialNotSaved}
                let started=ProcessInfo.processInfo.systemUptime
                let next=try await owner.authenticateServer(endpoint:saved.endpoint,identity:saved.identity);try current()
                guard next.authenticated else{throw ARLNASFault.connectionFailed}
                serverState=next;serverDeadline=started+120;state = .init();serverDirectory=nil;previewShare=nil;shareNames=[];revision+=1
            case .shares(let cursor):
                guard serverState.authenticated else{throw ARLNASFault.connectionFailed}
                let epoch=serverState.epoch
                let next=try await owner.listServerShares(cursor:cursor);try current()
                guard next.authenticated,next.epoch==epoch else{throw ARLNASFault.sourceChanged}
                if cursor==nil {shareNames=[];serverDirectory=nil;previewShare=nil}
                for share in next.shares where !shareNames.contains(share) {shareNames.append(share)}
                guard shareNames.count<=1024 else{throw ARLNASFault.bindingMismatch}
                serverState = .init(authenticated:true,epoch:next.epoch,shares:shareNames,nextCursor:next.nextCursor,failure:next.failure);revision+=1
            case .directory(let share,let path,let cursor):
                guard serverState.authenticated,shareNames.contains(where:{$0.name==share}) else{throw ARLNASFault.bindingMismatch}
                let epoch=serverState.epoch
                let next=try await owner.previewServerDirectories(share:share,path:path,cursor:cursor);try current()
                guard serverState.epoch==epoch,next.path==path else{throw ARLNASFault.sourceChanged}
                serverDirectory=next;previewShare=share;revision+=1
            case .authorize(let share,let path,let wholeShare):
                guard let saved=serverRecord,serverState.authenticated,serverDirectory?.path==path,
                      previewShare==share,shareNames.contains(where:{$0.name==share}),
                      (!path.isEmpty && !wholeShare) || (path.isEmpty && wholeShare)
                else{throw ARLNASFault.bindingMismatch}
                let config=try NASConnectionConfiguration(sourceRef:saved.endpoint.sourceRef,host:saved.endpoint.host,port:saved.endpoint.port,share:share,root:path,timeoutSeconds:saved.endpoint.timeoutSeconds,generation:(record?.configuration.generation ?? 0)+1)
                await owner.stop();try current()
                let next=Record(configuration:config,identity:saved.identity,credentialFingerprint:saved.endpoint.fingerprint,revision:revision+1,originalAddress:saved.originalAddress)
                try persist(next);record=next;revision=next.revision;state = .init();serverState = .init();serverDirectory=nil;previewShare=nil;shareNames=[]
            case .stop:
                await owner.stop();try current();state = .init();serverState = .init();serverDirectory=nil;previewShare=nil;shareNames=[];revision+=1
            }
            failure=nil;failureDiagnostic=nil
        } catch {
            guard serial==captured,serverIntentID==intent.id else{return}
            await owner.stop()
            guard serial==captured,serverIntentID==intent.id else{return}
            state = .init();serverState = .init();serverDirectory=nil;previewShare=nil;shareNames=[];failure=mapped(error)
        }
    }
    private func configuration() -> ARLNASConfiguration? {
        guard let saved = record?.configuration else { return nil }
        return try? .init(address: record?.originalAddress ?? saved.host, transport: .smb, share: saved.share, root: saved.root,
                          applicationScope: .readOnly, advanced: .init(connectionTimeoutSeconds: saved.timeoutSeconds), port: saved.port)
    }
    private func scope() -> ARLNASReadScope? {
        guard let record, let identity = record.identity,
              let raw = try? record.configuration.scopeJSON(identity: identity),
              let value = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let source = value["source_ref"] as? String, let credential = value["credential_ref"] as? String,
              let generation = value["credential_generation"] as? String,
              let fingerprint = value["config_fingerprint"] as? String,
              let root = value["root_descriptor_digest"] as? String else { return nil }
        return try? .init(sourceRef: .init(source), credentialRef: .init(credential),
                          configFingerprint: .init(fingerprint), rootDescriptorDigest: .init(root),
                          configGeneration: record.configuration.generation, credentialGeneration: .init(generation))
    }
    func cachedSnapshot() -> ARLNASSetupSnapshot {
        guard enabled, pins != nil else { return .unsupported }
        let config = configuration(), saved = credentialMatchesScope()
        let connection: ARLNASFact = failure.map { .failed($0) } ?? state.failure.map { .failed(ARLNASControllerResultProjection.fault($0)) } ?? (state.connected ? .verified : .unknown)
        let ready: ARLNASAdmission = saved ? .allowed : .held(.credentialNotSaved)
        return .init(revision: revision, provider: .available,
            availability: .init(saveConfiguration: .allowed, saveCredential: config == nil ? .held(.configurationNotSaved) : .allowed,
                testConnection: ready, testRead: state.connected ? .allowed : .held(.connectionFailed), reconnect: ready,
                stop: record?.identity == nil ? .held(.configurationNotSaved) : .allowed),
            configuration: config, currentConfigurationGeneration: record?.configuration.generation ?? 0,
            readScope: scope(), observedCallerPins: pins,
            connectionEpoch: state.epoch.flatMap { try? .init($0) }, configurationSaved: config == nil ? .unknown : .verified,
            credentialReferenceSaved: saved ? .verified : .unknown, credentialAvailable: state.connected ? .verified : .unknown,
            connected: connection, readable: state.readable ? .verified : .unknown)
    }
    private func validate(_ request: ARLNASActionRequest) throws {
        guard enabled, pins != nil else { throw ARLNASFault.hostNotConfigured }
        guard serverIntentID==nil, fileOperationID == nil || request.action == .stop else{throw ARLNASFault.operationInProgress}
        guard request.expectedSnapshotRevision == revision,
              request.expectedConfigurationGeneration == (record?.configuration.generation ?? 0) else { throw ARLNASFault.staleGeneration }
        guard request.configuration.applicationScope == .readOnly else { throw ARLNASFault.writeUnsupported }
        if request.action != .saveConfiguration {
            guard request.configuration == configuration(), request.readScope == scope() else { throw ARLNASFault.bindingMismatch }
        }
    }
    private func reply(_ request: ARLNASActionRequest, _ result: ARLNASActionOutcome) -> ARLNASActionReply {
        .init(request: request, outcome: result, snapshot: cachedSnapshot())
    }
    private func mapped(_ error: Error) -> ARLNASFault {
        // Closed operation/status codes only; never descriptions, paths or input.
        if let fault = error as? CredentialStorageFailure {
            failureDiagnostic = "storage." + fault.operation.rawValue + ": " + String(fault.status)
            return .credentialsUnavailable
        }
        failureDiagnostic = (error as? NASRuntimeFailure)?.rawValue
            ?? (error as? CredentialError)?.rawValue
        if let fault = error as? ARLNASFault { return fault }
        if let fault = error as? NASRuntimeFailure { return ARLNASControllerResultProjection.fault(fault.rawValue) }
        if error is CancellationError { return .userCancelled }
        switch error as? CredentialError {
        case .staleReference, .wrongPurpose: return .sourceChanged
        case .identityMismatch, .deploymentNotApproved: return .callerRejected
        case .busy: return .operationInProgress
        case .missing: return .credentialNotSaved
        case .invalidInput: return .credentialInvalid
        default: return .credentialsUnavailable
        }
    }
    func perform(_ request: ARLNASActionRequest, manualIntent: ARLNASManualIntent) async -> ARLNASActionReply {
        guard manualIntent.consume(for: request) else { return reply(request, .held(.manualIntentRequired)) }
        var captured: UUID?
        do {
            try validate(request); try Task.checkCancellation()
            guard request.action != .saveCredential, request.action != .testWrite else { throw ARLNASFault.writeUnsupported }
            serial = UUID(); captured = serial
            if request.action == .stop {
                polling?.cancel(); await owner.stop(); state = .init(); failure = nil; revision += 1
                return reply(request, .applied)
            }
            if request.action == .saveConfiguration {
                polling?.cancel(); await owner.stop()
                guard captured == serial else { throw CancellationError() }
                try Task.checkCancellation()
                let ui = request.configuration
                let config = try NASConnectionConfiguration(sourceRef: record?.configuration.sourceRef ?? UUID().uuidString.lowercased(),
                    host: ui.address, port: ui.port, share: ui.share, root: ui.root,
                    timeoutSeconds: ui.advanced.connectionTimeoutSeconds, generation: (record?.configuration.generation ?? 0) + 1)
                let next = Record(configuration: config, identity: record?.identity,
                    credentialFingerprint: record?.credentialFingerprint, revision: revision + 1, originalAddress: ui.addressInput)
                try persist(next); record = next; revision = next.revision; state = .init(); failure = nil
                return reply(request, .applied)
            }
            guard let record, let identity = record.identity,
                  credentialMatchesScope() else { throw ARLNASFault.credentialNotSaved }
            let next: NASRuntimeState
            if request.action == .testRead {
                _ = try await owner.readDirectory()
                next = await owner.status()
            } else {
                next = try await owner.connect(configuration: record.configuration, identity: identity)
            }
            guard captured == serial else { throw CancellationError() }
            try Task.checkCancellation()
            state = next; serverState = .init();serverDirectory=nil;previewShare=nil;shareNames=[];failure = nil; revision += 1
            startPolling()
            return reply(request, state.connected ? .applied : .failed(.connectionFailed))
        } catch {
            if let captured, captured != serial { return reply(request, .failed(.userCancelled)) }
            let fault = mapped(error); failure = fault
            return reply(request, .failed(fault))
        }
    }
    func save(_ input: ARLNASCredentialInput, request: ARLNASActionRequest,
              manualIntent: ARLNASManualIntent) async -> ARLNASActionReply {
        defer { input.clear() }
        guard manualIntent.consume(for: request) else { return reply(request, .held(.manualIntentRequired)) }
        var username = "", password = ""
        var captured: UUID?
        defer { username.removeAll(); password.removeAll() }
        do {
            try validate(request)
            guard request.action == .saveCredential, var saved = record,
                  input.consume({ username = $0; password = $1 }) else { throw ARLNASFault.credentialInvalid }
            polling?.cancel(); serial = UUID(); captured = serial
            try Task.checkCancellation()
            // Explicit Save may recover a purpose reference after a prior local persistence failure.
            let replacing = try await owner.savedIdentity()
            guard captured == serial else { throw CancellationError() }
            try Task.checkCancellation()
            let identity = try await owner.save(configuration: saved.configuration, username: username, password: password, replacing: replacing)
            guard captured == serial else { throw CancellationError() }
            try Task.checkCancellation()
            saved.identity = identity; saved.credentialFingerprint = saved.configuration.fingerprint; saved.revision = revision + 1
            try persist(saved); record = saved; revision = saved.revision; state = .init(); failure = nil
            return reply(request, .applied)
        } catch {
            if let captured, captured != serial { return reply(request, .failed(.userCancelled)) }
            let fault = mapped(error); failure = fault; return reply(request, .failed(fault))
        }
    }
    func browseDirectories(path: String, cursor: String?) async throws -> NASDirectoryPage {
        guard enabled, state.connected, let epoch = state.epoch else { throw ARLNASFault.connectionFailed }
        polling?.cancel(); serial = UUID(); let captured = serial
        do {
            let page = try await owner.browseDirectories(path: path, cursor: cursor)
            guard serial == captured, state.epoch == epoch else { throw CancellationError() }
            try Task.checkCancellation()
            startPolling()
            return page
        } catch {
            if serial == captured { state = .init(); failure = mapped(error); revision += 1 }
            throw error
        }
    }
    func prepareUploadTest(directory: String) async throws -> NASUploadProposal {
        guard enabled, state.connected else { throw ARLNASFault.connectionFailed }
        return try await owner.prepareUploadTest(directory: directory)
    }
    func uploadTestAfterConfirmation(_ proposal: NASUploadProposal) async throws -> NASUploadResult {
        guard enabled, record?.configuration == proposal.configuration, record?.identity == proposal.identity,
              state.connected else { throw ARLNASFault.bindingMismatch }
        polling?.cancel()
        serial = UUID(); let captured = serial
        let result = try await owner.uploadTestAfterConfirmation(proposal)
        guard captured == serial, !Task.isCancelled else { return .init(status: "uncertain", failure: "cancelled") }
        let current = await owner.status()
        guard captured == serial, !Task.isCancelled else { return .init(status: "uncertain", failure: "cancelled") }
        state = current; revision += 1
        startPolling()
        return result
    }
    func connectSavedReadScope() async throws {
        guard enabled, serverIntentID == nil, fileOperationID == nil else { throw ARLNASFault.operationInProgress }
        guard let record else { throw ARLNASFault.configurationNotSaved }
        guard let identity = record.identity else { throw ARLNASFault.credentialNotSaved }
        guard credentialMatchesScope() else { throw ARLNASFault.bindingMismatch }
        let id = UUID(); fileOperationID = id
        polling?.cancel(); serial = UUID(); let captured = serial
        defer { if fileOperationID == id { fileOperationID = nil } }
        do {
            let current = await owner.status()
            guard serial == captured, fileOperationID == id, self.record?.configuration == record.configuration,
                  self.record?.identity == identity else { throw CancellationError() }
            try Task.checkCancellation()
            let expectedScope = try record.configuration.scopeJSON(identity: identity)
            let sameScope = current.scopeJSON.flatMap { try? JSONSerialization.jsonObject(with: $0) as? NSDictionary }
                == (try JSONSerialization.jsonObject(with: expectedScope) as? NSDictionary)
            let next: NASRuntimeState
            if current.connected && current.readable && sameScope { next = current }
            else { next = try await owner.connect(configuration: record.configuration, identity: identity) }
            guard serial == captured, fileOperationID == id, self.record?.configuration == record.configuration,
                  self.record?.identity == identity else { throw CancellationError() }
            try Task.checkCancellation()
            state = next; failure = nil; revision += 1
            startPolling()
            guard next.connected, next.readable else { throw ARLNASFault.connectionFailed }
        } catch {
            if serial == captured { state = .init(); failure = mapped(error); revision += 1 }
            throw error
        }
    }

    func validateReadContext(sourceRef:String,generation:UInt64,epoch:String) async throws {
        guard enabled,serverIntentID==nil,fileOperationID==nil else {throw ARLNASFault.operationInProgress}
        guard let selected=record,selected.identity != nil,credentialMatchesScope(),
              selected.configuration.sourceRef==sourceRef,selected.configuration.generation==generation else {throw ARLNASFault.sourceChanged}
        let captured=serial,id=UUID();fileOperationID=id
        defer{if fileOperationID==id {fileOperationID=nil}}
        try await owner.validateReadContext(sourceRef:sourceRef,generation:generation,epoch:epoch)
        guard serial==captured,fileOperationID==id,record?.configuration==selected.configuration,
              record?.identity==selected.identity,credentialMatchesScope() else {throw ARLNASFault.sourceChanged}
        try Task.checkCancellation()
    }
    func consumeFileRead(_ request: NASFileRequest) async throws -> Data {
        guard enabled, serverIntentID == nil, fileOperationID == nil else { throw ARLNASFault.operationInProgress }
        guard let record, record.identity != nil, credentialMatchesScope() else { throw ARLNASFault.credentialNotSaved }
        let id = UUID(); fileOperationID = id
        polling?.cancel(); serial = UUID(); let captured = serial
        defer {
            if fileOperationID == id { fileOperationID = nil }
            if serial == captured { startPolling() }
        }
        let value = try await owner.consumeFileRead(request)
        guard serial == captured, fileOperationID == id, self.record?.configuration == record.configuration,
              self.record?.identity == record.identity else { throw CancellationError() }
        try Task.checkCancellation()
        return value
    }

    private func startPolling() {
        polling?.cancel()
        guard state.connected else { return }
        let owner = owner, captured = serial
        polling = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                let current = await owner.status()
                guard let self, self.serial == captured, !Task.isCancelled else { return }
                if self.state != current { self.state = current; self.revision += 1 }
                if !current.connected { return }
            }
        }
    }
}
