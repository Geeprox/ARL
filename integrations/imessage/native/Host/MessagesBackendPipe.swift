import Foundation
import CoreFoundation
import Darwin

/// Evidence belongs to this Process object's termination callback, never a PID lookup.
private final class MessagesBackendExitRecord: @unchecked Sendable {
    private let lock = NSLock()
    private var clean = false
    func record(cleanExit: Bool) { lock.lock(); clean = cleanExit; lock.unlock() }
    var cleanExit: Bool { lock.lock(); defer { lock.unlock() }; return clean }
}

/// One owned sealed backend. Public Control never gets these pipes or operations.
final class MessagesBackendPipe: @unchecked Sendable {
    private struct Pending {
        let continuation: CheckedContinuation<MessagesJSON, Error>
        let timer: DispatchWorkItem
    }
    private struct Callback {
        let token: UUID
        var task: Task<Void, Never>?
    }
    private let lock = NSLock()
    private let writes = DispatchQueue(label: "local.arl.messages.backend-writes")
    private var pending: [String: Pending] = [:]
    private var callbacks: [String: Callback] = [:]
    private var closed = false
    private var queuedWrites = 0
    private var readerExited = false
    private var writerClosed = false
    private var closeFailed = false
    private let exitRecord = MessagesBackendExitRecord()
    private let process: Process
    private let input: FileHandle
    private let output: FileHandle
    private let native: @Sendable (String, MessagesJSON) async throws -> MessagesJSON
    private var stopSeconds: Double = 5

    init(python: String, bootstrap: String, cache: String,
         native: @escaping @Sendable (String, MessagesJSON) async throws -> MessagesJSON) throws {
        self.native = native
        process = Process()
        let stdin = Pipe(), stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-I", "-B", "-X", "pycache_prefix=" + cache, "-u", bootstrap]
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"]
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        input = stdin.fileHandleForWriting
        output = stdout.fileHandleForReading
        try Self.configure(input: input.fileDescriptor, output: output.fileDescriptor)
        process.terminationHandler = { [exitRecord] child in
            exitRecord.record(cleanExit: child.terminationReason == .exit && child.terminationStatus == 0)
        }
        try process.run()
        DispatchQueue.global().async { [self] in readLoop() }
    }

    #if MESSAGES_HOST_FIXTURE
    /// Owns only the supplied memory pipes. No process is launched.
    init(fixtureInput: FileHandle, fixtureOutput: FileHandle,
         native: @escaping @Sendable (String, MessagesJSON) async throws -> MessagesJSON) throws {
        self.native = native
        process = Process()
        input = fixtureInput
        output = fixtureOutput
        stopSeconds = 0.2
        try Self.configure(input: input.fileDescriptor, output: output.fileDescriptor)
        DispatchQueue.global().async { [self] in readLoop() }
    }
    var fixtureClosed: Bool { isClosed }
    var fixturePendingCount: Int { lock.lock(); defer { lock.unlock() }; return pending.count }
    var fixtureCallbackCount: Int { lock.lock(); defer { lock.unlock() }; return callbacks.count }
    var fixtureIOSettled: Bool { ioSettled }
    /// Synthetic stop-state test input, never proof of a real child exit.
    func fixtureObserveCleanExit() { exitRecord.record(cleanExit: true) }
    #endif

    private static func configure(input: Int32, output: Int32) throws {
        for fd in [input, output] {
            let flags = fcntl(fd, F_GETFL)
            guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0,
                  fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { throw MessagesTransportFault("host_unavailable") }
        }
        guard fcntl(input, F_SETNOSIGPIPE, 1) == 0 else { throw MessagesTransportFault("host_unavailable") }
    }
    private var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return closed }
    private var ioSettled: Bool {
        lock.lock(); defer { lock.unlock() }
        return closed && pending.isEmpty && callbacks.isEmpty && queuedWrites == 0
            && readerExited && writerClosed && !closeFailed
    }
    private func requestCurrent(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }; return !closed && pending[id] != nil
    }
    private static func bytes(_ frame: MessagesJSON) throws -> Data {
        var data = try frame.data
        guard data.count <= 65536 else { throw MessagesTransportFault("invalid_request") }
        data.append(10); return data
    }

    func request(_ operation: String, _ arguments: MessagesJSON, seconds: Double = 15) async throws -> MessagesJSON {
        let id = UUID().uuidString.lowercased()
        return try await exchange(id: id, frame: MessagesJSON(["schema_version": 1, "type": "request",
            "id": id, "operation": operation, "arguments": arguments.value]), seconds: seconds, timeout: "verification_timeout")
    }
    func initialize(_ config: MessagesJSON) async throws -> MessagesJSON {
        let id = UUID().uuidString.lowercased()
        return try await exchange(id: id, frame: MessagesJSON(["schema_version": 1, "type": "initialize",
            "id": id, "config": config.value]), seconds: 15, timeout: "host_unavailable")
    }
    private func exchange(id: String, frame: MessagesJSON, seconds: Double, timeout: String) async throws -> MessagesJSON {
        guard seconds.isFinite, seconds > 0, seconds <= 195 else { throw MessagesTransportFault("invalid_request") }
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        let data = try Self.bytes(frame)
        return try await withCheckedThrowingContinuation { continuation in
            let timer = DispatchWorkItem { [weak self] in
                self?.finish(id, failure: MessagesTransportFault(timeout))
            }
            lock.lock()
            guard !closed, pending.count < 16 else {
                lock.unlock(); continuation.resume(throwing: MessagesTransportFault("host_unavailable")); return
            }
            pending[id] = Pending(continuation: continuation, timer: timer)
            lock.unlock()
            // Deadline is established before serialized write admission; a full pipe cannot defer it.
            DispatchQueue.global().asyncAfter(deadline: .now() + max(0, deadline - ProcessInfo.processInfo.systemUptime), execute: timer)
            enqueue(data, deadline: deadline, requestID: id) { [weak self] error in
                if let error { self?.finish(id, failure: error) }
            }
        }
    }
    private func finish(_ id: String, result: MessagesJSON? = nil, failure: Error? = nil) {
        lock.lock(); let item = pending.removeValue(forKey: id); lock.unlock()
        guard let item else { return }
        item.timer.cancel()
        if let result { item.continuation.resume(returning: result) }
        else { item.continuation.resume(throwing: failure ?? MessagesTransportFault("host_unavailable")) }
    }

    private func enqueue(_ data: Data, deadline: Double, requestID: String? = nil,
                         completion: @escaping @Sendable (Error?) -> Void) {
        lock.lock()
        guard !closed, queuedWrites < 24 else {
            lock.unlock(); completion(MessagesTransportFault("host_unavailable")); return
        }
        queuedWrites += 1; lock.unlock()
        writes.async { [self] in
            defer { lock.lock(); queuedWrites -= 1; lock.unlock() }
            if let requestID, !requestCurrent(requestID) {
                completion(MessagesTransportFault("verification_timeout")); return
            }
            do { try writeBytes(data, deadline: deadline); completion(nil) }
            catch {
                // A partially emitted frame has uncertain outcome; never resume the stream or retry it.
                closeAll(); completion(error)
            }
        }
    }
    private func writeReply(_ frame: MessagesJSON) async throws {
        let data = try Self.bytes(frame)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            enqueue(data, deadline: ProcessInfo.processInfo.systemUptime + 5) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }
    private func writeBytes(_ data: Data, deadline: Double) throws {
        var offset = 0
        while offset < data.count {
            guard !isClosed else { throw MessagesTransportFault("host_unavailable") }
            let left = deadline - ProcessInfo.processInfo.systemUptime
            guard left > 0 else { throw MessagesTransportFault("verification_timeout") }
            var item = pollfd(fd: input.fileDescriptor, events: Int16(POLLOUT), revents: 0)
            let ready = poll(&item, 1, Int32(max(1, min(100, ceil(left * 1000)))))
            if ready < 0 && errno == EINTR { continue }
            guard ready >= 0, item.revents & Int16(POLLERR | POLLHUP | POLLNVAL) == 0 else {
                throw MessagesTransportFault("host_unavailable")
            }
            if ready == 0 { continue }
            let written = data.withUnsafeBytes { Darwin.write(input.fileDescriptor, $0.baseAddress!.advanced(by: offset), data.count - offset) }
            if written < 0 && (errno == EAGAIN || errno == EINTR) { continue }
            guard written > 0 else { throw MessagesTransportFault("host_unavailable") }
            offset += written
        }
    }
    private func readFrame() throws -> Data? {
        var data = Data()
        let deadline = ProcessInfo.processInfo.systemUptime + 1000
        while true {
            if isClosed { return nil }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw MessagesTransportFault("transport_deadline") }
            var item = pollfd(fd: output.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&item, 1, 100)
            if ready < 0 && errno == EINTR { continue }
            guard ready >= 0, item.revents & Int16(POLLNVAL) == 0 else { throw MessagesTransportFault("host_unavailable") }
            if ready == 0 { continue }
            var byte: UInt8 = 0
            let size = Darwin.read(output.fileDescriptor, &byte, 1)
            if size < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            if size == 0 {
                guard data.isEmpty else { throw MessagesTransportFault("transport_truncated") }
                return nil
            }
            guard size == 1 else { throw MessagesTransportFault("host_unavailable") }
            if byte == 10 { return data }
            guard data.count < 65536 else { throw MessagesTransportFault("transport_size_exceeded") }
            data.append(byte)
        }
    }
    private func readLoop() {
        defer {
            closeAll()
            var failed = false
            do { try output.close() } catch { failed = true }
            lock.lock(); closeFailed = closeFailed || failed; readerExited = true; lock.unlock()
        }
        do {
            while let data = try readFrame() {
                let frame = try MessagesJSON.decode(data)
                guard MessagesNativeIO.integer(frame.value["schema_version"]) == 1,
                      let type = frame.value["type"] as? String, let id = frame.value["id"] as? String else {
                    throw MessagesTransportFault("invalid_response")
                }
                if type == "response" {
                    guard let ok = frame.value["ok"] as? NSNumber, CFGetTypeID(ok) == CFBooleanGetTypeID() else {
                        throw MessagesTransportFault("invalid_response")
                    }
                    if ok.boolValue, let result = frame.value["result"] as? [String: Any] { finish(id, result: MessagesJSON(result)) }
                    else { finish(id, failure: MessagesTransportFault(frame.value["code"] as? String ?? "host_unavailable")) }
                } else if type == "native_request", let operation = frame.value["operation"] as? String,
                          let arguments = frame.value["arguments"] as? [String: Any] {
                    try startCallback(id: id, operation: operation, arguments: MessagesJSON(arguments))
                } else { throw MessagesTransportFault("invalid_response") }
            }
        } catch { /* A malformed/failed channel has no success evidence. */ }
    }
    private func startCallback(id: String, operation: String, arguments: MessagesJSON) throws {
        lock.lock()
        guard !closed, callbacks.count < 8, !callbacks.keys.contains(id) else {
            lock.unlock(); throw MessagesTransportFault("host_unavailable")
        }
        let token = UUID()
        callbacks[id] = Callback(token: token, task: nil); lock.unlock()
        let task = Task { [self] in
            defer { finishCallback(id, token: token) }
            guard !isClosed, !Task.isCancelled else { return }
            do {
                let result = try await native(operation, arguments)
                guard !isClosed, !Task.isCancelled else { return }
                try await writeReply(MessagesJSON(["schema_version": 1, "type": "native_response", "id": id, "ok": true, "result": result.value]))
            } catch {
                guard !isClosed, !Task.isCancelled else { return }
                let code = (error as? MessagesTransportFault)?.code ?? "host_unavailable"
                try? await writeReply(MessagesJSON(["schema_version": 1, "type": "native_response", "id": id, "ok": false, "code": code]))
            }
        }
        lock.lock()
        if callbacks[id]?.token == token { callbacks[id]?.task = task }
        let cancel = closed || callbacks[id]?.token != token
        lock.unlock()
        if cancel { task.cancel() }
    }
    private func finishCallback(_ id: String, token: UUID) {
        lock.lock()
        if callbacks[id]?.token == token { callbacks.removeValue(forKey: id) }
        lock.unlock()
    }
    func closeAll() {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true
        let values = Array(pending.values); pending.removeAll()
        let tasks = callbacks.values.compactMap { $0.task }
        lock.unlock()
        for item in values { item.timer.cancel(); item.continuation.resume(throwing: MessagesTransportFault("host_unavailable")) }
        for task in tasks { task.cancel() }
        // The writer owns input.close; the reader alone closes output after its bounded poll exits.
        writes.async { [self] in
            var failed = false
            do { try input.close() } catch { failed = true }
            lock.lock(); closeFailed = closeFailed || failed; writerClosed = true; lock.unlock()
        }
    }
    func terminate() async -> Bool {
        closeAll() // EOF first. No raw PID signals and no isRunning-only success claim.
        let deadline = ProcessInfo.processInfo.systemUptime + stopSeconds
        repeat {
            if exitRecord.cleanExit && ioSettled { return true }
            // Cleanup remains bounded even if the caller task is already cancelled.
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.02) { continuation.resume() }
            }
        } while ProcessInfo.processInfo.systemUptime < deadline
        return exitRecord.cleanExit && ioSettled
    }
    var pid: Int32 { process.processIdentifier }
}
