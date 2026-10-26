import Foundation
import Darwin

final class OwnerReadStop: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    func cancel() { lock.withLock { stopped = true } }
    var cancelled: Bool { lock.withLock { stopped } }
}

enum OwnerReadSocket {
    static var now: Double { ProcessInfo.processInfo.systemUptime }
    static func address(_ socketPath: String = OwnerReadAuthority.socketPath) throws -> sockaddr_un {
        var address = sockaddr_un()
        let path = Array(socketPath.utf8) + [0]
        guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw OwnerReadFault.unavailable }
        address.sun_family = sa_family_t(AF_UNIX); address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path) }
        return address
    }
    static func configure(_ fd: Int32) throws {
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0,
              fcntl(fd, F_SETFD, FD_CLOEXEC) == 0, fcntl(fd, F_SETNOSIGPIPE, 1) == 0
        else { throw OwnerReadFault.unavailable }
    }
    static func wait(_ fd: Int32, event: Int16, deadline: Double, cancelled: () -> Bool) throws {
        while true {
            guard !cancelled() else { throw OwnerReadFault.cancelled }
            let remaining = deadline - now
            guard remaining > 0 else { throw OwnerReadFault.deadline }
            var descriptor = pollfd(fd: fd, events: event, revents: 0)
            let count = poll(&descriptor, 1, Int32(max(1, min(remaining * 1000, 50))))
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw OwnerReadFault.unavailable }
            if count == 0 { continue }
            if descriptor.revents & event != 0 { return }
            throw OwnerReadFault.unavailable
        }
    }
    static func writeFrame(_ bytes: Data, fd: Int32, limit: Int, deadline: Double, cancelled: () -> Bool) throws {
        guard !bytes.isEmpty, bytes.count <= limit, let length = UInt32(exactly: bytes.count) else { throw OwnerReadFault.limit }
        func writeAll(_ buffer: UnsafeRawBufferPointer) throws {
            var offset = 0
            while offset < buffer.count {
                try wait(fd, event: Int16(POLLOUT), deadline: deadline, cancelled: cancelled)
                let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), min(buffer.count - offset, 64 * 1024))
                if count < 0 && (errno == EAGAIN || errno == EINTR) { continue }
                guard count > 0 else { throw OwnerReadFault.unavailable }; offset += count
            }
        }
        // Send the header and existing payload without an extra full-frame copy.
        var size = length.bigEndian
        try withUnsafeBytes(of: &size) { try writeAll($0) }
        try bytes.withUnsafeBytes { try writeAll($0) }
    }
    static func readFrame(_ fd: Int32, limit: Int, deadline: Double, cancelled: () -> Bool) throws -> Data {
        func take(_ count: Int) throws -> Data {
            var result = Data()
            // An advertised length must never allocate its entire body up front.
            // This is an IO chunk size, not a result-size restriction.
            var chunk = [UInt8](repeating: 0, count: min(count, 64 * 1024))
            while result.count < count {
                try wait(fd, event: Int16(POLLIN), deadline: deadline, cancelled: cancelled)
                let wanted = min(chunk.count, count - result.count)
                let received = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!, wanted) }
                if received < 0 && (errno == EAGAIN || errno == EINTR) { continue }
                guard received > 0 else { throw OwnerReadFault.unavailable }
                result.append(contentsOf: chunk.prefix(received))
            }
            return result
        }
        let header = try take(MemoryLayout<UInt32>.size)
        let count = header.withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self)) }
        guard count > 0, Int(count) <= limit else { throw OwnerReadFault.limit }
        return try take(Int(count))
    }
    /// Called after the one request. Disconnect OR unsolicited additional data
    /// cancels the operation; pipelining and same-connection replay are denied.
    static func interrupted(_ fd: Int32) -> Bool {
        var byte: UInt8 = 0
        let count = recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
        return count >= 0 || (errno != EAGAIN && errno != EINTR)
    }
    static func connect(deadline: Double, cancelled: () -> Bool) throws -> Int32 {
        try OwnerReadAuthority.inspectPath(OwnerReadAuthority.socketPath)
        var before = stat()
        guard lstat(OwnerReadAuthority.socketPath, &before) == 0,
              before.st_mode & S_IFMT == S_IFSOCK, before.st_uid == getuid(), before.st_mode & 0o777 == 0o600
        else { throw OwnerReadFault.unavailable }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw OwnerReadFault.unavailable }
        do {
            try configure(fd); var a = try address()
            let code = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
            if code != 0 {
                guard errno == EINPROGRESS else { throw OwnerReadFault.unavailable }
                try wait(fd, event: Int16(POLLOUT), deadline: deadline, cancelled: cancelled)
                var error: Int32 = 0; var count = socklen_t(MemoryLayout<Int32>.size)
                guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &count) == 0, error == 0 else { throw OwnerReadFault.unavailable }
            }
            var after = stat()
            guard lstat(OwnerReadAuthority.socketPath, &after) == 0,
                  before.st_dev == after.st_dev, before.st_ino == after.st_ino,
                  after.st_mode & S_IFMT == S_IFSOCK else { throw OwnerReadFault.identity }
            return fd
        } catch { close(fd); throw error }
    }
    static func listener() throws -> (fd: Int32, device: dev_t, inode: ino_t) {
        // Create only these two fixed directories, checking each existing parent.
        let arl = NSHomeDirectory() + "/Library/Application Support/ARL"
        for directory in [arl, OwnerReadAuthority.directory] {
            try OwnerReadAuthority.inspectPath(URL(fileURLWithPath: directory).deletingLastPathComponent().path)
            if mkdir(directory, 0o700) != 0 && errno != EEXIST { throw OwnerReadFault.unavailable }
            try OwnerReadAuthority.inspectPath(directory)
            var st = stat()
            guard lstat(directory, &st) == 0, st.st_mode & S_IFMT == S_IFDIR,
                  st.st_uid == getuid(), st.st_mode & 0o077 == 0 else { throw OwnerReadFault.identity }
        }
        // Never unlink an unknown or stale endpoint. Removal requires review.
        var existing = stat()
        guard lstat(OwnerReadAuthority.socketPath, &existing) != 0, errno == ENOENT else { throw OwnerReadFault.unavailable }
        return try bindListener(path: OwnerReadAuthority.socketPath, failAfterBind: false)
    }
    private static func bindListener(path: String, failAfterBind: Bool) throws -> (fd: Int32, device: dev_t, inode: ino_t) {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw OwnerReadFault.unavailable }
        var owned: (device: dev_t, inode: ino_t)?
        do {
            try configure(fd); var a = try address(path)
            let status = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
            guard status == 0 else { throw OwnerReadFault.unavailable }
            var bound = stat()
            guard lstat(path, &bound) == 0, bound.st_mode & S_IFMT == S_IFSOCK, bound.st_uid == getuid()
            else { throw OwnerReadFault.cleanupUnproven }
            owned = (bound.st_dev, bound.st_ino)
            guard !failAfterBind, chmod(path, 0o600) == 0, Darwin.listen(fd, 1) == 0
            else { throw OwnerReadFault.unavailable }
            return (fd, bound.st_dev, bound.st_ino)
        } catch {
            let closed = close(fd) == 0
            let removed = owned.map { removeOwnSocket(path: path, device: $0.device, inode: $0.inode) } ?? true
            guard closed && removed else { throw OwnerReadFault.cleanupUnproven }
            throw error
        }
    }
    @discardableResult static func removeOwnSocket(device: dev_t, inode: ino_t) -> Bool {
        removeOwnSocket(path: OwnerReadAuthority.socketPath, device: device, inode: inode)
    }
    private static func removeOwnSocket(path: String, device: dev_t, inode: ino_t) -> Bool {
        var value = stat()
        if lstat(path, &value) != 0 { return errno == ENOENT }
        guard value.st_dev == device, value.st_ino == inode, value.st_uid == getuid(),
              value.st_mode & S_IFMT == S_IFSOCK else { return false }
        return unlink(path) == 0
    }
    #if ARL_OWNER_FIXTURE
    static func fixtureListener(path: String, failAfterBind: Bool = false) throws -> (fd: Int32, device: dev_t, inode: ino_t) {
        // The fixture supplies an owned short temporary path, never the live endpoint.
        guard path != OwnerReadAuthority.socketPath, path.hasPrefix("/private/tmp/arl-r5-") else { throw OwnerReadFault.identity }
        return try bindListener(path: path, failAfterBind: failAfterBind)
    }
    static func fixtureRemove(path: String, device: dev_t, inode: ino_t) -> Bool {
        guard path != OwnerReadAuthority.socketPath, path.hasPrefix("/private/tmp/arl-r5-") else { return false }
        return removeOwnSocket(path: path, device: device, inode: inode)
    }
    #endif
}

struct OwnerReadClient {
    /// Each call opens a new authenticated generation. There is no automatic
    /// reconnect/replay, and cancellation closes the fd to cancel the owner task.
    func call(tool: String, argumentsJSON: Data, logCorrelation: String? = nil, cancelled: () -> Bool) throws -> Data {
        guard OwnerReadWire.isTool(tool) else { throw OwnerReadFault.unsupported }
        guard !cancelled() else { throw OwnerReadFault.cancelled }
        let logStarted = ProcessInfo.processInfo.systemUptime
        let authority = try OwnerReadAuthority.load(role: .mio)
        let deadline = OwnerReadSocket.now + OwnerReadWire.seconds(for: tool)
        let fd = try OwnerReadSocket.connect(deadline: min(deadline, OwnerReadSocket.now + 2), cancelled: cancelled)
        defer { _ = shutdown(fd, SHUT_RDWR); close(fd) }
        let peer = try OwnerReadPeer(fd: fd, authority: authority)
        let hello = try OwnerReadJSON.object(OwnerReadSocket.readFrame(fd, limit: 1024,
            deadline: min(deadline, OwnerReadSocket.now + 2), cancelled: cancelled), limit: 1024)
        guard Set(hello.keys) == ["schema", "generation", "event"], OwnerReadWire.integer(hello["schema"], OwnerReadWire.schema),
              hello["event"] as? String == "ready", let generation = OwnerReadWire.uuid(hello["generation"])
        else { throw OwnerReadFault.identity }
        let request = OwnerReadRequest(generation: generation, callID: UUID().uuidString,
                                       tool: tool, argumentsJSON: argumentsJSON)
        var logFields: [String:Any] = ["owner_call_id":request.callID,"tool_sha256":ARLConnectionLog.fingerprint(tool) ?? ""]
        if let logCorrelation { logFields["rpc_id_sha256"] = logCorrelation }
        var logFailed = true
        ARLConnectionLog.production.record("gateway","owner_request",logFields)
        defer { logFields["elapsed_ms"]=max(0,Int((ProcessInfo.processInfo.systemUptime-logStarted)*1000));logFields["failed"]=logFailed;ARLConnectionLog.production.record("gateway","owner_finished",logFields) }
        try peer.verify()
        let encoded = try request.encoded()
        let result = try Self.receiveAfterPossibleSend(tool: tool) {
            try OwnerReadSocket.writeFrame(encoded, fd: fd, limit: OwnerReadWire.requestLimit,
                                           deadline: min(deadline, OwnerReadSocket.now + 2), cancelled: cancelled)
            let bytes = try OwnerReadSocket.readFrame(fd, limit: OwnerReadWire.responseLimit, deadline: deadline,
                cancelled: { cancelled() || (try? peer.checkBirth()) == nil })
            guard !cancelled(), OwnerReadSocket.now < deadline else { throw OwnerReadFault.cancelled }
            try peer.verify()
            let payload = try OwnerReadWire.payload(bytes, request: request,
                distinguishRejection: false)
            guard !cancelled(), OwnerReadSocket.now < deadline else { throw OwnerReadFault.cancelled }
            return payload
        }
        logFailed = false; return result
    }
    /// Preserve the original finite transport/rejection error after sending.
    /// Business callers decide recovery from their original operation record.
    static func receiveAfterPossibleSend(tool: String, receive: () throws -> Data) throws -> Data {
        do { return try receive() }
        catch let rejection as OwnerReadExplicitRejection { throw rejection }
        catch {
            throw error
        }
    }
}
