import Foundation
import Darwin
import CryptoKit
import CoreFoundation
import OSLog

/// Diagnostic metadata only. Failure is deliberately non-throwing and never an admission gate.
final class ARLConnectionLog: @unchecked Sendable {
    static let production = ARLConnectionLog(directory: FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/ARL/connection-logs.noindex"), enabled:
        (Bundle.main.bundleIdentifier == "local.arl.control" && Bundle.main.object(forInfoDictionaryKey: "ARLCoreRuntimeManifestSHA256") != nil) ||
        (Bundle.main.bundleIdentifier == "local.arl.mioapplebridge" && Bundle.main.object(forInfoDictionaryKey: "ARLApprovedPolicySHA256") != nil))
    private static let logger = Logger(subsystem: "local.arl.control", category: "Connection")
    private let directory: URL, enabled: Bool, rotateBytes: Int, retainDays: Int, clock: @Sendable () -> Date
    private let lock = NSLock(), session = UUID().uuidString
    private var fd: Int32 = -1, bytes = 0, day = -1
    private var warned = false
    init(directory: URL, enabled: Bool = true, rotateBytes: Int = 4 * 1024 * 1024,
         retainDays: Int = 7, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory; self.enabled = enabled; self.rotateBytes = max(256, rotateBytes)
        self.retainDays = max(7, retainDays); self.clock = clock
    }
    deinit { if fd >= 0 { close(fd) } }
    static func fingerprint(_ value: Any?) -> String? {
        guard let value, let raw = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]) else { return nil }
        return SHA256.hash(data: raw).map { String(format: "%02x", $0) }.joined()
    }
    static func requestFields(_ request: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        if let value = fingerprint(request["id"]) { result["rpc_id_sha256"] = value }
        if let method = request["method"] as? String, ["initialize", "ping", "tools/list", "tools/call", "notifications/initialized"].contains(method) { result["method"] = method }
        if let name = (request["params"] as? [String: Any])?["name"] as? String { result["tool_sha256"] = fingerprint(name) }
        return result
    }
    func record(_ source: String, _ event: String, _ fields: [String: Any] = [:]) {
        guard enabled, ["arl", "core", "mio", "tunnel", "gateway", "owner"].contains(source),
              ["starting", "started", "stopping", "stopped", "start_failed", "connected", "disconnected", "retry", "request_received", "request_finished", "owner_request", "owner_finished", "upstream_event", "output_eof", "output_oversize", "startup"].contains(event) else { return }
        lock.lock(); defer { lock.unlock() }
        let now = clock()
        var value: [String: Any] = ["schema": 1, "at_ms": Int64(now.timeIntervalSince1970 * 1000), "pid": getpid(), "session_id": session, "source": source, "event": event]
        value["scope"] = source == "tunnel" ? "upstream_sdk_emitted" : ["owner", "gateway"].contains(source) ? "local_owner_ipc" : source == "mio" ? "local_mio_host" : "owned_process"
        for (key, item) in fields {
            if ["elapsed_ms", "http_status", "retry_in_ms", "exit_code", "peer_pid", "line_bytes", "os_code"].contains(key),
               let number = item as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
               abs(number.doubleValue) <= 1e12 {
                if key == "http_status", !(100...599).contains(number.intValue) { continue }
                if ["elapsed_ms", "retry_in_ms", "line_bytes"].contains(key), number.doubleValue < 0 { continue }
                value[key] = number
            }
            else if ["failed", "completed"].contains(key), let boolean = item as? Bool { value[key] = boolean }
            else if ["rpc_id_sha256", "tool_sha256", "message_sha256", "client_instance_sha256", "tunnel_request_sha256", "upstream_request_sha256", "command_request_sha256", "code_sha256"].contains(key),
                    let text = item as? String, text.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil { value[key] = text }
            else if key == "owner_call_id", let text = item as? String, let uuid = UUID(uuidString: text) { value[key] = uuid.uuidString }
            else if key == "method", let text = item as? String, ["initialize", "ping", "tools/list", "tools/call", "notifications/initialized"].contains(text) { value[key] = text }
            else if key == "stream", let text = item as? String, ["stdout", "stderr"].contains(text) { value[key] = text }
            else if key == "level", let text = item as? String, ["DEBUG", "INFO", "WARN", "ERROR"].contains(text) { value[key] = text }
            else if key == "error_kind", let text = item as? String, ["timeout", "tls", "authorization", "transport", "unspecified"].contains(text) { value[key] = text }
        }
        guard var line = try? JSONSerialization.data(withJSONObject: value, options: .sortedKeys) else { return }
        line.append(10)
        let currentDay = Int(now.timeIntervalSince1970 / 86400)
        if fd < 0 || day != currentDay || bytes + line.count > rotateBytes {
            if fd >= 0 { close(fd); fd = -1 }
            guard let dir = openDirectory() else { unavailable(); return }; defer { close(dir) }
            prune(dir, before: now.timeIntervalSince1970 - Double(retainDays * 86400))
            let name = "connection-\(currentDay)-\(getpid())-\(UUID().uuidString).jsonl"
            fd = openat(dir, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { unavailable(); return }
            day = currentDay; bytes = 0
        }
        var offset = 0
        let ok = line.withUnsafeBytes { raw -> Bool in
            while offset < raw.count {
                let count = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if count < 0 && errno == EINTR { continue }
                if count <= 0 { return false }; offset += count
            }
            return fsync(fd) == 0
        }
        if ok { bytes += line.count }
        else { close(fd); fd = -1; unavailable() } // keep a partial segment; never append another record to it
    }
    private func unavailable() {
        if !warned { warned = true; Self.logger.error("Connection metadata journal unavailable; business execution continues") }
    }
    private func openDirectory() -> Int32? {
        var current = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard current >= 0 else { return nil }
        for part in directory.pathComponents.dropFirst() {
            var next = openat(current, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0 && errno == ENOENT {
                _ = mkdirat(current, part, 0o700)
                next = openat(current, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            close(current); current = next
            guard current >= 0 else { return nil }
            var st = stat()
            guard fstat(current, &st) == 0, st.st_uid == 0 || st.st_uid == getuid(), st.st_mode & 0o022 == 0 else { close(current); return nil }
        }
        var st = stat()
        guard fstat(current, &st) == 0, st.st_uid == getuid(), st.st_mode & 0o077 == 0 else { close(current); return nil }
        return current
    }
    private func prune(_ dir: Int32, before: Double) {
        let duplicate = dup(dir); guard duplicate >= 0 else { return }
        guard let listing = fdopendir(duplicate) else { close(duplicate); return }; defer { closedir(listing) }
        while let item = readdir(listing) {
            let name = withUnsafePointer(to: &item.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
            }
            guard name.range(of: "^connection-[0-9]+-[0-9]+-[A-F0-9-]{36}\\.jsonl$", options: .regularExpression) != nil else { continue }
            var st = stat()
            if fstatat(dir, name, &st, AT_SYMLINK_NOFOLLOW) == 0, st.st_mode & S_IFMT == S_IFREG,
               st.st_uid == getuid(), st.st_nlink == 1, Double(st.st_mtimespec.tv_sec) < before { _ = unlinkat(dir, name, 0) }
        }
    }
    func capture(_ pipe: Pipe, source: String, stream: String) {
        let parser = ARLConnectionOutput(log: self, source: source, stream: stream)
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            parser.feed(data, end: data.isEmpty)
            if data.isEmpty { handle.readabilityHandler = nil }
        }
    }
}

/// Consume every line, but persist only allowlisted metadata. Raw text/headers/URLs never reach disk.
final class ARLConnectionOutput: @unchecked Sendable {
    private let log: ARLConnectionLog, source: String, stream: String, lock = NSLock()
    private var bytes = Data(), count = 0, dropping = false
    init(log: ARLConnectionLog, source: String, stream: String) { self.log = log; self.source = source; self.stream = stream }
    func feed(_ data: Data, end: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        for byte in data {
            if byte == 10 { finish() }
            else { count += 1; if bytes.count < 65536 && !dropping { bytes.append(byte) } else { dropping = true; bytes.removeAll() } }
        }
        if end { if count > 0 { finish() }; log.record(source, "output_eof", ["stream": stream]) }
    }
    private func finish() {
        defer { bytes.removeAll(keepingCapacity: true); count = 0; dropping = false }
        if dropping { log.record(source, "output_oversize", ["stream": stream, "line_bytes": count]); return }
        guard !bytes.isEmpty else { return }
        var fields: [String: Any] = ["stream": stream, "line_bytes": count]
        let object = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] ?? [:]
        let attrs = object["attrs"] as? [String: Any] ?? object
        let message = object["msg"] as? String ?? object["message"] as? String ?? ""
        fields["message_sha256"] = ARLConnectionLog.fingerprint(message.isEmpty ? String(decoding: bytes, as: UTF8.self) : message)
        if let level = (object["level"] as? String)?.uppercased() { fields["level"] = level }
        for (keys, target) in [(["http_status", "status_code"], "http_status"), (["elapsed_ms", "duration_ms"], "elapsed_ms"), (["retry_in_ms"], "retry_in_ms")] {
            for key in keys { if let n = attrs[key] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { fields[target] = n; break } }
        }
        if let id = attrs["client_instance_id"] { fields["client_instance_sha256"] = ARLConnectionLog.fingerprint(id) }
        if let id = attrs["tunnel_request_id"] { fields["tunnel_request_sha256"] = ARLConnectionLog.fingerprint(id) }
        for (key, target) in [("request_id", "upstream_request_sha256"), ("cmd_request_id", "command_request_sha256"), ("rpc_request_id", "rpc_id_sha256")] {
            if let id = attrs[key] { fields[target] = ARLConnectionLog.fingerprint(id) }
        }
        let error = attrs["error"] as? String ?? ""
        let raw = (error.isEmpty ? String(decoding: bytes, as: UTF8.self) : error).lowercased()
        let failed = !error.isEmpty || fields["level"] as? String == "ERROR" || ((fields["http_status"] as? NSNumber)?.intValue ?? 0) >= 400
        fields["failed"] = failed
        if failed {
            fields["error_kind"] = raw.contains("timeout") || raw.contains("deadline") || raw.contains("timed out") ? "timeout" :
                raw.contains("certificate") || raw.contains("tls") ? "tls" : raw.contains("unauthorized") || raw.contains("forbidden") ? "authorization" : "transport"
        }
        log.record(source, fields["retry_in_ms"] == nil ? "upstream_event" : "retry", fields)
    }
}
