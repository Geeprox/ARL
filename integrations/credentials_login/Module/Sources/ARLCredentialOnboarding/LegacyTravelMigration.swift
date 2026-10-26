import Foundation
import Darwin
import OSLog

public enum LegacyTravelStatus: String, Sendable { case available, absent, unavailable }
enum TravelCredentialPhase: String { case source, validation, commit, recovery }
enum TravelCredentialDiagnosticState: String { case succeeded, tested, unconfirmed }
enum TravelCredentialDiagnostics {
    private static let logger = Logger(subsystem: "local.arl.control", category: "travel-credential-migration")
    static func record(_ purpose: CredentialPurpose, phase: TravelCredentialPhase, state: TravelCredentialDiagnosticState, result: ConnectionTestResult? = nil) {
        // Finite metadata only: no source bytes, path, URL, header, body, key
        // fragment, persistent reference or vendor message enters the log.
        logger.notice("purpose=\(purpose.rawValue, privacy: .public) phase=\(phase.rawValue, privacy: .public) state=\(state.rawValue, privacy: .public) result=\(result?.state.rawValue ?? "none", privacy: .public) evidence=\(result?.evidence.rawValue ?? "none", privacy: .public)")
    }
}
enum TravelCredentialEvidence {
    static func accepts(_ result: ConnectionTestResult, purpose: CredentialPurpose) -> Bool {
        let age = Date().timeIntervalSince(result.checkedAt)
        guard result.state == .verified, result.expiryKnowledge == .unknown, age >= 0, age <= 30 else { return false }
        switch purpose {
        case .amapMapsWeather: return result.evidence == .amapWeatherResponse
        case .fliggyTravelReadOnly: return result.evidence == .flyaiDifferentialReadOnlyResponse
        case .neteaseMusic, .nasSMB: return false
        }
    }
}
protocol LegacyTravelSource: Sendable {
    /// Presence/permissions only. It must never read credential contents.
    func inspect(_ purpose: CredentialPurpose) throws -> LegacyTravelStatus
    func read(_ purpose: CredentialPurpose) throws -> LegacyTravelLease
}
final class LegacyTravelLease: @unchecked Sendable, CustomStringConvertible, CustomReflectable {
    let secret: CredentialInput
    private let check: @Sendable () throws -> Void
    private let release: @Sendable () -> Void
    init(secret: CredentialInput, check: @escaping @Sendable () throws -> Void, release: @escaping @Sendable () -> Void = {}) {
        self.secret = secret; self.check = check; self.release = release
    }
    func verifyUnchanged() throws { try check() }
    deinit { secret.clear(); release() }
    var description: String { "LegacyTravelLease(<redacted>)" }
    var customMirror: Mirror { Mirror(self, children: [:]) }
}
/// Fixed user-owned MioReadOnly sources, for the same map/weather and travel
/// destinations. There is no generic path, environment, CLI, Keychain export,
/// config writer, source deletion, device-id import or automatic invocation.
struct NativeLegacyTravelSource: LegacyTravelSource {
    let gate: any DeploymentGate
    private let home: URL
    init(gate: any DeploymentGate, home: URL = FileManager.default.homeDirectoryForCurrentUser) { self.gate = gate; self.home = home }
    private func relative(_ purpose: CredentialPurpose) throws -> String {
        switch purpose {
        case .amapMapsWeather: return "Library/Application Support/MioReadOnly/amap.json"
        case .fliggyTravelReadOnly: return "Library/Application Support/MioReadOnly/flyai-home/.flyai/config.json"
        case .neteaseMusic, .nasSMB: throw CredentialError.wrongPurpose
        }
    }
    private func file(_ purpose: CredentialPurpose) throws -> String { home.appendingPathComponent(try relative(purpose)).path }
    /// Descriptor-relative traversal rejects symbolic links in every component.
    /// The final file must be private, bounded and owned by the current user.
    private func openSource(_ purpose: CredentialPurpose) throws -> Int32? {
        try gate.verify()
        let path = try file(purpose)
        guard path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { throw CredentialError.uncertainLocalState }
        let parts = path.split(separator: "/").map(String.init)
        guard let name = parts.last else { throw CredentialError.uncertainLocalState }
        var directory = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw CredentialError.storageUnavailable }
        defer { close(directory) }
        for part in parts.dropLast() {
            let next = openat(directory, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0, errno == ENOENT { return nil }
            guard next >= 0 else { throw CredentialError.uncertainLocalState }
            close(directory); directory = next
            var st = stat()
            guard fstat(directory, &st) == 0, st.st_mode & S_IFMT == S_IFDIR,
                  st.st_uid == 0 || st.st_uid == getuid(), st.st_mode & 0o022 == 0
            else { throw CredentialError.uncertainLocalState }
        }
        let fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0, errno == ENOENT { return nil }
        guard fd >= 0 else { throw CredentialError.uncertainLocalState }
        do { _ = try metadata(fd); return fd } catch { close(fd); throw error }
    }
    private func metadata(_ fd: Int32) throws -> stat {
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_uid == getuid(), st.st_mode & S_IFMT == S_IFREG,
              st.st_mode & 0o777 == 0o600, st.st_nlink == 1, st.st_size > 0, st.st_size <= 16384
        else { throw CredentialError.uncertainLocalState }
        return st
    }
    private func stamp(_ st: stat) -> [Int64] {
        [Int64(st.st_dev), Int64(st.st_ino), Int64(st.st_size), Int64(st.st_mtimespec.tv_sec),
         Int64(st.st_mtimespec.tv_nsec), Int64(st.st_ctimespec.tv_sec), Int64(st.st_ctimespec.tv_nsec)]
    }
    func inspect(_ purpose: CredentialPurpose) throws -> LegacyTravelStatus {
        guard let fd = try openSource(purpose) else { return .absent }
        close(fd); return .available // No read() or Data(contentsOf:) here.
    }
    func read(_ purpose: CredentialPurpose) throws -> LegacyTravelLease {
        guard let fd = try openSource(purpose) else { throw CredentialError.missing }
        var retained = false
        defer { if !retained { close(fd) } }
        let before = try stamp(metadata(fd))
        var bytes = try FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(upToCount: 16385) ?? Data()
        defer { bytes.resetBytes(in: 0..<bytes.count) }
        guard try stamp(metadata(fd)) == before else { throw CredentialError.uncertainLocalState }
        let object = try MusicStrictJSON.object(bytes, limit: 16384)
        let field = purpose == .amapMapsWeather ? "AMAP_MAPS_API_KEY" : "FLYAI_API_KEY"
        guard let value = object[field] as? String else { throw CredentialError.invalidInput }
        let secret = try CredentialInput(purpose: purpose, value: value)
        let lease = LegacyTravelLease(secret: secret, check: {
            try gate.verify()
            guard try stamp(metadata(fd)) == before, let current = try openSource(purpose) else { throw CredentialError.uncertainLocalState }
            defer { close(current) }
            guard try stamp(metadata(current)) == before else { throw CredentialError.uncertainLocalState }
        }, release: { close(fd) })
        retained = true
        return lease
    }
}
