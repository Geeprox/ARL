import Foundation
import Darwin
import Security
import CryptoKit
import CoreFoundation

/// Supplied only by a separately reviewed, newly signed pair of bundles.
/// The two bundles seal the same authority bytes in signed Info.plist. No
/// executable hash is self-referential; the exact shared seal is in the code
/// requirement, so an older bundle with the same ID/certificate is rejected.
struct OwnerReadAuthority: Sendable {
    enum Role: String, Sendable { case owner, mio }
    struct Pin: Sendable {
        let identifier: String
        let certificateSHA1: String
        func requirement(seal: String) -> String {
            "identifier \"\(identifier)\" and certificate leaf = H\"\(certificateSHA1)\" and info[ARLCredentialReadOwnerAuthoritySHA256] = \"\(seal)\""
        }
    }
    let seal: String
    let owner: Pin
    let mio: Pin
    let bundleURL: URL
    let role: Role
    var peer: Pin { role == .owner ? mio : owner }
    var own: Pin { role == .owner ? owner : mio }
    static let capabilities: Set<String> = ["travel_read", "music_read", "music_status", "music_playlist_create", "music_playlist_append", "music_playlist_cover",
        "apple_reminders_task", "apple_product_v1", "nas_saved_scope_read"]
    static let sealKey = "ARLCredentialReadOwnerAuthoritySHA256"
    static var directory: String { NSHomeDirectory() + "/Library/Application Support/ARL/read-owner-r1" }
    static var socketPath: String { directory + "/read.sock" }
    static func load(role: Role, bundle: Bundle = .main) throws -> Self {
        #if ARL_FUTURE_OCT3
        throw OwnerReadFault.held
        #else
        guard let seal = bundle.object(forInfoDictionaryKey: sealKey) as? String,
              matches(seal, "^[a-f0-9]{64}$"), let resources = bundle.resourceURL
        else { throw OwnerReadFault.held }
        let url = resources.appendingPathComponent("CredentialReadOwner/authority.json")
        let raw = try readRegular(url.path, limit: 4096)
        guard SHA256.hash(data: raw).map({ String(format: "%02x", $0) }).joined() == seal else { throw OwnerReadFault.identity }
        let p = try OwnerReadJSON.object(raw, limit: 4096)
        guard Set(p.keys) == ["schema", "executionAllowed", "reviewID", "owner", "mio", "capabilities"],
              let capabilities = p["capabilities"] as? [String], capabilities.count == Self.capabilities.count,
              Set(capabilities) == Self.capabilities,
              OwnerReadWire.integer(p["schema"], 2), OwnerReadWire.trueBoolean(p["executionAllowed"]),
              Self.reviewID(p["reviewID"]) != nil else { throw OwnerReadFault.held }
        func pin(_ name: String, identifier: String) throws -> Pin {
            guard let p = p[name] as? [String: Any], Set(p.keys) == ["identifier", "certificateSHA1"],
                  p["identifier"] as? String == identifier, let cert = p["certificateSHA1"] as? String,
                  matches(cert, "^[A-F0-9]{40}$") else { throw OwnerReadFault.identity }
            return .init(identifier: identifier, certificateSHA1: cert)
        }
        let authority = try Self(seal: seal, owner: pin("owner", identifier: "local.arl.control"),
                                 mio: pin("mio", identifier: "local.arl.mioapplebridge"),
                                 bundleURL: bundle.bundleURL, role: role)
        try authority.verifySelf()
        return authority
        #endif
    }
    /// Review metadata uses UUID value semantics; letter case is not identity.
    static func reviewID(_ value: Any?) -> UUID? {
        guard let text = value as? String else { return nil }
        return UUID(uuidString: text)
    }
    func verifySelf() throws {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { throw OwnerReadFault.identity }
        try verify(code, pin: own)
        guard let bundle = Bundle(url: bundleURL),
              bundle.object(forInfoDictionaryKey: Self.sealKey) as? String == seal,
              let url = bundle.resourceURL?.appendingPathComponent("CredentialReadOwner/authority.json"),
              SHA256.hash(data: try Self.readRegular(url.path, limit: 4096)).map({ String(format: "%02x", $0) }).joined() == seal
        else { throw OwnerReadFault.identity }
    }
    func verify(_ code: SecCode, pin: Pin) throws {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(pin.requirement(seal: seal) as CFString, [], &requirement) == errSecSuccess,
              let requirement,
              SecCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess
        else { throw OwnerReadFault.identity }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecStaticCodeCheckValidity(staticCode,
                SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode), requirement) == errSecSuccess
        else { throw OwnerReadFault.identity }
        var raw: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &raw) == errSecSuccess,
              let info = raw as? [String: Any], info[kSecCodeInfoIdentifier as String] as? String == pin.identifier,
              let flags = info[kSecCodeInfoFlags as String] as? NSNumber,
              flags.uint32Value & SecCodeSignatureFlags.runtime.rawValue != 0,
              let plist = info[kSecCodeInfoPList as String] as? [String: Any],
              plist["CFBundleIdentifier"] as? String == pin.identifier,
              plist[Self.sealKey] as? String == seal,
              let certificates = info[kSecCodeInfoCertificates as String] as? [SecCertificate], let leaf = certificates.first,
              Insecure.SHA1.hash(data: SecCertificateCopyData(leaf) as Data).map({ String(format: "%02X", $0) }).joined() == pin.certificateSHA1
        else { throw OwnerReadFault.identity }
        let entitlements = info[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:]
        for key in ["com.apple.security.get-task-allow", "com.apple.security.cs.disable-library-validation",
                    "com.apple.security.cs.allow-dyld-environment-variables", "com.apple.security.cs.allow-unsigned-executable-memory",
                    "com.apple.security.cs.allow-jit", "com.apple.security.cs.disable-executable-page-protection"] {
            if let value = entitlements[key] {
                guard let boolean = value as? NSNumber, CFGetTypeID(boolean) == CFBooleanGetTypeID(), !boolean.boolValue
                else { throw OwnerReadFault.identity }
            }
        }
    }
    static func matches(_ value: String, _ pattern: String) -> Bool { value.range(of: pattern, options: .regularExpression) != nil }
    static func inspectPath(_ path: String) throws {
        guard path.hasPrefix("/"), !path.utf8.contains(0) else { throw OwnerReadFault.identity }
        var current = ""
        for part in path.split(separator: "/") {
            guard part != ".", part != ".." else { throw OwnerReadFault.identity }; current += "/" + part
            var st = stat()
            guard lstat(current, &st) == 0, st.st_mode & S_IFMT != S_IFLNK,
                  st.st_uid == getuid() || st.st_uid == 0, st.st_mode & 0o022 == 0
            else { throw OwnerReadFault.identity }
        }
    }
    static func readRegular(_ path: String, limit: Int) throws -> Data {
        try inspectPath(path)
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw OwnerReadFault.identity }; defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG,
              st.st_size > 0, st.st_size <= limit else { throw OwnerReadFault.identity }
        let data = try FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw OwnerReadFault.identity }; return data
    }
}

/// An audit token is kernel evidence, never a caller supplied identity. Both
/// roles check uid/PID/birth and exact signature at admission and each request.
struct OwnerReadPeer: Sendable {
    let fd: Int32
    let token: Data
    let pid: pid_t
    let seconds: UInt64
    let micros: UInt64
    let authority: OwnerReadAuthority
    init(fd: Int32, authority: OwnerReadAuthority) throws {
        let token = try Self.audit(fd)
        let words = token.withUnsafeBytes { b in (0..<8).map { b.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self) } }
        guard words[1] == getuid(), words[3] == getuid(), words[5] > 0, words[5] <= UInt32(Int32.max)
        else { throw OwnerReadFault.identity }
        let pid = pid_t(words[5]), info = try Self.process(pid)
        self.fd = fd; self.token = token; self.pid = pid
        seconds = info.pbi_start_tvsec; micros = info.pbi_start_tvusec; self.authority = authority
        try verify()
    }
    static func audit(_ fd: Int32) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 32); var count: socklen_t = 32
        // Darwin SOL_LOCAL / LOCAL_PEERTOKEN. Includes PID version as well as PID.
        guard getsockopt(fd, 0, 6, &bytes, &count) == 0, count == 32 else { throw OwnerReadFault.identity }
        return Data(bytes)
    }
    static func process(_ pid: pid_t) throws -> proc_bsdinfo {
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size,
              info.pbi_uid == getuid(), info.pbi_ruid == getuid(), info.pbi_status != 5
        else { throw OwnerReadFault.identity }; return info
    }
    func checkBirth() throws {
        let info = try Self.process(pid)
        guard try Self.audit(fd) == token, info.pbi_start_tvsec == seconds,
              info.pbi_start_tvusec == micros else { throw OwnerReadFault.identity }
    }
    func verify() throws {
        try checkBirth(); try authority.verifySelf()
        var guest: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit as String: token] as CFDictionary, [], &guest) == errSecSuccess,
              let guest else { throw OwnerReadFault.identity }
        try authority.verify(guest, pin: authority.peer); try checkBirth()
    }
}
