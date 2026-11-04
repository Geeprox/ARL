import Foundation

struct RegisteredModelScenario: Codable, Identifiable, Sendable {
    let id: String; let name: String; let task_kind: String; let priority: String; let package_id: String
    let deadline_ms: Int; let max_output_bytes: Int
    var priorityTitle: String { priority == "interactive" ? "交互":priority == "background" ? "后台":"用户任务" }
    var packageTitle: String { ["low":"低","medium":"中","high":"高","very_high":"很高","highest":"最高"][package_id] ?? package_id }
}

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
    var scenarios: [RegisteredModelScenario] = []
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
        case "model_task_queued": "模型任务已排队"
        case "diagnostic_history_reset": "历史记录损坏，已重新开始记录"
        case "model_task_succeeded": "模型任务已完成"
        case "model_task_failed": "模型任务未完成"
        default: "未知事件"
        }
    }
}
extension RedactedLogEntry {
    var explanation:String {
        switch code {
        case "identity_unverified":return "应用身份未通过核验，请重新打开来源应用后重试。"
        case "method_not_authorized":return "应用没有使用此功能的权限，请检查其接入配置。"
        case "unknown_app":return "请求来自未注册的应用，操作未执行。"
        case "unknown_method":return "应用请求了不受支持的功能，请更新应用。"
        case "invalid_request","invalid_arguments":return "请求格式不符合协议，操作未执行。"
        case "not_ready":return "后台尚未就绪，请等待自动恢复。"
        case "internal_error":return "后台处理请求时发生内部错误；这条旧记录没有保存具体原因。"
        case "provider_unavailable","probe_failed":return "服务连接未通过检查，请到服务连接查看当前状态。"
        default:break
        }
        switch event {
        case "runtime_starting":return "ARL 正在启动后台服务。"
        case "runtime_ready":return "后台已就绪，可以接收应用任务。"
        case "runtime_stopping":return "后台正在结束任务并关闭连接。"
        case "app_verified":return "应用已通过身份核验，可以使用获准的服务。"
        case "app_revoked":return "应用连接已结束；已撤回该会话的服务使用权限。"
        case "model_task_queued":return "模型任务已加入统一队列，等待执行。"
        case "model_task_succeeded":return "模型任务已完成。"
        case "model_task_failed":return "模型任务未成功完成，请查看下方原因与任务信息。"
        case "provider_check":return "ARL 更新了服务可用状态。"
        case "rpc_rejected":return "请求未通过检查，ARL 没有执行此操作。"
        case "diagnostic_history_reset":return "此前日志文件无法读取，ARL 已重新开始记录。"
        default:return "这条记录没有更多说明。"
        }
    }
}

struct LogTaskContext:Decodable,Sendable {
    let task_id:String?
    let package_id:String?
    let model:String?
    let reasoning_effort:String?
    let method:String?
    let reason:String?
    let duration_ms:Int?
    var isEmpty:Bool {task_id == nil && package_id == nil && model == nil && reasoning_effort == nil && method == nil && reason == nil && duration_ms == nil}
    var packageTitle:String? {package_id.flatMap{["low":"低","medium":"中","high":"高","very_high":"很高","highest":"最高"][$0]}}
    var reasonTitle:String? {
        guard let reason else{return nil}
        switch reason {
        case "provider_controls_unverified":return "模型服务未确认执行参数，任务已停止。"
        case "provider_deadline_exceeded","provider_timeout","deadline_exceeded":return "模型响应超时。"
        case "model_unavailable","unsupported_model","unsupported_reasoning_effort":return "所选模型或思考强度当前不可用。"
        case "call_budget_exceeded":return "已达到本地调用上限。"
        case "cancelled":return "任务已取消。"
        case "scope_expired","app_session_expired","app_connection_required":return "应用连接已过期，请重新打开来源应用。"
        case "input_too_large","result_too_large":return "任务内容超过允许的大小。"
        case "identity_unverified":return "应用身份未通过核验。"
        case "method_not_authorized":return "应用没有使用此功能的权限。"
        case "provider_unavailable","provider_preflight_failed":return "模型服务暂时不可用，请稍后重试。"
        default:return "任务未完成，请结合事件和状态代码排查。"
        }
    }
    static func decode(_ data:Data,sequence:Int,session:String)throws->Self? {
        let r=try WireSchema.object(JSONSerialization.jsonObject(with:data),["schema_version","sequence","session_id","available","context"])
        try WireSchema.constantInt(r["schema_version"],1)
        guard try WireSchema.integer(r["sequence"]) == sequence,r["session_id"] as? String == session,
              let values=r["context"] as? [String:Any],Set(values.keys).isSubset(of:["task_id","package_id","model","reasoning_effort","method","reason","duration_ms"]) else {throw ARLError(code:"invalid_response")}
        for (key,value) in values {
            if key == "duration_ms" {let n=try WireSchema.integer(value);guard (0...3600000).contains(n) else {throw ARLError(code:"invalid_response")}}
            else {
                let text=try WireSchema.string(value,maximum:80)
                guard text.range(of:"^[a-zA-Z0-9_.-]+$",options:.regularExpression) != nil else{throw ARLError(code:"invalid_response")}
                if key == "task_id", UUID(uuidString:text)?.uuidString.lowercased() != text {throw ARLError(code:"invalid_response")}
                if key == "package_id", !["low","medium","high","very_high","highest"].contains(text) {throw ARLError(code:"invalid_response")}
                if key == "reasoning_effort", !["none","minimal","low","medium","high","xhigh","max","ultra"].contains(text) {throw ARLError(code:"invalid_response")}
                if key == "model", text.range(of:"^(gpt|o[1-9])[a-z0-9._-]{0,60}$",options:.regularExpression) == nil {throw ARLError(code:"invalid_response")}
            }
        }
        guard try WireSchema.boolean(r["available"]) else{return nil}
        return try JSONDecoder().decode(Self.self,from:JSONSerialization.data(withJSONObject:values))
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

struct RecentLogPage:Sendable {
    let sessionID:String
    let entries:[RedactedLogEntry]
    let total:Int
    let truncated:Bool
    static func decode(_ data:Data)throws->Self {
        let r=try WireSchema.object(JSONSerialization.jsonObject(with:data),["schema_version","session_id","records","limit","total","truncated"])
        try WireSchema.constantInt(r["schema_version"],1)
        let session=try WireSchema.string(r["session_id"],maximum:32)
        guard session.range(of:"^[a-f0-9]{32}$",options:.regularExpression) != nil else{throw ARLError(code:"invalid_response")}
        let limit=try WireSchema.integer(r["limit"]);guard (1...500).contains(limit) else{throw ARLError(code:"invalid_response")}
        try WireSchema.records(r["records"],maximum:limit)
        let entries=try JSONDecoder().decode([RedactedLogEntry].self,from:JSONSerialization.data(withJSONObject:r["records"]!))
        let total=try WireSchema.integer(r["total"]),truncated=try WireSchema.boolean(r["truncated"])
        guard total >= entries.count,total <= 1024,truncated == (total > entries.count) else{throw ARLError(code:"invalid_response")}
        return .init(sessionID:session,entries:entries,total:total,truncated:truncated)
    }
}
