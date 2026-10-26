import Foundation

/// Presentation contracts. Wire decoding is added only for a confirmed service schema.
enum MetadataFeature<Value: Sendable>: Sendable {
    case available(Value)
    case unsupported
    case unavailable(String)
    var value: Value? { if case .available(let value) = self { return value }; return nil }
    var explanation: String {
        switch self {
        case .available: "已读取"
        case .unsupported: "后台服务未提供此状态"
        case .unavailable: "状态暂不可读"
        }
    }
}

/// Shared retirement survives value copies and wall-clock adjustments.
final class AppConnectionLease: @unchecked Sendable {
    private let lock = NSLock()
    private let received: TimeInterval
    private let expires: TimeInterval
    private var retired = false
    init(remainingMilliseconds: Int, uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        received = uptime; expires = uptime + Double(max(0,remainingMilliseconds))/1000
    }
    func live(at uptime: TimeInterval) -> Bool {
        lock.withLock {
            if uptime < received || uptime >= expires { retired = true }
            return !retired
        }
    }
}

struct AppRegistration: Identifiable, Sendable {
    let id: String
    let name: String
    let symbol: String
    let connection: String
    let authorization: String
    var registration: String = "仅登记范围"
    var authentication: String = "身份尚未核验"
    var version: String? = nil
    var observedAt: Date? = nil
    var advertised: [String] = []
    var authorizedTools: [String] = []
    var hasConnectedEvidence: Bool = false
    var handshakeSession: String? = nil
    var staleAfterMilliseconds: Int = 30000
    var hasVerifiedRegistration: Bool = false
    var verifiedAt: Date? = nil
    var lease: AppConnectionLease? = nil
    var applicationIcon: RegisteredApplicationIcon? = nil
    var applicationIconHome: URL? = nil
    func isStale(at now: Date) -> Bool { hasConnectedEvidence && observedAt.map { now.timeIntervalSince($0) * 1000 > Double(staleAfterMilliseconds) } == true }
    func isConnected(at now: Date, uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard handshakeSession != nil, hasConnectedEvidence, hasVerifiedRegistration, staleAfterMilliseconds > 0,
              observedAt != nil, verifiedAt != nil, let lease else { return false }
        return lease.live(at: uptime)
    }
    static func connected(_ entries: [Self], at now: Date, uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) -> [Self] {
        entries.filter { $0.isConnected(at: now, uptime: uptime) }
    }
}
enum AppIdentity {
    static func presentation(_ app: String) -> (name: String, symbol: String) {
        (app, "app")
    }
}

struct SystemLoad: Sendable {
    let sampledAt: Date
    let cpuPercent: Double?
    let memoryTotalBytes: UInt64?
    let pressure: String
    let swapUsedBytes: UInt64?
    let processes: [ControlProcess]
    let sourceDescription: String
}

struct RedactedLogEntry: Identifiable, Codable, Sendable {
    let sequence: Int
    let at_ms: Int
    let level: String
    let event: String
    let code: String?
    let app_id: String?
    // Local selection identity. Never encoded as a diagnostic wire field.
    var presentationID: Int? = nil
    private enum CodingKeys: String, CodingKey { case sequence, at_ms, level, event, code, app_id }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy:CodingKeys.self)
        try c.encode(sequence,forKey:.sequence); try c.encode(at_ms,forKey:.at_ms)
        try c.encode(level,forKey:.level); try c.encode(event,forKey:.event)
        if let code { try c.encode(code,forKey:.code) } else { try c.encodeNil(forKey:.code) }
        if let app_id { try c.encode(app_id,forKey:.app_id) } else { try c.encodeNil(forKey:.app_id) }
    }
    var id: Int { presentationID ?? sequence }
    var searchableText: String { [event, code, app_id, level].compactMap { $0 }.joined(separator: " ") }
    var eventTitle: String {
        switch event {
        case "runtime_starting": "正在启动"
        case "runtime_ready": "后台已启动"
        case "runtime_stopping": "正在停止"
        case "app_verified": "应用身份已核验"
        case "app_revoked": "应用身份已撤销"
        case "provider_check": "服务检查"
        case "rpc_rejected": "调用已拒绝"
        default: "未知事件"
        }
    }
}
struct RedactedLogPage: Sendable {
    let entries: [RedactedLogEntry]
    let hasMore: Bool
    let nextCursor: String?
    let truncated: Bool
    let sourceDescription: String
}

struct HouseholdStatus: Sendable {
    let owner: String
    let connection: String
    let authorization: String
    let adapter: String
}

struct ControlPlaneState: Sendable {
    var registry: MetadataFeature<[AppRegistration]> = .unsupported
    var metrics: MetadataFeature<SystemLoad> = .unsupported
    var logs: MetadataFeature<RedactedLogPage> = .unsupported
    var household: MetadataFeature<HouseholdStatus> = .unsupported
    var providerHealth: MetadataFeature<[ControlProvider]> = .unsupported
    var credentials: MetadataFeature<[ControlCredential]> = .unsupported
    var runtime: MetadataFeature<ControlRuntime> = .unsupported
    var appleApps: MetadataFeature<[ControlAppleApp]> = .unsupported
    static let unavailable = Self(registry: .unavailable("disconnected"), metrics: .unavailable("disconnected"),
                                  logs: .unavailable("disconnected"),
                                  household: .unavailable("disconnected"), providerHealth: .unavailable("disconnected"),
                                  credentials: .unavailable("disconnected"), runtime: .unavailable("disconnected"), appleApps: .unavailable("disconnected"))
}
