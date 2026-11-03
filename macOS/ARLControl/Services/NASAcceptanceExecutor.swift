import Foundation
import Darwin
import ARLCredentialOnboarding
import ARLCredentialHostCore
import Network

/// Local management seam for the one approved six-file acceptance manifest.
/// No user-selected JSON, filename, bytes, path, host or credential is accepted.
enum NASAcceptanceExecutor {
    private struct Saved: Decodable, Sendable {
        let schema: Int
        let configuration: NASConnectionConfiguration
        let identity: NASCredentialIdentity?
    }
    private final class ResultBox: @unchecked Sendable {
        private let lock=NSLock()
        private var stored: Result<Data,Error>?
        func put(_ value: Result<Data,Error>) { lock.withLock{stored=value} }
        func get() -> Result<Data,Error>? { lock.withLock{stored} }
    }

    private static func savedScope() throws -> Saved {
        let path=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/ARL/nas/settings-v1.json")
        var parent=open("/",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
        guard parent >= 0 else { throw CredentialError.storageUnavailable }
        defer { Darwin.close(parent) }
        for component in path.deletingLastPathComponent().pathComponents.dropFirst() {
            let next=openat(parent,component,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
            guard next >= 0 else { throw CredentialError.storageUnavailable }
            Darwin.close(parent);parent=next
        }
        let fd=openat(parent,path.lastPathComponent,O_RDONLY|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK)
        guard fd >= 0 else { throw CredentialError.storageUnavailable }
        defer { Darwin.close(fd) }
        var info=stat()
        guard fstat(fd,&info)==0,info.st_mode&S_IFMT==S_IFREG,info.st_uid==getuid(),info.st_nlink==1,
              info.st_mode&0o7777==0o600,info.st_size>0,info.st_size<=32768
        else { throw CredentialError.uncertainLocalState }
        var data=Data(count:Int(info.st_size))
        let length=data.withUnsafeMutableBytes { raw -> Int in
            var offset=0
            while offset<raw.count {
                let count=Darwin.read(fd,raw.baseAddress!.advanced(by:offset),raw.count-offset)
                if count < 0 && errno==EINTR { continue }
                guard count>0 else{return -1};offset+=count
            }
            return offset
        }
        var after=stat(),named=stat()
        guard length==info.st_size,fstat(fd,&after)==0,
              fstatat(parent,path.lastPathComponent,&named,AT_SYMLINK_NOFOLLOW)==0,
              info.st_dev==after.st_dev,info.st_ino==after.st_ino,info.st_size==after.st_size,
              after.st_dev==named.st_dev,after.st_ino==named.st_ino,
              info.st_uid==after.st_uid,info.st_mode==after.st_mode,after.st_nlink==1,
              info.st_mtimespec.tv_sec==after.st_mtimespec.tv_sec,info.st_mtimespec.tv_nsec==after.st_mtimespec.tv_nsec,
              info.st_ctimespec.tv_sec==after.st_ctimespec.tv_sec,info.st_ctimespec.tv_nsec==after.st_ctimespec.tv_nsec
        else { throw CredentialError.uncertainLocalState }
        _=try MessagesJSON.decode(data,limit:32768)
        let saved=try JSONDecoder().decode(Saved.self,from:data)
        guard saved.schema==1,saved.identity?.reference.purpose == .nasSMB else { throw CredentialError.invalidInput }
        try NASAcceptanceProtocol.validate(configuration:saved.configuration,approvedManifestSHA256:NASAcceptanceProtocol.manifestSHA256)
        return saved
    }

    static func run(phase: NASAcceptancePhase, approvedManifestSHA256: String) async throws -> Data {
        guard approvedManifestSHA256==NASAcceptanceProtocol.manifestSHA256 else { throw CredentialError.invalidInput }
        let saved=try savedScope()
        let bootstrap=CredentialHostBootstrap.load()
        guard bootstrap.configured,let expected=saved.identity else { throw CredentialError.deploymentNotApproved }
        let owner=bootstrap.service.nas
        do {
            guard try await owner.savedIdentity()==expected else { throw CredentialError.staleReference }
            let state=try await owner.connect(configuration:saved.configuration,identity:expected)
            guard state.connected,state.readable else { throw NASRuntimeFailure(rawValue:state.failure ?? "") ?? .unavailable }
            let result=try await owner.runFixedAcceptance(phase,approvedManifestSHA256:approvedManifestSHA256)
            await owner.stop()
            return result
        } catch {
            await owner.stop()
            throw error
        }
    }

    /// Called before constructing SwiftUI/RuntimeStore. The task performs only
    /// SDK-owned native work; it never needs a main-thread UI or permission prompt.
    static func runBlocking(phase: String, approvedManifestSHA256: String) throws -> [String:Any] {
        guard let phase=NASAcceptancePhase(rawValue:phase),approvedManifestSHA256==NASAcceptanceProtocol.manifestSHA256
        else { throw CredentialError.invalidInput }
        let box=ResultBox(),done=DispatchSemaphore(value:0)
        let task=Task.detached(priority:.userInitiated) {
            do { box.put(.success(try await run(phase:phase,approvedManifestSHA256:approvedManifestSHA256))) }
            catch { box.put(.failure(error)) }
            done.signal()
        }
        guard done.wait(timeout:.now()+210) == .success else { task.cancel();throw NASRuntimeFailure.timeout }
        guard let value=box.get() else { throw NASRuntimeFailure.invalidReply }
        let bytes=try value.get()
        guard let result=try JSONSerialization.jsonObject(with:bytes) as? [String:Any] else { throw NASRuntimeFailure.invalidReply }
        return result
    }
}

/// One payload-free TCP diagnostic in the existing GUI process, after a
/// transport failure. A management CLI has different local-network privileges.
enum NASNetworkDiagnostic {
    static let seconds: Double = 2.8
    enum Outcome: String, Encodable, Sendable { case ready, failed, deadline, cancelled, notAttempted = "not_attempted" }
    enum Reason: String, Encodable, Sendable { case notAvailable = "not_available", cellularDenied = "cellular_denied", wifiDenied = "wifi_denied", localNetworkDenied = "local_network_denied", unknown }
    enum Domain: String, Encodable, Sendable { case posix, dns, tls }
    struct Snapshot: Encodable, Sendable {
        let schema_version = 1
        let operation = "nas_network_diagnostic"
        let context = "gui_after_transport_failure"
        let credentials_read = false
        let smb_payload_sent = false
        let at: Int
        let outcome: Outcome
        let unsatisfied_reason: Reason?
        let error_domain: Domain?
        let error_code: Int32?
        let elapsed_milliseconds: Int
    }
    static func eligible(_ error: Error, configuration: NASConnectionConfiguration) -> Bool {
        (error as? NASRuntimeFailure) == .transportFailed
            && configuration.share == "home" && configuration.root == "ARL-Test"
    }
    /// A late callback/cancellation can never resume a request twice.
    final class Completion: @unchecked Sendable {
        private let lock=NSLock()
        private var result: Snapshot?
        private var continuation: CheckedContinuation<Snapshot,Never>?
        var resolved: Bool { lock.withLock { result != nil } }
        func wait(_ value: CheckedContinuation<Snapshot,Never>) {
            let current=lock.withLock { () -> Snapshot? in
                if let result { return result }
                precondition(continuation == nil);continuation=value;return nil
            }
            if let current { value.resume(returning:current) }
        }
        @discardableResult func resolve(_ value: Snapshot) -> Bool {
            let finished=lock.withLock { () -> (Bool,CheckedContinuation<Snapshot,Never>?) in
                guard result == nil else{return(false,nil)}
                result=value;let pending=continuation;continuation=nil;return(true,pending)
            }
            finished.1?.resume(returning:value);return finished.0
        }
    }
    private final class Probe: @unchecked Sendable {
        let completion=Completion()
        private let connection: NWConnection
        private let queue=DispatchQueue(label:"local.arl.nas-network-diagnostic")
        private let started=ProcessInfo.processInfo.systemUptime
        private var latestReason: Reason?
        private var latestDomain: Domain?
        private var latestCode: Int32?
        init(host: String, port: UInt16) {
            connection=NWConnection(host:.init(host),port:.init(rawValue:port)!,using:.tcp)
        }
        private func sample(_ outcome: Outcome) -> Snapshot {
            .init(at:Int(Date().timeIntervalSince1970),outcome:outcome,unsatisfied_reason:latestReason,
                error_domain:latestDomain,error_code:latestCode,
                elapsed_milliseconds:max(0,Int((ProcessInfo.processInfo.systemUptime-started)*1000)))
        }
        private func finish(_ outcome: Outcome) {
            if completion.resolve(sample(outcome)) { connection.stateUpdateHandler=nil;connection.cancel() }
        }
        private func update(_ error: NWError?) {
            latestReason=nil
            if let path=connection.currentPath,path.status == .unsatisfied {
                switch path.unsatisfiedReason {
                case .notAvailable:latestReason = .notAvailable
                case .cellularDenied:latestReason = .cellularDenied
                case .wifiDenied:latestReason = .wifiDenied
                case .localNetworkDenied:latestReason = .localNetworkDenied
                @unknown default:latestReason = .unknown
                }
            }
            if let error {
                switch error {
                case .posix(let code):latestDomain = .posix;latestCode=code.rawValue
                case .dns(let code):latestDomain = .dns;latestCode=code
                case .tls(let code):latestDomain = .tls;latestCode=code
                @unknown default:break
                }
            } else { latestDomain=nil;latestCode=nil }
        }
        func start(_ continuation: CheckedContinuation<Snapshot,Never>) {
            completion.wait(continuation)
            guard !completion.resolved else{return}
            connection.stateUpdateHandler={ [weak self] state in
                guard let self,!self.completion.resolved else{return}
                switch state {
                case .ready:self.update(nil);self.finish(.ready)
                case .failed(let error):self.update(error);self.finish(.failed)
                case .waiting(let error):
                    self.update(error)
                    if self.latestReason == .localNetworkDenied { self.finish(.failed) }
                case .cancelled:self.finish(.cancelled)
                default:break
                }
            }
            connection.start(queue:queue)
            queue.asyncAfter(deadline:.now()+NASNetworkDiagnostic.seconds){ [weak self] in self?.finish(.deadline) }
        }
        func cancel() { queue.async { [self] in finish(.cancelled) } }
    }
    static func capture(configuration: NASConnectionConfiguration) async -> Snapshot {
        guard !Task.isCancelled,configuration.share == "home",configuration.root == "ARL-Test",
              let port=UInt16(exactly:configuration.port),port>0 else {
            return .init(at:Int(Date().timeIntervalSince1970),outcome:Task.isCancelled ? .cancelled:.notAttempted,
                unsatisfied_reason:nil,error_domain:nil,error_code:nil,elapsed_milliseconds:0)
        }
        let probe=Probe(host:configuration.host,port:port)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { probe.start($0) }
        } onCancel: { probe.cancel() }
    }
}
