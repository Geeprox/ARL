import Foundation
import Darwin

protocol NotesPermissionLease: AnyObject { func verify() throws }

// Fixed private state file, process-wide exclusivity until the blocking API
// returns. The descriptor is retained by the request, not an RPC timeout timer.
final class NativeNotesPermissionLease: NotesPermissionLease {
    private var fd: Int32 = -1
    private let directoryFD: Int32
    private let directoryCheck: () throws -> Void
    private let name = "manual_permission.lock"
    init(directoryFD: Int32, directoryCheck: @escaping () throws -> Void) throws {
        self.directoryFD = directoryFD; self.directoryCheck = directoryCheck
        try directoryCheck()
        fd = openat(directoryFD, name, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw NativeFault("unsafe_permission_lease") }
        do {
            try verify()
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw NativeFault(errno == EWOULDBLOCK ? "busy" : "unsafe_permission_lease") }
            try verify()
        } catch { close(fd); fd = -1; throw error }
    }
    deinit { if fd >= 0 { _ = flock(fd, LOCK_UN); close(fd) } }
    func verify() throws {
        try directoryCheck()
        var named = stat(), opened = stat()
        guard fd >= 0, fstat(fd, &opened) == 0, fstatat(directoryFD, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              named.st_dev == opened.st_dev, named.st_ino == opened.st_ino,
              named.st_mode & S_IFMT == S_IFREG, opened.st_mode & S_IFMT == S_IFREG,
              opened.st_uid == getuid(), opened.st_mode & 0o077 == 0, opened.st_nlink == 1 else { throw NativeFault("unsafe_permission_lease") }
        try directoryCheck()
    }
}
