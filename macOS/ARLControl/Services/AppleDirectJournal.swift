import Foundation
import Darwin

// Separate from legacy grants. Only opaque IDs, approval digests and terminal
// markers persist. An anchor detects a missing/replaced directory after setup.
final class AppleDirectJournal {
    private let home: URL
    private let directory: Int32
    private let lock: Int32
    private let device: dev_t
    private let inode: ino_t
    fileprivate static func openHome(_ home: URL) throws -> Int32 {
        guard home.path.hasPrefix("/"), home.standardizedFileURL.path == home.path else { throw AppleDirectFault("journal_unavailable") }
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw AppleDirectFault("journal_unavailable") }
        do {
            for part in home.path.split(separator: "/") {
                guard part != ".", part != ".." else { throw AppleDirectFault("journal_unavailable") }
                let next = openat(fd, String(part), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw AppleDirectFault("journal_unavailable") }
                close(fd); fd = next
            }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o022 == 0 else { throw AppleDirectFault("journal_unavailable") }
            return fd
        } catch { close(fd); throw error }
    }
    fileprivate static func checkedFile(_ fd: Int32) throws {
        var info = stat()
        guard fd >= 0, fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1, info.st_mode & 0o777 == 0o600 else { throw AppleDirectFault("journal_unsafe") }
    }
    private static func writeDurable(_ fd: Int32, _ text: String) throws {
        let bytes = Data(text.utf8)
        let count = bytes.withUnsafeBytes { write(fd, $0.baseAddress, bytes.count) }
        guard count == bytes.count, fsync(fd) == 0 else { throw AppleDirectFault("journal_uncertain") }
    }
    init(home: URL) throws {
        let parent = try Self.openHome(home); defer { close(parent) }
        let name = "apple-direct-once-v1", anchor = name + ".anchor"
        var childInfo = stat(), anchorInfo = stat()
        let childExists = fstatat(parent, name, &childInfo, AT_SYMLINK_NOFOLLOW) == 0
        let childError = errno
        let anchorExists = fstatat(parent, anchor, &anchorInfo, AT_SYMLINK_NOFOLLOW) == 0
        let anchorError = errno
        guard childExists || childError == ENOENT, anchorExists || anchorError == ENOENT,
              childExists == anchorExists else { throw AppleDirectFault("journal_missing_or_replaced") }
        if !childExists {
            guard mkdirat(parent, name, 0o700) == 0 else { throw AppleDirectFault("journal_unavailable") }
        }
        let child = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard child >= 0 else { throw AppleDirectFault("journal_unavailable") }
        var owned = true
        defer { if owned { close(child) } }
        var info = stat()
        guard fstat(child, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o777 == 0o700 else { throw AppleDirectFault("journal_unsafe") }
        let text = "v1\n\(info.st_dev)\n\(info.st_ino)\n"
        if !anchorExists {
            let marker = openat(parent, anchor, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard marker >= 0 else { throw AppleDirectFault("journal_uncertain") }
            defer { close(marker) }
            try Self.writeDurable(marker, text)
            guard fsync(parent) == 0 else { throw AppleDirectFault("journal_uncertain") }
        } else {
            let marker = openat(parent, anchor, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            defer { if marker >= 0 { close(marker) } }
            try Self.checkedFile(marker)
            var bytes = [UInt8](repeating: 0, count: 128)
            let count = read(marker, &bytes, bytes.count)
            guard count > 0, count < 128, String(bytes: bytes.prefix(count), encoding: .utf8) == text else {
                throw AppleDirectFault("journal_missing_or_replaced")
            }
        }
        let file = openat(child, "lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        do {
            try Self.checkedFile(file)
            guard flock(file, LOCK_EX | LOCK_NB) == 0 else { throw AppleDirectFault("journal_busy") }
        } catch { if file >= 0 { close(file) }; throw error }
        self.home = home; directory = child; lock = file; device = info.st_dev; inode = info.st_ino
        owned = false
    }
    deinit { _ = flock(lock, LOCK_UN); close(lock); close(directory) }
    private func verifyDirectory() throws {
        let parent = try Self.openHome(home); defer { close(parent) }
        var info = stat()
        guard fstatat(parent, "apple-direct-once-v1", &info, AT_SYMLINK_NOFOLLOW) == 0,
              info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(), info.st_mode & 0o777 == 0o700,
              info.st_dev == device, info.st_ino == inode else { throw AppleDirectFault("journal_missing_or_replaced") }
    }
    private func record(_ name: String, _ text: String) throws {
        try verifyDirectory()
        let fd = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw AppleDirectFault(errno == EEXIST ? "operation_consumed" : "journal_unavailable") }
        defer { close(fd) }
        try Self.writeDurable(fd, text)
        guard fsync(directory) == 0 else { throw AppleDirectFault("journal_uncertain") }
        try verifyDirectory()
    }
    private func readRecord(_ name: String) throws -> String {
        let fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw AppleDirectFault("previous_create_unconfirmed") }
        defer { close(fd) }
        try Self.checkedFile(fd)
        var bytes = [UInt8](repeating: 0, count: 256)
        let count = read(fd, &bytes, bytes.count)
        guard count > 0, count < 256, let value = String(bytes: bytes.prefix(count), encoding: .utf8) else {
            throw AppleDirectFault("journal_needs_review")
        }
        return value
    }
    func checkAvailable() throws { try verifyDirectory() }
    // O_EXCL consumes each operation independently. Unknown outcomes never
    // replay and do not require scanning unrelated historical records.
    func claim(id: UUID, digest: String) throws {
        guard digest.count == 64, digest.allSatisfy({ "0123456789abcdef".contains($0) }) else { throw AppleDirectFault("invalid_intent") }
        try verifyDirectory()
        try record("notes_" + id.uuidString.lowercased(), "v1\nconsumed_unknown\n" + digest + "\n")
    }
    func confirmed(id: UUID, digest: String) throws {
        guard digest.count == 64, digest.allSatisfy({ "0123456789abcdef".contains($0) }) else { throw AppleDirectFault("invalid_intent") }
        try verifyDirectory()
        guard try readRecord("notes_" + id.uuidString.lowercased()) == "v1\nconsumed_unknown\n" + digest + "\n" else {
            throw AppleDirectFault("journal_needs_review")
        }
        try record("notes_" + id.uuidString.lowercased() + ".verified", "v1\nverified_local\n" + digest + "\n")
    }
}

// Full local business records. Isolated v2 JSONL segments are retained indefinitely (>=7 days).
// Best-effort audit failure is reported separately from the once-only effect journal.
enum AppleDirectBusinessLog {
    private struct Entry<Request: Encodable, Response: Encodable>: Encodable {
        let time: Date
        let callID: UUID
        let domain: String
        let request: Request
        let response: Response?
        let fault: String?
    }
    static func record<Request: Encodable, Response: Encodable>(home: URL, domain: String, callID: UUID,
        request: Request, response: Response?, fault: String?) -> Bool {
        do {
            guard ["notes", "messages"].contains(domain) else { return false }
            let parent = try AppleDirectJournal.openHome(home); defer { close(parent) }
            let name = "apple-direct-business-v1.noindex"
            if mkdirat(parent, name, 0o700) != 0 && errno != EEXIST { return false }
            let directory = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard directory >= 0 else { return false }; defer { close(directory) }
            var info = stat()
            guard fstat(directory, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o777 == 0o700 else { return false }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            var bytes = try encoder.encode(Entry(time: Date(), callID: callID, domain: domain, request: request, response: response, fault: fault))
            bytes.append(10)
            let day = Int(Date().timeIntervalSince1970 / 86400)
            let stem = "v2-" + domain + "-" + String(day) + "-" + callID.uuidString.lowercased() + "-" + UUID().uuidString.lowercased()
            let partial = stem + ".partial"
            let fd = openat(directory, partial, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { return false }; defer { close(fd) }
            try AppleDirectJournal.checkedFile(fd)
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return false }; defer { _ = flock(fd, LOCK_UN) }
            var published = false, failure = "write-0"
            defer {
                if !published {
                    // Keep every failed prefix and its error diagnosis. Never
                    // append a later request to the same incomplete bytes.
                    _ = fsync(fd)
                    _ = renameatx_np(directory, partial, directory, stem + "." + failure + ".partial", UInt32(RENAME_EXCL))
                    _ = fsync(directory)
                }
            }
            var offset = 0
            while offset < bytes.count {
                let count = bytes.withUnsafeBytes { write(fd, $0.baseAddress!.advanced(by: offset), bytes.count - offset) }
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { failure = "write-" + String(count < 0 ? errno : 0); return false }
                offset += count
            }
            guard fsync(fd) == 0 else { failure = "file-sync-" + String(errno); return false }
            guard renameatx_np(directory, partial, directory, stem + ".jsonl", UInt32(RENAME_EXCL)) == 0 else {
                failure = "commit-" + String(errno); return false
            }
            published = true
            return fsync(directory) == 0

        } catch { return false }
    }
}
