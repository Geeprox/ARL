import Foundation
import Darwin

public indirect enum ARLJSON: Codable, Sendable, Equatable {
    case object([String: ARLJSON]), array([ARLJSON]), string(String), number(Double), bool(Bool), null
    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let v = try? value.decode(Bool.self) { self = .bool(v) }
        else if let v = try? value.decode(String.self) { self = .string(v) }
        else if let v = try? value.decode(Double.self) { self = .number(v) }
        else if let v = try? value.decode([String: ARLJSON].self) { self = .object(v) }
        else { self = .array(try value.decode([ARLJSON].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .object(let v): try value.encode(v)
        case .array(let v): try value.encode(v)
        case .string(let v): try value.encode(v)
        case .number(let v): try value.encode(v)
        case .bool(let v): try value.encode(v)
        case .null: try value.encodeNil()
        }
    }
    public subscript(key: String) -> ARLJSON? {
        if case .object(let values) = self { return values[key] }
        return nil
    }
    public var text: String? { if case .string(let v) = self { return v }; return nil }
}

public struct ARLError: Error, Sendable {
    public let code: String
    public init(code: String) { self.code = code }
}
private struct Reply: Decodable { let `protocol`: String; let ok: Bool; let result: ARLJSON?; let error: RemoteError? }
private struct RemoteError: Decodable { let code: String }

/// Public read-only settings surface; no heartbeat, task, configuration or credential writes.
public enum ARLSettingsMethod: String, Sendable {
    case health, ready, overview
    case snapshot = "settings.snapshot"
    case logs = "settings.logs"
    case logsExport = "settings.logs_export"
}

/// Native Swift 6 consumer for registered local applications. Actor keeps blocking socket I/O off MainActor.
/// Trusted local-user transport; app is a logical namespace, not a signed identity.
public actor ARLClient {
    private let home: URL
    private let app: String
    private var appSession: String?
    private let launcher: (@Sendable () throws -> Void)?
    public init(home: URL, app: String, launcher: (@Sendable () throws -> Void)? = nil) {
        self.home = home; self.app = app; self.launcher = launcher
    }
    public func describeRuntime() throws -> ARLJSON {
        let value = try rpc("runtime.describe")
        guard case .object(let fields) = value,
              Set(fields.keys) == ["schema_version", "protocol", "version", "boot_id", "source_sha256", "features", "ready"],
              value["schema_version"] == .number(1), value["protocol"] == .string("arl/1"),
              value["version"]?.text != nil,
              case .bool? = value["ready"],
              let boot = value["boot_id"]?.text, let source = value["source_sha256"]?.text,
              [boot, source].allSatisfy({ $0.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil }),
              case .object(let features)? = value["features"],
              features.values.allSatisfy({ if case .number(let n) = $0 { return n >= 1 && n.rounded() == n }; return false })
        else { throw ARLError(code: "invalid_response") }
        return value
    }
    /// Identity registration is host-owned. This exchange grants no new tools.
    public func openAppSession(name: String, capabilities: [String], icon: String = "sf:app", version: String? = nil) throws -> [String] {
        let nonce = (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased()
        let reply = try rpc("connection.open", params: ["client_nonce":.string(nonce),"name":.string(name),
            "icon_ref":.string(icon),"version":version.map(ARLJSON.string) ?? .null,
            "capabilities":.array(capabilities.map(ARLJSON.string))])
        guard reply["schema_version"] == .number(1), reply["protocol"] == .string("arl/1"),
              reply["client_nonce"] == .string(nonce), let session = reply["session_id"]?.text,
              let challenge = reply["challenge"]?.text,
              session.count == 64, challenge.count == 64,
              case .array(let accepted)? = reply["accepted_capabilities"] else { throw ARLError(code:"invalid_response") }
        let tools = accepted.compactMap(\.text)
        guard tools.count == accepted.count, Set(tools).isSubset(of:Set(capabilities)) else { throw ARLError(code:"invalid_response") }
        let confirmed = try rpc("connection.confirm", params:["session_id":.string(session),"challenge":.string(challenge)])
        guard confirmed["schema_version"] == .number(1), confirmed["connected"] == .bool(true),
              confirmed["session_id"] == .string(session) else { throw ARLError(code:"invalid_response") }
        appSession = session
        return tools
    }
    public func pingAppSession() throws {
        guard let session = appSession else { throw ARLError(code:"app_session_changed") }
        let reply = try rpc("connection.ping", params:["session_id":.string(session)])
        guard reply["connected"] == .bool(true), reply["session_id"] == .string(session) else { throw ARLError(code:"invalid_response") }
    }
    public func closeAppSession() throws {
        guard let session = appSession else { return }
        let reply = try rpc("connection.close", params:["session_id":.string(session)])
        guard reply["connected"] == .bool(false), reply["session_id"] == .string(session) else { throw ARLError(code:"invalid_response") }
        appSession = nil
    }
    public func settingsMetadata(_ method: ARLSettingsMethod, params: [String: ARLJSON] = [:], timeout: TimeInterval = 5) throws -> ARLJSON {
        guard app == "settings" else { throw ARLError(code:"method_not_authorized") }
        if method == .logs || method == .logsExport {
            guard Set(params.keys).isSubset(of:["cursor","limit","level","event","since_ms","until_ms"]) else { throw ARLError(code:"invalid_arguments") }
        } else { guard params.isEmpty else { throw ARLError(code:"invalid_arguments") } }
        return try rpc(method.rawValue,params:params,timeout:timeout)
    }
    /// One monotonic deadline covers connect, write, read and response validation.
    public func rpc(_ method: String, params: [String: ARLJSON] = [:], timeout: TimeInterval = 5) throws -> ARLJSON {
        guard timeout.isFinite, timeout > 0, timeout <= 60 else { throw ARLError(code: "rpc_deadline_exceeded") }
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeout * 1_000_000_000)
        func remainingMilliseconds() throws -> Int32 {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { throw ARLError(code: "rpc_deadline_exceeded") }
            return Int32(min((deadline - now + 999_999) / 1_000_000, UInt64(Int32.max)))
        }
        let path = home.appendingPathComponent("runtime.sock").path
        guard path.utf8.count < 104 else { throw ARLError(code: "socket_path_too_long") }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ARLError(code: "disconnected") }
        defer { close(fd) }
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { throw ARLError(code: "disconnected") }
        var noSignal: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0 else { throw ARLError(code: "disconnected") }
        func waitFor(_ events: Int16) throws {
            while true {
                var item = pollfd(fd: fd, events: events, revents: 0)
                let result = poll(&item, 1, try remainingMilliseconds())
                if result < 0 && errno == EINTR { continue }
                guard result != 0 else { throw ARLError(code: "rpc_deadline_exceeded") }
                guard result > 0, item.revents & Int16(POLLNVAL) == 0 else { throw ARLError(code: "disconnected") }
                _ = try remainingMilliseconds()
                return
            }
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { target in
            path.utf8CString.withUnsafeBytes { source in target.copyBytes(from: source) }
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if connected != 0 {
            guard errno == EINPROGRESS || errno == EAGAIN || errno == EINTR else { throw ARLError(code: "disconnected") }
            try waitFor(Int16(POLLOUT))
            var socketError: Int32 = 0, length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0, socketError == 0 else { throw ARLError(code: "disconnected") }
        }
        var data = try JSONEncoder().encode(ARLJSON.object([
            "protocol": .string("arl/1"), "app": .string(app), "method": .string(method), "params": .object(params)]))
        data.append(10)
        guard data.count <= 16_384 else { throw ARLError(code: "invalid_frame") }
        try data.withUnsafeBytes { bytes in
            var sent = 0
            while sent < bytes.count {
                try waitFor(Int16(POLLOUT))
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: sent), bytes.count-sent)
                if count < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) { continue }
                guard count > 0 else { throw ARLError(code: "disconnected") }
                sent += count
            }
        }
        var response = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while !response.contains(10) {
            try waitFor(Int16(POLLIN))
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) { continue }
            guard count > 0 else { throw ARLError(code: "disconnected") }
            response.append(contentsOf: buffer.prefix(count))
            guard response.count <= 131_072 else { throw ARLError(code: "invalid_response") }
        }
        guard response.last == 10, response.filter({ $0 == 10 }).count == 1 else { throw ARLError(code: "invalid_response") }
        let reply = try JSONDecoder().decode(Reply.self, from: response)
        _ = try remainingMilliseconds()
        guard reply.protocol == "arl/1" else { throw ARLError(code: "unsupported_protocol") }
        guard reply.ok else { throw ARLError(code: reply.error?.code ?? "invalid_response") }
        guard let result = reply.result else { throw ARLError(code: "invalid_response") }
        return result
    }
    public func connect(timeout: TimeInterval = 10) async throws -> ARLJSON {
        guard timeout.isFinite, timeout > 0, timeout <= 60 else { throw ARLError(code: "ready_timeout") }
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeout * 1_000_000_000)
        var launched = false, delay: UInt64 = 20_000_000
        while DispatchTime.now().uptimeNanoseconds < deadline {
            guard !FileManager.default.fileExists(atPath: home.appendingPathComponent("disabled").path)
                else { throw ARLError(code: "user_disabled") }
            do {
                let now = DispatchTime.now().uptimeNanoseconds
                guard now < deadline else { break }
                let remaining = Double(deadline - now) / 1_000_000_000
                return try rpc("ready", timeout: min(5, remaining))
            }
            catch let error as ARLError {
                guard error.code == "not_ready" || error.code == "disconnected" || error.code == "rpc_deadline_exceeded" else { throw error }
                if error.code == "disconnected", !launched, let launcher {
                    try launcher(); launched = true
                }
            }
            let now = DispatchTime.now().uptimeNanoseconds
            if now >= deadline { break }
            try await Task.sleep(nanoseconds: min(delay, deadline - now))
            delay = min(delay*2, 300_000_000)
        }
        throw ARLError(code: "ready_timeout")
    }
    public func submit(tool: String, args: [String: ARLJSON], key: String) async throws -> ARLJSON {
        _ = try await connect()
        let params: [String: ARLJSON] = ["tool": .string(tool), "args": .object(args), "key": .string(key)]
        do { return try rpc("submit", params: params) }
        catch let error as ARLError where error.code == "disconnected" {
            _ = try await connect()
            return try rpc("submit", params: params)
        }
    }
}
