import Foundation
import Darwin

/// Local ownership evidence, containing no credential bytes. Pending states deliberately
/// stop after interruption; a service-name match never resolves uncertain ownership.
struct LoginCreationReceipt: Codable, Sendable {
    enum Phase: String, Codable, Sendable { case intent, owned, pendingUpdate, pendingRemoval, removed }
    let schema: Int
    let identity: String
    let purpose: CredentialPurpose
    let loginPath: String
    let nonce: UUID
    var phase: Phase
    var persistentReference: Data?
    var metadata: StoredMetadata
    var pendingMetadata: StoredMetadata? = nil
    let baselineACL: [LoginACLSnapshot]
}
protocol LoginReceiptStore: Sendable {
    func withLock<T>(_ body: () throws -> T) throws -> T
    func load(_ purpose: CredentialPurpose) throws -> LoginCreationReceipt?
    func write(_ receipt: LoginCreationReceipt) throws
}

/// Lazily creates only this identity's receipt directory after the deployment gate.
/// Files are owner-only, bounded, atomic and fsynced; a nonblocking flock excludes another process.
final class FileLoginReceiptStore: LoginReceiptStore, @unchecked Sendable {
    private let directory: URL
    private let lock = NSLock()
    private var activeDirectory: Int32?
    init(directory: URL) { self.directory = directory }
    private func file(_ purpose: CredentialPurpose) -> URL { directory.appendingPathComponent(purpose.rawValue + ".json") }
    private func validate(_ fd: Int32, mode: mode_t, type: mode_t) throws -> stat {
        var metadata = stat()
        guard fstat(fd, &metadata) == 0, metadata.st_uid == getuid(), metadata.st_mode & S_IFMT == type,
              metadata.st_mode & 0o777 == mode, type != S_IFREG || metadata.st_nlink == 1
        else { throw CredentialError.uncertainLocalState }
        return metadata
    }
    func withLock<T>(_ body: () throws -> T) throws -> T {
        try lock.withLock {
            // Traverse with openat/O_NOFOLLOW, preventing a symlink in any path component.
            guard directory.isFileURL, directory.path.hasPrefix("/"), !directory.pathComponents.contains("..") else { throw CredentialError.uncertainLocalState }
            var fd = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard fd >= 0 else { throw CredentialError.storageUnavailable }
            defer { close(fd) }
            for component in directory.pathComponents.dropFirst() {
                let next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                if next >= 0 { close(fd); fd = next; continue }
                guard errno == ENOENT, mkdirat(fd, component, 0o700) == 0 else { throw CredentialError.uncertainLocalState }
                let created = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                guard created >= 0 else { throw CredentialError.uncertainLocalState }
                close(fd); fd = created
            }
            _ = try validate(fd, mode: 0o700, type: S_IFDIR)
            let lockFD = openat(fd, "operation.lock", O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
            guard lockFD >= 0 else { throw CredentialError.storageUnavailable }
            defer { close(lockFD) }
            _ = try validate(lockFD, mode: 0o600, type: S_IFREG)
            guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { throw CredentialError.busy }
            defer { flock(lockFD, LOCK_UN) }
            activeDirectory = fd
            defer { activeDirectory = nil }
            return try body()
        }
    }
    func load(_ purpose: CredentialPurpose) throws -> LoginCreationReceipt? {
        guard let directoryFD = activeDirectory else { throw CredentialError.uncertainLocalState }
        let fd = openat(directoryFD, file(purpose).lastPathComponent, O_RDONLY | O_NOFOLLOW)
        if fd < 0, errno == ENOENT { return nil }
        guard fd >= 0 else { throw CredentialError.uncertainLocalState }
        defer { close(fd) }
        let metadata = try validate(fd, mode: 0o600, type: S_IFREG)
        guard metadata.st_size > 0, metadata.st_size <= 65536 else { throw CredentialError.uncertainLocalState }
        var bytes = [UInt8](repeating: 0, count: Int(metadata.st_size)), offset = 0
        while offset < bytes.count {
            let remaining = bytes.count - offset
            let count = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!.advanced(by: offset), remaining) }
            guard count > 0 else { throw CredentialError.uncertainLocalState }; offset += count
        }
        guard let record = try? JSONDecoder().decode(LoginCreationReceipt.self, from: Data(bytes)) else { throw CredentialError.uncertainLocalState }
        return record
    }
    func write(_ receipt: LoginCreationReceipt) throws {
        let bytes = try JSONEncoder().encode(receipt)
        guard bytes.count <= 65536 else { throw CredentialError.uncertainLocalState }
        guard let directoryFD = activeDirectory else { throw CredentialError.uncertainLocalState }
        let temporary = "receipt-" + UUID().uuidString
        let fd = openat(directoryFD, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw CredentialError.storageUnavailable }
        defer { close(fd); unlinkat(directoryFD, temporary, 0) }
        try bytes.withUnsafeBytes { pointer in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, pointer.baseAddress!.advanced(by: offset), bytes.count - offset)
                guard count > 0 else { throw CredentialError.storageUnavailable }; offset += count
            }
        }
        guard fsync(fd) == 0, renameat(directoryFD, temporary, directoryFD, file(receipt.purpose).lastPathComponent) == 0,
              fsync(directoryFD) == 0 else { throw CredentialError.storageUnavailable }
    }
}
