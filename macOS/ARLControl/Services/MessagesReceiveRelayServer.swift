import Foundation
import Darwin
import Security
import CryptoKit

/// Attests the managed core child, not a JSON app-ID claim. The trusted core
/// separately verifies the original application registration/session and policy.
struct MessagesReceiveRelayPeer: Sendable {
    let fd: Int32
    let token: Data
    let pid: pid_t
    let birthSeconds: UInt64
    let birthMicros: UInt64
    let executable: String
    let parentPID: pid_t
    let requirement: String
    private static func process(_ pid: pid_t) throws -> (UInt64, UInt64, String, pid_t) {
        var info = proc_bsdinfo(), bytes = [CChar](repeating: 0, count: 4096)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size,
              info.pbi_uid == getuid(), proc_pidpath(pid, &bytes, UInt32(bytes.count)) > 0 else { throw MessagesReceiveFault("receive_relay_peer_unverified") }
        let raw = bytes.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
        guard let path = String(bytes: raw, encoding: .utf8) else { throw MessagesReceiveFault("receive_relay_peer_unverified") }
        return (info.pbi_start_tvsec, info.pbi_start_tvusec, path, pid_t(info.pbi_ppid))
    }
    init(fd: Int32, expectedPID: pid_t, expectedExecutable: URL, expectedParentPID: pid_t) throws {
        var raw = [UInt8](repeating: 0, count: 32), size: socklen_t = 32
        guard expectedPID > 1, getsockopt(fd, 0, 6, &raw, &size) == 0, size == 32 else { throw MessagesReceiveFault("receive_relay_peer_unverified") }
        let audit = Data(raw)
        let actualPID = audit.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 20, as: UInt32.self) }
        let uid = audit.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) }
        guard actualPID == UInt32(expectedPID), uid == getuid() else { throw MessagesReceiveFault("receive_relay_peer_unverified") }
        let info = try Self.process(expectedPID)
        guard info.2 == expectedExecutable.path, info.3 == expectedParentPID else { throw MessagesReceiveFault("receive_relay_peer_unverified") }
        var code: SecStaticCode?, signing: CFDictionary?
        guard SecStaticCodeCreateWithPath(expectedExecutable as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess,
              SecCodeCopySigningInformation(code, [], &signing) == errSecSuccess,
              let cdhash = (signing as? [String: Any])?[kSecCodeInfoUnique as String] as? Data, !cdhash.isEmpty else {
            throw MessagesReceiveFault("receive_relay_signature_unverified")
        }
        self.fd = fd; token = audit; pid = expectedPID; birthSeconds = info.0; birthMicros = info.1; executable = info.2; parentPID = expectedParentPID
        requirement = "cdhash H\"" + cdhash.map { String(format: "%02x", $0) }.joined() + "\""
        try verify()
    }
    func verify() throws {
        var raw = [UInt8](repeating: 0, count: 32), size: socklen_t = 32
        guard getsockopt(fd, 0, 6, &raw, &size) == 0, size == 32, Data(raw) == token else { throw MessagesReceiveFault("receive_relay_peer_unverified") }
        let info = try Self.process(pid)
        guard info.0 == birthSeconds, info.1 == birthMicros, info.2 == executable, info.3 == parentPID else { throw MessagesReceiveFault("receive_relay_peer_unverified") }
        var rule: SecRequirement?, guest: SecCode?, staticCode: SecStaticCode?
        guard SecRequirementCreateWithString(requirement as CFString, [], &rule) == errSecSuccess, let rule,
              SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit as String: token] as CFDictionary, [], &guest) == errSecSuccess, let guest,
              SecCodeCheckValidity(guest, [], rule) == errSecSuccess,
              SecCodeCopyStaticCode(guest, [], &staticCode) == errSecSuccess, let staticCode,
              SecStaticCodeCheckValidity(staticCode, SecCSFlags(rawValue: kSecCSStrictValidate), rule) == errSecSuccess else {
            throw MessagesReceiveFault("receive_relay_signature_unverified")
        }
    }
}

struct MessagesReceiveRelayRequest: Sendable {
    let requestID: String
    let method: String
    let parameters: Data
    let consumer: MessagesReceiveConsumer
}

final class MessagesReceiveRelayServer: @unchecked Sendable {
    typealias Authorize = @Sendable (Int32) async throws -> MessagesReceiveRelayPeer
    typealias Call = @Sendable (MessagesReceiveRelayRequest, MessagesReceiveRelayPeer) async throws -> Data
    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var stopped = false, ended = false, cleanupProven = false
        var cancelled: Bool { lock.withLock { stopped } }
        var drained: Bool { lock.withLock { ended && cleanupProven } }
        func stop() { lock.withLock { stopped = true } }
        func finish(clean: Bool) { lock.withLock { ended = true; cleanupProven = clean } }
    }
    private let state = State()
    private var worker: Task<Void, Never>?
    var drained: Bool { state.drained }
    private init(lease: SocketLease, authorize: @escaping Authorize, call: @escaping Call) {
        let state = state
        worker = Task.detached(priority: .utility) {
            defer { state.finish(clean: lease.close()) }
            while !state.cancelled {
                var p = pollfd(fd: lease.fd, events: Int16(POLLIN), revents: 0)
                let ready = poll(&p, 1, 50)
                if ready < 0 && errno == EINTR { continue }
                if ready <= 0 { if ready < 0 { break }; continue }
                let fd = accept(lease.fd, nil, nil)
                if fd < 0 { if errno == EINTR || errno == EAGAIN { continue }; break }
                do {
                    defer { _ = shutdown(fd, SHUT_RDWR); Darwin.close(fd) }
                    try Self.configure(fd)
                    let peer = try await authorize(fd); try peer.verify()
                    let raw = try Self.readFrame(fd, limit: 16384, deadline: Self.now + 2, state: state)
                    let request = try Self.decode(raw)
                    let bytes: Data
                    do {
                        guard !state.cancelled else { throw MessagesReceiveFault("receive_relay_stopping") }
                        try peer.verify()
                        let result = try await call(request, peer)
                        guard !state.cancelled else { throw MessagesReceiveFault("receive_relay_stopping") }
                        try peer.verify()
                        guard result.count <= 96 * 1024, let text = String(data: result, encoding: .utf8) else { throw MessagesReceiveFault("receive_wire_budget") }
                        bytes = try JSONSerialization.data(withJSONObject: ["schema_version": 1, "request_id": request.requestID, "ok": true, "result_json": text, "error_code": NSNull()], options: [.sortedKeys])
                    } catch {
                        let code = (error as? MessagesReceiveFault)?.code ?? "receive_unavailable"
                        bytes = try JSONSerialization.data(withJSONObject: ["schema_version": 1, "request_id": request.requestID, "ok": false, "result_json": NSNull(), "error_code": code], options: [.sortedKeys])
                    }
                    guard !state.cancelled else { throw MessagesReceiveFault("receive_relay_stopping") }
                    try peer.verify(); try Self.writeFrame(bytes, fd: fd, deadline: Self.now + 2, state: state)
                    // Keep the authenticated endpoint alive until the core has
                    // rechecked the native signature and original app lease.
                    var ack = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                    if poll(&ack, 1, 1000) > 0 { var byte: UInt8 = 0; _ = Darwin.read(fd, &byte, 1) }
                } catch {
                    #if ARL_MESSAGES_RECEIVE_FIXTURE
                    FileHandle.standardError.write(Data(("fixture-relay-rejected:" + ((error as? MessagesReceiveFault)?.code ?? "unavailable") + "\n").utf8))
                    #endif
                    continue
                }
            }
        }
    }
    static func start(home: URL, authorize: @escaping Authorize, call: @escaping Call) throws -> MessagesReceiveRelayServer {
        .init(lease: try SocketLease(home: home), authorize: authorize, call: call)
    }
    deinit { state.stop(); worker?.cancel() }
    func stopAndDrain(seconds: Double = 5) async -> Bool {
        state.stop(); worker?.cancel()
        let deadline = Self.now + seconds
        while !state.drained && Self.now < deadline {
            do { try await Task.sleep(for: .milliseconds(20)) } catch { return false }
        }
        return state.drained
    }
    private static var now: Double { ProcessInfo.processInfo.systemUptime }
    private static func configure(_ fd: Int32) throws {
        var noSignal: Int32 = 1
        guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0, fcntl(fd, F_SETFL, O_NONBLOCK) == 0,
              setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0 else { throw MessagesReceiveFault("receive_relay_unavailable") }
    }
    private static func readFrame(_ fd: Int32, limit: Int, deadline: Double, state: State) throws -> Data {
        var data = Data()
        while !state.cancelled && now < deadline && data.count <= limit {
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&p, 1, 50)
            if ready < 0 && errno == EINTR { continue }
            guard ready >= 0 else { throw MessagesReceiveFault("receive_relay_unavailable") }
            if ready == 0 { continue }
            var bytes = [UInt8](repeating: 0, count: min(4096, limit + 1 - data.count))
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            guard count > 0 else { throw MessagesReceiveFault("receive_relay_unavailable") }
            data.append(contentsOf: bytes.prefix(count))
            if let end = data.firstIndex(of: 10) {
                guard end == data.count - 1 else { throw MessagesReceiveFault("invalid_receive_request") }
                return data.prefix(end)
            }
        }
        throw MessagesReceiveFault("receive_relay_deadline_or_limit")
    }
    private static func writeFrame(_ data: Data, fd: Int32, deadline: Double, state: State) throws {
        guard data.count <= 512 * 1024 else { throw MessagesReceiveFault("receive_wire_budget") }
        var bytes = data; bytes.append(10); var offset = 0
        while offset < bytes.count && !state.cancelled && now < deadline {
            var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let ready = poll(&p, 1, 50)
            if ready < 0 && errno == EINTR { continue }
            guard ready >= 0 else { throw MessagesReceiveFault("receive_relay_unavailable") }
            if ready == 0 { continue }
            let count = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: offset), bytes.count - offset) }
            if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            guard count > 0 else { throw MessagesReceiveFault("receive_relay_unavailable") }; offset += count
        }
        guard offset == bytes.count else { throw MessagesReceiveFault("receive_relay_deadline_or_limit") }
    }
    private static func flat(_ data: Data) throws -> [String: Any] {
        guard data.count <= 16384, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw MessagesReceiveFault("invalid_receive_request") }
        let bytes = Array(data); var at = 0, keys = Set<String>()
        func space() { while at < bytes.count && [9, 10, 13, 32].contains(bytes[at]) { at += 1 } }
        func quoted() throws -> String {
            guard at < bytes.count && bytes[at] == 34 else { throw MessagesReceiveFault("invalid_receive_request") }; let start = at; at += 1; var escaped = false
            while at < bytes.count { let byte = bytes[at]; at += 1; if escaped { escaped = false; continue }; if byte == 92 { escaped = true; continue }; if byte == 34 {
                guard let value = try JSONSerialization.jsonObject(with: Data(bytes[start..<at]), options: .fragmentsAllowed) as? String else { throw MessagesReceiveFault("invalid_receive_request") }; return value
            } }
            throw MessagesReceiveFault("invalid_receive_request")
        }
        space(); guard at < bytes.count && bytes[at] == 123 else { throw MessagesReceiveFault("invalid_receive_request") }; at += 1; space()
        if at < bytes.count && bytes[at] == 125 { at += 1 } else {
            while true {
                let key = try quoted(); guard keys.insert(key).inserted else { throw MessagesReceiveFault("duplicate_receive_key") }; space()
                guard at < bytes.count && bytes[at] == 58 else { throw MessagesReceiveFault("invalid_receive_request") }; at += 1; space()
                if at < bytes.count && bytes[at] == 34 { _ = try quoted() } else {
                    let start = at; while at < bytes.count && ![44, 125, 9, 10, 13, 32].contains(bytes[at]) { at += 1 }
                    guard String(decoding: bytes[start..<at], as: UTF8.self) == "1" else { throw MessagesReceiveFault("invalid_receive_request") }
                }
                space(); guard at < bytes.count else { throw MessagesReceiveFault("invalid_receive_request") }
                if bytes[at] == 125 { at += 1; break }
                guard bytes[at] == 44 else { throw MessagesReceiveFault("invalid_receive_request") }; at += 1; space()
            }
        }
        space(); guard at == bytes.count && keys == Set(object.keys) else { throw MessagesReceiveFault("invalid_receive_request") }; return object
    }
    private static func decode(_ data: Data) throws -> MessagesReceiveRelayRequest {
        let object = try flat(data)
        guard Set(object.keys) == ["schema_version", "request_id", "method", "consumer_app_id", "consumer_session_id", "consumer_generation", "parameters_json"],
              object["schema_version"] as? Int == 1, let id = object["request_id"] as? String, UUID(uuidString: id)?.uuidString.lowercased() == id,
              let method = object["method"] as? String, ["messages.receive.status", "messages.receive.pull", "messages.receive.ack"].contains(method),
              let app = object["consumer_app_id"] as? String, app.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$", options: .regularExpression) != nil,
              let session = object["consumer_session_id"] as? String, session.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
              let generation = object["consumer_generation"] as? String, generation.range(of: "^[a-f0-9]{64,128}$", options: .regularExpression) != nil,
              let parameters = object["parameters_json"] as? String, parameters.utf8.count <= 2048 else { throw MessagesReceiveFault("invalid_receive_request") }
        return .init(requestID: id, method: method, parameters: Data(parameters.utf8), consumer: .init(appID: app, sessionID: session, registrationGeneration: generation, authorizedCapabilities: [MessagesReceiveService.capability]))
    }
    private final class SocketLease: @unchecked Sendable {
        let fd: Int32
        private let path: String
        private let device: dev_t
        private let inode: ino_t
        private let lockFD: Int32
        private let directory: Int32
        init(home: URL) throws {
            let parts = home.path.split(separator: "/")
            guard home.path.hasPrefix("/"), parts.allSatisfy({ $0 != "." && $0 != ".." }) else { throw MessagesReceiveFault("receive_relay_home_unsafe") }
            var parent = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard parent >= 0 else { throw MessagesReceiveFault("receive_relay_home_unsafe") }
            do {
                for part in parts { let next = openat(parent, String(part), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC); guard next >= 0 else { throw MessagesReceiveFault("receive_relay_home_unsafe") }; Darwin.close(parent); parent = next }
                var info = stat()
                guard fstat(parent, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o777 == 0o700 else { throw MessagesReceiveFault("receive_relay_home_unsafe") }
                let lock = openat(parent, "messages-receive.socket.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
                guard lock >= 0 else { throw MessagesReceiveFault("receive_relay_owner_busy") }
                do {
                    guard fstat(lock, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_mode & 0o777 == 0o600, info.st_nlink == 1,
                          flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw MessagesReceiveFault("receive_relay_owner_busy") }
                    path = home.appendingPathComponent("messages-receive.sock").path
                    var address = sockaddr_un(); let bytes = Array(path.utf8) + [0]
                    guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw MessagesReceiveFault("receive_relay_path_limit") }
                    address.sun_family = sa_family_t(AF_UNIX); address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
                    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
                    var old = stat()
                    if lstat(path, &old) == 0 {
                        guard old.st_mode & S_IFMT == S_IFSOCK, old.st_uid == getuid(), old.st_mode & 0o777 == 0o600 else { throw MessagesReceiveFault("receive_relay_socket_cleanup_required") }
                        // Exclusive owner lock + an explicitly refused local
                        // connection prove this exact socket has no listener.
                        // A live/uncertain endpoint or changed inode is retained.
                        let probe = socket(AF_UNIX, SOCK_STREAM, 0)
                        guard probe >= 0 else { throw MessagesReceiveFault("receive_relay_socket_cleanup_required") }
                        let flags = fcntl(probe, F_GETFL)
                        guard flags >= 0, fcntl(probe, F_SETFL, flags | O_NONBLOCK) == 0 else { Darwin.close(probe); throw MessagesReceiveFault("receive_relay_socket_cleanup_required") }
                        let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
                        let failure = errno; Darwin.close(probe)
                        var current = stat()
                        guard connected < 0, failure == ECONNREFUSED, lstat(path, &current) == 0,
                              current.st_dev == old.st_dev, current.st_ino == old.st_ino, current.st_uid == old.st_uid,
                              current.st_mode == old.st_mode, unlink(path) == 0, fsync(parent) == 0 else { throw MessagesReceiveFault("receive_relay_socket_cleanup_required") }
                    } else if errno != ENOENT { throw MessagesReceiveFault("receive_relay_socket_cleanup_required") }
                    let socketFD = socket(AF_UNIX, SOCK_STREAM, 0); guard socketFD >= 0 else { throw MessagesReceiveFault("receive_relay_unavailable") }
                    do {
                        try MessagesReceiveRelayServer.configure(socketFD)
                        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
                        guard bound == 0, chmod(path, 0o600) == 0, listen(socketFD, 1) == 0, lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK,
                              info.st_uid == getuid(), info.st_mode & 0o777 == 0o600 else { throw MessagesReceiveFault("receive_relay_unavailable") }
                        fd = socketFD; device = info.st_dev; inode = info.st_ino; lockFD = lock; directory = parent
                    } catch { Darwin.close(socketFD); throw error }
                } catch { Darwin.close(lock); throw error }
            } catch { Darwin.close(parent); throw error }
        }
        func close() -> Bool {
            let closed = Darwin.close(fd) == 0
            var info = stat()
            var removed = false
            if lstat(path, &info) == 0 && info.st_dev == device && info.st_ino == inode && info.st_mode & S_IFMT == S_IFSOCK && info.st_uid == getuid() {
                removed = unlink(path) == 0 && fsync(directory) == 0
            } else if errno == ENOENT { removed = true }
            flock(lockFD, LOCK_UN); Darwin.close(lockFD); Darwin.close(directory)
            return closed && removed
        }
    }
}
