import Foundation
import Darwin

// The reviewed profile seals the journal inode, including across host restarts.
// This complements the owner's dirfd-based durable claims without editing it.
final class NotesV2JournalGuard {
    private let path: String
    private var fd: Int32
    private let device: UInt64
    private let inode: UInt64
    init(path: String, device: UInt64, inode: UInt64) throws {
        guard path.hasPrefix("/"), device > 0, inode > 0 else { throw NativeFault("unsafe_journal") }
        self.path = path; self.device = device; self.inode = inode
        fd = try Self.openDirectory(path)
        guard fd >= 0 else { throw NativeFault("unsafe_journal") }
        do { try verify() } catch { close(fd); fd = -1; throw error }
    }
    deinit { if fd >= 0 { close(fd) } }
    func permissionLease() throws -> NotesPermissionLease {
        try NativeNotesPermissionLease(directoryFD: fd, directoryCheck: verify)
    }
    private static func openDirectory(_ path: String) throws -> Int32 {
        guard path.hasPrefix("/") else { throw NativeFault("unsafe_journal") }
        var current = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard current >= 0 else { throw NativeFault("unsafe_journal") }
        for part in path.split(separator: "/") {
            guard part != ".", part != ".." else { close(current); throw NativeFault("unsafe_journal") }
            let next = openat(current, String(part), O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            close(current)
            guard next >= 0 else { throw NativeFault("unsafe_journal") }
            current = next
        }
        return current
    }
    func verify() throws {
        let namedFD = try Self.openDirectory(path)
        defer { close(namedFD) }
        var named = stat(), opened = stat()
        guard fstat(namedFD, &named) == 0, fstat(fd, &opened) == 0,
              named.st_mode & S_IFMT == S_IFDIR, opened.st_mode & S_IFMT == S_IFDIR,
              named.st_uid == getuid(), opened.st_uid == getuid(), named.st_mode & 0o077 == 0, opened.st_mode & 0o077 == 0,
              UInt64(UInt32(bitPattern: named.st_dev)) == device, UInt64(named.st_ino) == inode,
              named.st_dev == opened.st_dev, named.st_ino == opened.st_ino else { throw NativeFault("unsafe_journal") }
    }
}
