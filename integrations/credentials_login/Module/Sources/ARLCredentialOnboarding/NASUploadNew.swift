import Foundation
import Darwin
import CryptoKit

// Compatibility helpers for the existing, byte-identical ConsumptionJournal
// compiled into this SDK. Apple review sources and journal semantics are unchanged.
struct ReviewFault: Error { let code: String; init(_ code: String) { self.code = code } }
func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
func identifier(_ text: String) -> Bool { text.utf8.count <= 64 && text.range(of: #"^[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil }
func uuid(_ text: String) -> Bool { UUID(uuidString: text)?.uuidString.lowercased() == text }

public final class NASUploadProposal: Sendable, Identifiable {
    public let id: UUID
    public let configuration: NASConnectionConfiguration
    public let identity: NASCredentialIdentity
    public let target: String
    public let text: String
    public let bytes: Int
    public let sha256: String
    let staged: Bool
    let expires = ProcessInfo.processInfo.systemUptime + 120
    init(configuration: NASConnectionConfiguration, identity: NASCredentialIdentity, directory: String) throws {
        guard !directory.isEmpty, directory.utf8.count <= 900 else { throw CredentialError.invalidInput }
        let reserved = ["CON","PRN","AUX","NUL"] + (1...9).flatMap { ["COM\($0)","LPT\($0)"] }
        for part in directory.split(separator: "/", omittingEmptySubsequences: false) {
            guard (1...255).contains(part.utf8.count), part != ".", part != "..", !part.hasSuffix("."),
                  part.range(of: #"^[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil,
                  !reserved.contains(part.split(separator: ".").first?.uppercased() ?? "") else { throw CredentialError.invalidInput }
        }
        id = UUID()
        self.configuration = configuration; self.identity = identity
        target = directory + "/arl-test-" + id.uuidString.lowercased() + ".txt"
        text = "ARL NAS connection test\nOperation: " + id.uuidString.lowercased() + "\n"
        bytes = text.utf8.count; sha256 = digest(Data(text.utf8)); staged = false
    }
    static func validateTarget(_ target: String) throws {
        let reserved = ["CON","PRN","AUX","NUL"] + (1...9).flatMap { ["COM\($0)","LPT\($0)"] }
        guard (1...1024).contains(target.utf8.count),
              target.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ part in
                  (1...255).contains(part.utf8.count) && part != "." && part != ".."
                      && !part.hasSuffix(".") && !part.hasSuffix(" ")
                      && !part.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 })
                      && !part.contains(where: { "\\:*?\"<>|".contains($0) })
                      && !reserved.contains(String(part.prefix(while: { $0 != "." })).uppercased())
              }) else { throw CredentialError.invalidInput }
    }
    init(id: UUID, configuration: NASConnectionConfiguration, identity: NASCredentialIdentity,
         target: String, bytes: Int, sha256: String) throws {
        try Self.validateTarget(target)
        guard (0...9_007_199_254_740_991).contains(bytes),
              sha256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil
        else { throw CredentialError.invalidInput }
        self.id = id; self.configuration = configuration; self.identity = identity
        self.target = target; self.bytes = bytes; self.sha256 = sha256
        text = ""; staged = true
    }
}

public struct NASUploadResult: Sendable {
    public let status: String
    public let failure: String?
    public var committed: Bool { status == "committed" && failure == nil }
    public init(status: String, failure: String?) { self.status = status; self.failure = failure }
}

struct NASAttachmentStage: Sendable {
    let size: Int
    let sha256: String
}

public struct NASAttachmentFailure: Error, Sendable { public let code: String }

public struct NASAttachmentSaveResult: Sendable {
    public let result: NASUploadResult
    public let size: Int
    public let sha256: String
}

final class NASUploadAuthorization: @unchecked Sendable {
    let proposal: NASUploadProposal
    let plan: [String: Any]
    let planDigest: String
    let journalDescriptor: [String: Any]
    private let journal: ConsumptionJournal
    private let directory: URL
    private let fd: Int32
    private let device: dev_t, inode: ino_t
    private let verifyOwner: @Sendable () throws -> Void
    private let deadline = ProcessInfo.processInfo.systemUptime + 30
    private var consumed = false
    init(proposal: NASUploadProposal, scope: [String: Any], epoch: UInt64, directory: URL,
         verify: @escaping @Sendable () throws -> Void) throws {
        self.proposal = proposal; self.directory = directory; verifyOwner = verify
        try verify()
        guard ProcessInfo.processInfo.systemUptime < proposal.expires, epoch > 0, epoch <= UInt64(Int64.max),
              let namespace = scope["root_descriptor_digest"] as? String,
              let generation = scope["credential_generation"] as? String else { throw CredentialError.staleReference }
        let bytes = try JSONSerialization.data(withJSONObject: scope, options: [.sortedKeys, .withoutEscapingSlashes])
        plan = ["operation_id": proposal.id.uuidString.lowercased(), "permit_id": UUID().uuidString.lowercased(),
            "scope_hash": digest(bytes), "namespace_hash": namespace, "credential_generation": generation,
            "registration_epoch": epoch, "target": proposal.target, "size": proposal.bytes, "sha256": proposal.sha256]
        let planJSON = try JSONSerialization.data(withJSONObject: plan, options: [.sortedKeys, .withoutEscapingSlashes])
        let canonical = String(decoding: planJSON, as: UTF8.self).utf16.map {
            $0 > 127 ? String(format: "\\u%04x", $0) : String(UnicodeScalar($0)!)
        }.joined()
        planDigest = digest(Data(canonical.utf8))
        // Created only after exact native user confirmation; never at construction/status.
        let parent = try MusicRuntimeResources.directory(directory.deletingLastPathComponent().path)
        defer { Darwin.close(parent) }
        if mkdirat(parent, directory.lastPathComponent, 0o700) != 0 && errno != EEXIST { throw CredentialError.storageUnavailable }
        fd = openat(parent, directory.lastPathComponent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw CredentialError.storageUnavailable }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o7777 == 0o700 else {
            Darwin.close(fd); throw CredentialError.storageUnavailable
        }
        device = info.st_dev; inode = info.st_ino
        journalDescriptor = ["path": directory.path, "dev": Int64(info.st_dev), "ino": UInt64(info.st_ino)]
        do { journal = try ConsumptionJournal(home: directory.path) }
        catch { Darwin.close(fd); throw error }
        try check()
    }
    func check() throws {
        try verifyOwner()
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw NASRuntimeFailure.expired }
        var opened = stat(), named = stat()
        guard fstat(fd,&opened) == 0, lstat(directory.path,&named) == 0,
              opened.st_dev == device, opened.st_ino == inode, named.st_dev == device, named.st_ino == inode,
              named.st_mode & S_IFMT == S_IFDIR, opened.st_uid == getuid(), opened.st_mode & 0o7777 == 0o700
        else { throw CredentialError.uncertainLocalState }
    }
    func authorize(consume: Bool) throws {
        try check()
        if consume {
            guard !consumed else { throw CredentialError.staleReference }
            consumed = true // Never reset even if durable claim fails.
            try journal.consume(operationID: proposal.id.uuidString.lowercased(),
                permitID: plan["permit_id"] as! String, subject: "arl.nas.upload-new.v1",
                epoch: Int64(plan["registration_epoch"] as! UInt64), budget: 1)
        }
        try check()
    }
    var remaining: Double { max(0, deadline - ProcessInfo.processInfo.systemUptime) }
    deinit { Darwin.close(fd) }
}
