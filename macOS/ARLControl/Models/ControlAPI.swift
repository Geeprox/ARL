import Foundation
import CoreFoundation

struct ControlRuntime: Codable, Sendable {
    let state: String; let started_at_ms: Int?; let uptime_seconds: Double?
    let ui_required: Bool; let task_execution_enabled: Bool
}
struct RegisteredApplicationIcon: Codable, Hashable, Sendable {
    let app_id: String
    let sha256: String
    let mime_type: String
    let width: Int
    let height: Int
    let bytes: Int
    static func validate(_ value: Any?, appID: String) throws {
        let row = try WireSchema.object(value, ["app_id","sha256","mime_type","width","height","bytes"])
        let hash = try WireSchema.string(row["sha256"], maximum:64)
        guard row["app_id"] as? String == appID, row["mime_type"] as? String == "image/png",
              hash.utf8.count == 64, hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              try WireSchema.integer(row["width"]) == 64, try WireSchema.integer(row["height"]) == 64,
              (1...8192).contains(try WireSchema.integer(row["bytes"])) else { throw ARLError(code:"invalid_response") }
    }
}
struct ControlApp: Codable, Sendable {
    let id: String; let name: String; let icon_ref: String; let version: String?
    let registration: String; let connection: String; let authentication: String; let authorization: String
    let last_verified_at_ms: Int?; let last_seen_at_ms: Int?; let stale_after_ms: Int
    let advertised_capabilities: [String]; let authorized_tools: [String]
    var handshake_session: String? = nil
    var session_remaining_ms: Int? = nil
    var application_icon: RegisteredApplicationIcon? = nil
    var presentation: AppRegistration { presented(atUptime: ProcessInfo.processInfo.systemUptime) }
    func presented(atUptime: TimeInterval, iconHome: URL? = nil) -> AppRegistration {
        let symbol = icon_ref.hasPrefix("sf:") ? String(icon_ref.dropFirst(3)) : "app"
        return AppRegistration(id: id, name: name, symbol: symbol,
            connection: Self.connectionTitle(connection), authorization: authorization == "limited" ? "限定授权" : "未授权",
            registration: registrationTitle,
            authentication: authentication == "verified" ? "已核验" : authentication == "stale" ? "待重验" : "待核验",
            version: version, observedAt: last_seen_at_ms.map { Date(timeIntervalSince1970: Double($0) / 1000) },
            advertised: advertised_capabilities, authorizedTools: authorized_tools,
            hasConnectedEvidence: connection == "connected", handshakeSession: handshake_session, staleAfterMilliseconds: stale_after_ms,
            hasVerifiedRegistration: registration == "registered" && authentication == "verified",
            verifiedAt: last_verified_at_ms.map { Date(timeIntervalSince1970: Double($0) / 1000) },
            lease: session_remaining_ms.map { AppConnectionLease(remainingMilliseconds: $0, uptime: atUptime) },
            applicationIcon: application_icon, applicationIconHome: iconHome)
    }
    private static func connectionTitle(_ state: String) -> String {
        switch state { case "connected": "已连接"; case "stale": "状态过期";
        case "disconnected": "已断开"; default: "暂无记录" }
    }
    var registrationTitle: String { registration == "registered" ? "已登记" : registration == "revoked" ? "已撤销" : "未登记" }
}
struct ControlProvider: Codable, Identifiable, Sendable {
    let id: String; let state: String; let checked_at_ms: Int?; let stale_after_ms: Int
    let evidence: String; let catalog_models: [String]; let model_load_state: String; let inference_enabled: Bool
    var title: String { switch id { case "ollama": "Ollama";
        case "codex_app_server": "Codex"; case "jev": "Jev"; case "mock": "测试模型"; default: id } }
    var stateTitle: String { switch state { case "discovered": "已发现"; case "starting": "准备中";
        case "ready": "检查通过"; case "degraded": "部分可用"; case "unavailable": "不可用";
        case "disabled": "已停用"; default: "未知" } }
    var evidenceTitle: String { switch evidence { case "local_http": "本机检查"; case "test_double": "模拟检查";
        case "host_observation": "后台核验"; default: "暂无记录" } }
    func isStale(at now: Date) -> Bool {
        guard let checked_at_ms else { return false }
        return now.timeIntervalSince1970 * 1000 - Double(checked_at_ms) > Double(stale_after_ms)
    }
}
struct ControlProcess: Codable, Identifiable, Sendable {
    let id: String; let app_ids: [String]; let rss_bytes: UInt64?; let cpu_percent: Double?; let state: String
    var stateTitle: String { state == "available" ? "已采样" : state == "warming_up" ? "等待采样" : "无法采样" }
}
struct ControlResources: Codable, Sendable {
    let state: String; let sampled_at_ms: Int?; let minimum_interval_ms: Int
    let cpu_logical_count: Int?; let system_cpu_percent: Double?; let memory_total_bytes: UInt64?
    let memory_pressure: String; let swap_used_bytes: UInt64?; let processes: [ControlProcess]
    let attribution: String; let gpu_allocation: String
    var presentation: SystemLoad? {
        guard let sampled_at_ms, state == "available" || state == "partial" else { return nil }
        let pressure = switch memory_pressure { case "normal": "正常"; case "warning": "警告"; case "critical": "严重"; default: "未知" }
        return SystemLoad(sampledAt: Date(timeIntervalSince1970: Double(sampled_at_ms)/1000), cpuPercent: system_cpu_percent,
                          memoryTotalBytes: memory_total_bytes, pressure: pressure, swapUsedBytes: swap_used_bytes,
                          processes: processes, sourceDescription: state == "partial" ? "部分指标可用 · 至少 5 秒采样间隔" : "系统负载与受控进程采样 · 至少 5 秒间隔")
    }
}
struct ControlDiagnostics: Codable, Sendable {
    let redaction_version: Int; let retention: String; let max_records: Int; let max_age_ms: Int
}
struct ControlCredential: Codable, Identifiable, Sendable {
    let id: String; let service: String; let purpose: String; let state: String; let reference_id: String?
    let reference_status: String; let provider_revocation: String
    var stateTitle: String { switch state { case "not_configured": "未配置"; case "fixture": "测试记录";
        case "reference_only": "仅存记录"; case "removed": "本机移除"; default: "未知" } }
}
struct ControlAppleAction: Codable, Identifiable, Sendable {
    let id: String; let state: String; let implementation: String; let permission: String; let lock: String
    let authorized: Bool; let checked_at_ms: Int?
    var title: String {
        switch id.split(separator:".").last {
        case "list": "读取列表"; case "read": "读取"; case "create": "创建"; case "write": "写入";
        case "update": "更新"; case "remove": "删除"; case "complete": "标记完成"; case "append": "追加";
        case "edit": "编辑"; case "history": "读取历史"; case "send": "发送"; case "watch": "监听"; default: id }
    }
    var stateTitle: String { switch state { case "not_implemented": "未接入"; case "needs_permission": "需要权限";
        case "locked": "已锁定"; case "ready": "可操作"; case "unavailable": "不可用"; default: "未知" } }
    var permissionTitle: String { switch permission { case "authorized": "已授权"; case "denied": "未授权";
        case "restricted": "系统限制"; case "not_determined": "未申请";
        case "not_applicable": "无需授权"; default: "待检查" } }
}
struct ControlAppleApp: Codable, Identifiable, Sendable {
    let id: String; let name: String; let icon_ref: String; let actions: [ControlAppleAction]
    var symbol: String { icon_ref.hasPrefix("sf:") ? String(icon_ref.dropFirst(3)) : "app" }
    var title: String { switch id { case "calendar": "日历"; case "reminders": "提醒事项"; case "notes": "备忘录"; case "imessage", "messages": "信息"; default: name } }
}
struct ControlHousehold: Codable, Sendable {
    let owner_app: String?; let state: String; let read_capabilities: [String]; let actuation_capabilities: [String]
}
struct ControlPlaneSnapshot: Codable, Sendable {
    let schema_version: Int; let `protocol`: String; let version: String; let checked_at_ms: Int
    let runtime: ControlRuntime; let apps: [ControlApp]; let providers: [ControlProvider]; let resources: ControlResources
    let diagnostics: ControlDiagnostics; let credentials: [ControlCredential]; let apple_apps: [ControlAppleApp]; let household: ControlHousehold

    static func decode(_ data: Data) throws -> Self {
        let r = try WireSchema.object(JSONSerialization.jsonObject(with: data), ["schema_version","protocol","version","checked_at_ms","runtime","apps","providers","resources","diagnostics","credentials","apple_apps","household"])
        try WireSchema.constantInt(r["schema_version"], 2); try WireSchema.choice(r["protocol"], ["arl/1"])
        _ = try WireSchema.string(r["version"],maximum:80); _ = try WireSchema.integer(r["checked_at_ms"])
        let runtime = try WireSchema.object(r["runtime"], ["state","started_at_ms","uptime_seconds","ui_required","task_execution_enabled"])
        try WireSchema.choice(runtime["state"], ["starting","ready","stopping","stopped","error","unknown"])
        try WireSchema.nullableInteger(runtime["started_at_ms"]); try WireSchema.nullableNumber(runtime["uptime_seconds"])
        guard try !WireSchema.boolean(runtime["ui_required"]) else { throw ARLError(code: "invalid_response") }
        _ = try WireSchema.boolean(runtime["task_execution_enabled"])
        let apps = try WireSchema.array(r["apps"])
        for value in apps {
            let base: Set<String> = ["id","name","icon_ref","version","registration","connection","authentication","authorization","last_verified_at_ms","last_seen_at_ms","stale_after_ms","advertised_capabilities","authorized_tools"]
            let optional: Set<String> = ["handshake_session", "session_remaining_ms", "application_icon"]
            let keys = base.union(Set((value as? [String:Any])?.keys.map { $0 } ?? []).intersection(optional))
            let a = try WireSchema.object(value, keys)
            if let session = a["handshake_session"], !(session is NSNull) {
                let text = try WireSchema.string(session, maximum:64)
                guard text.count == 64, text.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { throw ARLError(code:"invalid_response") }
            }
            if let remaining = a["session_remaining_ms"], !(remaining is NSNull) {
                let n = try WireSchema.integer(remaining)
                guard n >= 0, n <= 30000 else { throw ARLError(code:"invalid_response") }
            }
            if let icon = a["application_icon"], !(icon is NSNull) {
                guard let appID = a["id"] as? String, a["handshake_session"] is String else { throw ARLError(code:"invalid_response") }
                try RegisteredApplicationIcon.validate(icon, appID:appID)
            }
            try WireSchema.identifier(a["id"]); _ = try WireSchema.string(a["name"])
            try WireSchema.icon(a["icon_ref"]); try WireSchema.nullableString(a["version"],maximum:80)
            try WireSchema.choice(a["registration"], ["unregistered","registered","revoked"])
            try WireSchema.choice(a["connection"], ["never_seen","connected","stale","disconnected"])
            try WireSchema.choice(a["authentication"], ["unverified","verified","stale"])
            try WireSchema.choice(a["authorization"], ["none","limited"])
            for key in ["last_verified_at_ms","last_seen_at_ms"] { try WireSchema.nullableInteger(a[key]) }
            _ = try WireSchema.integer(a["stale_after_ms"])
            for key in ["advertised_capabilities","authorized_tools"] { try WireSchema.identifiers(a[key],maximum:80) }
            // A connected/authenticated display needs actual verified traffic evidence.
            if a["connection"] as? String == "connected" {
                guard a["registration"] as? String == "registered", a["authentication"] as? String == "verified",
                      !(a["last_seen_at_ms"] is NSNull), !(a["last_verified_at_ms"] is NSNull) else { throw ARLError(code: "invalid_response") }
            }
        }
        try WireSchema.uniqueIDs(apps)
        let providers = try WireSchema.array(r["providers"])
        for value in providers {
            let p = try WireSchema.object(value, ["id","state","checked_at_ms","stale_after_ms","evidence","catalog_models","model_load_state","inference_enabled"])
            try WireSchema.identifier(p["id"])
            try WireSchema.choice(p["state"], ["discovered","starting","ready","degraded","unavailable","disabled","unknown"])
            try WireSchema.nullableInteger(p["checked_at_ms"]); _ = try WireSchema.integer(p["stale_after_ms"])
            try WireSchema.choice(p["evidence"], ["none","local_http","test_double","host_observation"])
            try WireSchema.strings(p["catalog_models"])
            try WireSchema.choice(p["model_load_state"], ["unknown","not_applicable"])
            _ = try WireSchema.boolean(p["inference_enabled"])
        }
        try WireSchema.uniqueIDs(providers)
        let res = try WireSchema.object(r["resources"], ["state","sampled_at_ms","minimum_interval_ms","cpu_logical_count","system_cpu_percent","memory_total_bytes","memory_pressure","swap_used_bytes","processes","attribution","gpu_allocation"])
        try WireSchema.choice(res["state"], ["available","partial","unavailable","unknown"])
        try WireSchema.nullableInteger(res["sampled_at_ms"])
        guard try WireSchema.integer(res["minimum_interval_ms"]) >= 5000 else { throw ARLError(code: "invalid_response") }
        for key in ["cpu_logical_count","memory_total_bytes","swap_used_bytes"] { try WireSchema.nullableInteger(res[key]) }
        try WireSchema.nullableNumber(res["system_cpu_percent"], maximum: 100)
        try WireSchema.choice(res["memory_pressure"], ["normal","warning","critical","unknown"])
        try WireSchema.choice(res["attribution"], ["controlled_process_set_shared_counted_once"])
        try WireSchema.choice(res["gpu_allocation"], ["unavailable"])
        let processes = try WireSchema.array(res["processes"],maximum:32)
        for value in processes {
            let p = try WireSchema.object(value, ["id","app_ids","rss_bytes","cpu_percent","state"])
            try WireSchema.identifier(p["id"]); try WireSchema.identifiers(p["app_ids"])
            try WireSchema.nullableInteger(p["rss_bytes"]); try WireSchema.nullableNumber(p["cpu_percent"])
            try WireSchema.choice(p["state"], ["available","warming_up","unavailable"])
        }
        try WireSchema.uniqueIDs(processes)
        let d = try WireSchema.object(r["diagnostics"], ["redaction_version","retention","max_records","max_age_ms"])
        try WireSchema.constantInt(d["redaction_version"], 1); try WireSchema.choice(d["retention"], ["current_process"])
        try WireSchema.constantInt(d["max_records"], 1024); try WireSchema.constantInt(d["max_age_ms"], 86400000)
        let credentials = try WireSchema.array(r["credentials"])
        for value in credentials {
            let c = try WireSchema.object(value, ["id","service","purpose","state","reference_id","reference_status","provider_revocation"])
            try WireSchema.identifier(c["id"]); for key in ["service","purpose"] { _ = try WireSchema.string(c[key]) }
            try WireSchema.choice(c["state"], ["not_configured","fixture","reference_only","removed","unknown"])
            try WireSchema.nullableString(c["reference_id"])
            try WireSchema.choice(c["reference_status"], ["unresolved","fixture","unknown"])
            try WireSchema.choice(c["provider_revocation"], ["not_performed"])
        }
        try WireSchema.uniqueIDs(credentials)
        let apples = try WireSchema.array(r["apple_apps"])
        for value in apples {
            let a = try WireSchema.object(value, ["id","name","icon_ref","actions"])
            try WireSchema.identifier(a["id"]); _ = try WireSchema.string(a["name"]); try WireSchema.icon(a["icon_ref"])
            let actions = try WireSchema.array(a["actions"])
            for value in actions {
                let act = try WireSchema.object(value, ["id","state","implementation","permission","lock","authorized","checked_at_ms"])
                try WireSchema.identifier(act["id"],maximum:80)
                try WireSchema.choice(act["state"], ["not_implemented","needs_permission","locked","ready","unavailable","unknown"])
                try WireSchema.choice(act["implementation"], ["absent","adapter"])
                try WireSchema.choice(act["permission"], ["not_checked","not_determined","denied","restricted","authorized","not_applicable"])
                try WireSchema.choice(act["lock"], ["unknown","unlocked","locked","not_applicable"])
                _ = try WireSchema.boolean(act["authorized"]); try WireSchema.nullableInteger(act["checked_at_ms"])
            }
            try WireSchema.uniqueIDs(actions)
        }
        try WireSchema.uniqueIDs(apples)
        let house = try WireSchema.object(r["household"], ["owner_app","state","read_capabilities","actuation_capabilities"])
        try WireSchema.nullableString(house["owner_app"], maximum:64)
        try WireSchema.choice(house["state"], ["not_registered","unverified","stale","available","unavailable"])
        try WireSchema.identifiers(house["read_capabilities"],maximum:80); try WireSchema.identifiers(house["actuation_capabilities"],maximum:80)
        return try JSONDecoder().decode(Self.self, from: data)
    }
    var presentation: ControlPlaneState { presented(atUptime: ProcessInfo.processInfo.systemUptime) }
    func presented(atUptime: TimeInterval, iconHome: URL? = nil) -> ControlPlaneState {
        var state = ControlPlaneState()
        state.registry = .available(apps.map { $0.presented(atUptime: atUptime, iconHome: iconHome) })
        state.metrics = resources.presentation.map { .available($0) } ?? .unavailable(resources.state)
        state.household = .available(HouseholdStatus(owner: apps.first { $0.id == household.owner_app }?.name ?? "未连接", connection: household.stateTitle,
            authorization: household.actuation_capabilities.isEmpty ? "未声明执行能力" : "声明不代表已授权执行",
            adapter: household.read_capabilities.isEmpty ? "未声明读取能力" : household.read_capabilities.joined(separator: "、")))
        state.providerHealth = .available(providers); state.credentials = .available(credentials); state.runtime = .available(runtime)
        state.appleApps = .available(apple_apps)
        return state
    }
}
extension ControlHousehold {
    var stateTitle: String { switch state { case "available": "家庭状态已读取"; case "unverified": "身份待核";
        case "stale": "状态过期"; case "unavailable": "家庭连接不可用"; default: "尚未连接" } }
}

struct ControlLogResponse: Codable, Sendable {
    let schema_version: Int; let redaction_version: Int; let records: [RedactedLogEntry]
    let next_cursor: String?; let more: Bool; let truncated: Bool
    static func decode(_ data: Data) throws -> Self {
        let raw = try WireSchema.object(JSONSerialization.jsonObject(with: data), ["schema_version","redaction_version","records","next_cursor","more","truncated"])
        try WireSchema.constantInt(raw["schema_version"],2); try WireSchema.constantInt(raw["redaction_version"],1)
        try WireSchema.records(raw["records"], maximum: 100); try WireSchema.nullableString(raw["next_cursor"], maximum:64)
        _ = try WireSchema.boolean(raw["more"]); _ = try WireSchema.boolean(raw["truncated"])
        return try JSONDecoder().decode(Self.self, from:data)
    }
    var presentation: RedactedLogPage { .init(entries: records, hasMore: more, nextCursor: next_cursor, truncated: truncated, sourceDescription: "当前进程 · 最近 15 分钟 · 服务端脱敏") }
}

enum WireSchema {
    static let events: Set<String> = ["runtime_starting","runtime_ready","runtime_stopping","app_verified","app_revoked","provider_check","rpc_rejected"]
    static let codes: Set<String> = ["identity_unverified","method_not_authorized","unknown_app","unknown_method","invalid_request","invalid_arguments","not_ready","internal_error","provider_unavailable","probe_failed"]
    static func object(_ value: Any?, _ keys: Set<String>) throws -> [String:Any] {
        guard let v=value as? [String:Any], Set(v.keys)==keys else { throw ARLError(code:"invalid_response") }; return v
    }
    static func string(_ value: Any?, maximum: Int = 200) throws -> String {
        guard let v=value as? String, !v.isEmpty, v.unicodeScalars.count <= maximum,
              v.unicodeScalars.allSatisfy({$0.value >= 32}) else { throw ARLError(code:"invalid_response") }; return v
    }
    static func nullableString(_ value: Any?, maximum:Int=200) throws { if value is NSNull { return }; _ = try string(value,maximum:maximum) }
    static func boolean(_ value:Any?) throws -> Bool {
        guard let v=value as? NSNumber, CFGetTypeID(v)==CFBooleanGetTypeID() else { throw ARLError(code:"invalid_response") }; return v.boolValue
    }
    static func integer(_ value:Any?) throws -> Int {
        guard let v=value as? NSNumber, CFGetTypeID(v) != CFBooleanGetTypeID(), let n=Int(v.stringValue), n>=0 else { throw ARLError(code:"invalid_response") }; return n
    }
    static func nullableInteger(_ value:Any?) throws { if value is NSNull { return }; _ = try integer(value) }
    static func nullableNumber(_ value:Any?, maximum:Double?=nil) throws {
        if value is NSNull { return }
        guard let v=value as? NSNumber, CFGetTypeID(v) != CFBooleanGetTypeID(), v.doubleValue.isFinite,
              v.doubleValue>=0, maximum.map({v.doubleValue <= $0}) ?? true else { throw ARLError(code:"invalid_response") }
    }
    static func constantInt(_ value:Any?, _ expected:Int) throws { guard try integer(value)==expected else { throw ARLError(code:"unsupported_protocol") } }
    static func choice(_ value:Any?, _ allowed:Set<String>) throws { guard allowed.contains(try string(value)) else { throw ARLError(code:"invalid_response") } }
    static func array(_ value:Any?, maximum:Int=100) throws -> [Any] {
        guard let v=value as? [Any], v.count<=maximum else { throw ARLError(code:"invalid_response") }; return v
    }
    static func strings(_ value:Any?) throws { for v in try array(value) { _ = try string(v) } }
    static func identifier(_ value:Any?, maximum:Int=64) throws {
        let v = try string(value,maximum:maximum)
        guard v.range(of:"^[A-Za-z0-9_.-]+$",options:.regularExpression) != nil else { throw ARLError(code:"invalid_response") }
    }
    static func identifiers(_ value:Any?, maximum:Int=64) throws { for v in try array(value) { try identifier(v,maximum:maximum) } }
    static func icon(_ value:Any?) throws {
        let v = try string(value,maximum:80)
        guard v.range(of:"^sf:[a-z0-9.]+$",options:.regularExpression) != nil else { throw ARLError(code:"invalid_response") }
    }
    static func uniqueIDs(_ values:[Any]) throws {
        let ids=try values.map { value -> String in guard let object=value as? [String:Any] else { throw ARLError(code:"invalid_response") }; return try string(object["id"]) }
        guard Set(ids).count==ids.count else { throw ARLError(code:"invalid_response") }
    }
    static func records(_ value:Any?, maximum:Int) throws {
        var last:Int? = nil
        for value in try array(value,maximum:maximum) {
            let record=try object(value,["sequence","at_ms","level","event","code","app_id"])
            let sequence=try integer(record["sequence"])
            if let last, sequence<=last { throw ARLError(code:"invalid_response") }; last=sequence
            _ = try integer(record["at_ms"]); try choice(record["level"],["info","warning","error"])
            try choice(record["event"],events)
            if !(record["code"] is NSNull) { try choice(record["code"],codes) }
            if !(record["app_id"] is NSNull) { try identifier(record["app_id"]) }
        }
    }
}


// Native consumer seam for the existing ARL owner. The controller retains the
// operation UUID across reconnects; this actor never launches or authorizes a host.
struct CodexServiceStatus: Decodable, Sendable {
    let schema_version: Int
    let state: String
    let reason: String?
    let scope_generation: String?
    let caller: String?
    let model: String?
    let route_enabled: Bool?
    let reasoning_effort: String?
    let service_tier: String?
    let execution_preferences_verified: Bool?
    let execution_catalog: CodexExecutionCatalog?
    let checked_at_ms: Int?
    let stale_after_ms: Int?
    let last_error_code: String?
    let last_inference_at_ms: Int?
    let inference_verified: Bool?
    let max_pending: Int?
    let remaining_calls: Int?
    let max_calls: Int?
    let max_input_bytes: Int?
    let max_output_bytes: Int?
    let max_wall_ms: Int?
    let token_hard_cap_supported: Bool?
    let cost_hard_cap_supported: Bool?
    let simulated: Bool?

    static func decode(_ value: ARLJSON) throws -> Self {
        let data = try JSONEncoder().encode(value)
        let raw = try JSONSerialization.jsonObject(with: data)
        let base: Set<String> = ["schema_version", "state"]
        let configured: Set<String> = ["caller", "model", "route_enabled", "reasoning_effort", "service_tier", "execution_preferences_verified", "scope_generation", "checked_at_ms",
            "stale_after_ms", "last_error_code", "last_inference_at_ms", "inference_verified",
            "max_pending", "remaining_calls", "max_calls", "max_input_bytes", "max_output_bytes", "max_wall_ms",
            "token_hard_cap_supported", "cost_hard_cap_supported", "simulated"]
        let dictionary = raw as? [String: Any]
        let absent = dictionary?["state"] as? String == "not_configured"
        let absentKeys = dictionary?["reason"] == nil ? base : base.union(["reason"])
        let expected = absent ? absentKeys : base.union(configured).union(dictionary?["execution_catalog"] == nil ? [] : ["execution_catalog"])
        let row = try WireSchema.object(raw, expected)
        if absent, row["reason"] != nil { _ = try WireSchema.string(row["reason"], maximum:80) }
        try WireSchema.constantInt(row["schema_version"], 1)
        try WireSchema.choice(row["state"], ["not_configured", "ready", "unavailable", "preflight_pending", "budget_exhausted"])
        if !absent {
            try WireSchema.identifier(row["caller"])
            guard UUID(uuidString: try WireSchema.string(row["scope_generation"], maximum:36)) != nil else { throw ARLError(code:"invalid_response") }
            _ = try WireSchema.string(row["model"], maximum: 150)
            try WireSchema.choice(row["reasoning_effort"], ["xhigh"])
            try WireSchema.choice(row["service_tier"], ["default"])
            for key in ["route_enabled", "execution_preferences_verified", "inference_verified", "simulated"] { _ = try WireSchema.boolean(row[key]) }
            for key in ["checked_at_ms", "last_inference_at_ms"] { try WireSchema.nullableInteger(row[key]) }
            try WireSchema.nullableString(row["last_error_code"], maximum: 80)
            try WireSchema.constantInt(row["stale_after_ms"], 90000)
            try WireSchema.constantInt(row["max_pending"], 1)
            try WireSchema.constantInt(row["max_input_bytes"], 8192)
            try WireSchema.constantInt(row["max_wall_ms"], 30000)
            let unlimited = row["max_calls"] is NSNull && row["remaining_calls"] is NSNull
            let calls = unlimited ? 1 : try WireSchema.integer(row["max_calls"])
            let output = try WireSchema.integer(row["max_output_bytes"])
            let remaining = unlimited ? 0 : try WireSchema.integer(row["remaining_calls"])
            guard (1...1000).contains(calls), (0...calls).contains(remaining), (128...32768).contains(output),
                  try !WireSchema.boolean(row["token_hard_cap_supported"]),
                  try !WireSchema.boolean(row["cost_hard_cap_supported"]) else { throw ARLError(code: "invalid_response") }
        }
        let status = try JSONDecoder().decode(Self.self, from: data)
        if let catalog = status.execution_catalog, !catalog.isValid { throw ARLError(code: "invalid_response") }
        return status
    }
}

struct CodexTaskReply: Decodable, Sendable {
    let id: String
    let tool: String
    let state: String
    let attempts: Int
    let result: ARLJSON?
    let error: String?
    let updated: Double
    let progress: ARLJSON?
    var text: String? { state == "succeeded" ? result?["text"]?.text : nil }

    static func decode(_ value: ARLJSON, model: String?) throws -> Self {
        let data = try JSONEncoder().encode(value)
        guard data.count <= 65536 else { throw ARLError(code: "invalid_response") }
        let raw = try JSONSerialization.jsonObject(with: data)
        let base: Set<String> = ["id", "tool", "state", "attempts", "result", "error", "updated"]
        let fields = raw as? [String: Any]
        let keys = fields?["progress"] == nil ? base : base.union(["progress"])
        let row = try WireSchema.object(raw, keys)
        guard UUID(uuidString: try WireSchema.string(row["id"], maximum: 40)) != nil,
              try WireSchema.string(row["tool"]) == "codex.text.plan.v1" else { throw ARLError(code: "invalid_response") }
        try WireSchema.choice(row["state"], ["queued", "running", "succeeded", "failed", "cancelled", "needs_review"])
        _ = try WireSchema.integer(row["attempts"])
        try WireSchema.nullableString(row["error"], maximum: 80)
        let reply = try JSONDecoder().decode(Self.self, from: data)
        if reply.state == "succeeded" {
            guard reply.result?["provider"]?.text == "codex_app_server",
                  (model == nil || reply.result?["model"]?.text == model),
                  reply.result?["model"]?.text != nil,
                  let text = reply.text, text.utf8.count <= 32768 else { throw ARLError(code: "invalid_response") }
        }
        return reply
    }
}

actor CodexTextClient {
    private let home: URL
    private let model: String
    private let client: ARLClient
    init(home: URL, model: String) {
        self.home = home; self.model = model
        client = ARLClient(home: home, app: "arl-control")
    }
    func status() async throws -> CodexServiceStatus {
        let value = try await ARLClient(home: home, app: "settings").rpc("codex.service.status.v1")
        return try CodexServiceStatus.decode(value)
    }
    func submit(input: String, operationID: UUID, maxOutputBytes: Int = 4096, selection: CodexExecutionSelection? = nil) async throws -> CodexTaskReply {
        guard !input.isEmpty, input.utf8.count <= 8192, (128...32768).contains(maxOutputBytes) else { throw ARLError(code: "model_budget_exceeded") }
        var args: [String: ARLJSON] = ["model": .string(selection?.model ?? model), "input": .string(input), "max_output_bytes": .number(Double(maxOutputBytes))]
        if let selection {
            guard selection.isWellFormed else { throw ARLError(code: "invalid_arguments") }
            args["reasoning_effort"] = .string(selection.reasoning_effort); args["service_tier"] = .string(selection.service_tier)
        }
        let value = try await client.rpc("submit", params: [
            "tool": .string("codex.text.plan.v1"), "key": .string(operationID.uuidString.lowercased()),
            "args": .object(args)])
        return try CodexTaskReply.decode(value, model: selection?.model ?? model)
    }
    func get(id: UUID) async throws -> CodexTaskReply {
        let value = try await client.rpc("get", params: ["id": .string(id.uuidString.lowercased())])
        return try CodexTaskReply.decode(value, model: nil)
    }
    func cancel(id: UUID) async throws -> CodexTaskReply {
        let value = try await client.rpc("cancel", params: ["id": .string(id.uuidString.lowercased())])
        return try CodexTaskReply.decode(value, model: nil)
    }
}
