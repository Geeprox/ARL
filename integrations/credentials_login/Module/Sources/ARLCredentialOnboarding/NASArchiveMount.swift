import Foundation
import NetFS
import Darwin

/// A separate, user-selected archive destination. This never alters a Mio read grant.
public struct NASArchiveDestination: Codable, Equatable, Sendable {
    public let id: UUID
    public let endpoint: NASServerEndpoint
    public let identity: NASCredentialIdentity
    public let share: String
    public let directory: String
    public init(endpoint: NASServerEndpoint, identity: NASCredentialIdentity, share: String, directory: String) throws {
        _ = try endpoint.validated(); _ = try NASShareRecord(name: share)
        try NASDirectoryPage.validatePath(directory)
        guard identity.reference.purpose == .nasSMB else { throw CredentialError.wrongPurpose }
        self.id = UUID(); self.endpoint = endpoint; self.identity = identity
        self.share = share; self.directory = directory
    }
    public var displayPath: String { endpoint.host + "/" + share + (directory.isEmpty ? "" : "/" + directory) + "/Friday" }
    func validated() throws {
        _ = try Self(endpoint: endpoint, identity: identity, share: share, directory: directory)
    }
}

/// Opaque, in-process connection. Credentials never leave the SDK owner.
public final class NASArchiveMount: @unchecked Sendable {
    public let destination: NASArchiveDestination
    public let root: URL
    private let checkCredential: @Sendable () throws -> Void
    init(destination: NASArchiveDestination, root: URL, checkCredential: @escaping @Sendable () throws -> Void) {
        self.destination = destination; self.root = root; self.checkCredential = checkCredential
    }
    public func validate() throws {
        try checkCredential()
        var value = statfs()
        guard statfs(root.path, &value) == 0 else { throw NASRuntimeFailure.unavailable }
        let type = withUnsafeBytes(of: value.f_fstypename) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let point = withUnsafeBytes(of: value.f_mntonname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let source = withUnsafeBytes(of: value.f_mntfromname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let address = URLComponents(string: "smb:" + source)
        let expectedPath = "/" + destination.share + (destination.directory.isEmpty ? "" : "/" + destination.directory)
        guard type == "smbfs", point == root.path,
              address?.host?.lowercased() == destination.endpoint.host.lowercased(),
              (address?.port ?? 445) == destination.endpoint.port,
              address?.path == expectedPath else { throw NASRuntimeFailure.sourceChanged }
    }
    /// Verify actual negotiated encryption, rather than assuming NetFS forwards
    /// the private SMB encryption options. Supported algorithms are not proof.
    func verifyEncryption() throws {
        try validate()
        let task = Process(), pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/smbutil")
        task.arguments = ["statshares", "-m", root.path, "-f", "JSON"]
        task.standardOutput = pipe; task.standardError = FileHandle.nullDevice
        try task.run()
        let timeout = DispatchWorkItem { if task.isRunning { task.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 10, execute: timeout)
        defer { timeout.cancel() }
        let result = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0, result.count < 262144,
              let object = try? JSONSerialization.jsonObject(with: result) else { throw NASRuntimeFailure.invalidReply }
        guard Self.encryptedSMB3(object) else { throw NASRuntimeFailure.accessDenied }
    }
    static func encryptedSMB3(_ object: Any) -> Bool {
        // smbutil emits a share dictionary inside an array on current macOS.
        // Require version and current algorithm on the same share record.
        if let record = object as? [String: Any] {
            if let version = record["SMB_VERSION"] as? String,
               let algorithm = record["SMB_CURR_ENCRYPT_ALGORITHM"] as? String {
                let versions: Set<String> = ["SMB_3.0", "SMB_3.0.2", "SMB_3.1.1"]
                let algorithms: Set<String> = ["AES_128_CCM", "AES_128_GCM", "AES_256_CCM", "AES_256_GCM", "AES-128-CCM", "AES-128-GCM", "AES-256-CCM", "AES-256-GCM"]
                return versions.contains(version) && algorithms.contains(algorithm)
            }
            return record.values.contains { encryptedSMB3($0) }
        }
        return (object as? [Any])?.contains { encryptedSMB3($0) } ?? false
    }
    static func connect(destination: NASArchiveDestination, root: URL, username: String, password: String,
                        checkCredential: @escaping @Sendable () throws -> Void) throws -> NASArchiveMount {
        try destination.validated(); try checkCredential()
        let fm = FileManager.default
        // A fixed per-grant private mountpoint, never a caller-provided shell path.
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard root.resolvingSymlinksInPath().path == root.path else { throw NASRuntimeFailure.invalidRequest }
        // A normal ARL restart can reuse only this exact server/share/subfolder
        // mount, after credential-generation and current encryption checks.
        let existing = NASArchiveMount(destination: destination, root: root, checkCredential: checkCredential)
        if (try? existing.validate()) != nil { try existing.verifyEncryption(); return existing }
        guard try fm.contentsOfDirectory(atPath: root.path).isEmpty else { throw NASRuntimeFailure.sourceChanged }
        var parts = URLComponents(); parts.scheme = "smb"; parts.host = destination.endpoint.host; parts.port = destination.endpoint.port
        parts.path = "/" + destination.share + (destination.directory.isEmpty ? "" : "/" + destination.directory)
        guard let address = parts.url else { throw NASRuntimeFailure.invalidRequest }
        let open = NSMutableDictionary(dictionary: ["UIOption": "NoUI", "NoUserPreferences": true, "ForceNewSession": true])
        let options = NSMutableDictionary(dictionary: ["MountAtMountDir": true, "AllowSubMounts": true, "SoftMount": true,
            "MountFlags": Int(MNT_DONTBROWSE | MNT_NOSUID | MNT_NODEV), "SMBSessionEncryption": true, "SMBShareEncryption": true])
        var points: Unmanaged<CFArray>?
        let code = NetFSMountURLSync(address as CFURL, root as CFURL, username as CFString, password as CFString,
                                    unsafeBitCast(open, to: CFMutableDictionary.self), unsafeBitCast(options, to: CFMutableDictionary.self), &points)
        _ = points?.takeRetainedValue()
        guard code == 0 else { throw NASRuntimeFailure.transportFailed }
        let mount = NASArchiveMount(destination: destination, root: root, checkCredential: checkCredential)
        do { try mount.verifyEncryption(); try checkCredential(); return mount }
        catch { _ = unmount(root.path, 0); throw error }
    }
}
