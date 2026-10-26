import Foundation

/// Optional schema 1: local tunnel health is independent of tool/supplier readiness.
struct ModulesSnapshot: Codable, Sendable {
    let schema_version: Int
    let checked_at_ms: Int
    let modules: [ModuleHealth]

    static func decode(_ data: Data) throws -> Self {
        let root = try WireSchema.object(JSONSerialization.jsonObject(with: data), ["schema_version", "checked_at_ms", "modules"])
        try WireSchema.constantInt(root["schema_version"], 1)
        _ = try WireSchema.integer(root["checked_at_ms"])
        let modules = try WireSchema.array(root["modules"])
        try WireSchema.uniqueIDs(modules)
        for value in modules {
            let module = try WireSchema.object(value, ["id", "name", "checked_at_ms", "stale_after_ms", "liveness", "readiness", "evidence", "external_roundtrip", "tool_publication", "tool_count", "provider_readiness", "error_code"])
            try WireSchema.identifier(module["id"])
            _ = try WireSchema.string(module["name"])
            try WireSchema.nullableInteger(module["checked_at_ms"])
            try WireSchema.constantInt(module["stale_after_ms"], 10_000)
            try WireSchema.choice(module["liveness"], ["live", "unavailable", "unknown"])
            try WireSchema.choice(module["readiness"], ["ready", "unavailable", "unknown"])
            try WireSchema.choice(module["evidence"], ["local_client_health"])
            for key in ["external_roundtrip", "tool_publication", "provider_readiness"] { try WireSchema.choice(module[key], ["not_checked"]) }
            guard module["tool_count"] is NSNull else { throw ARLError(code: "invalid_response") }
            if !(module["error_code"] is NSNull) { try WireSchema.choice(module["error_code"], ["probe_unavailable", "probe_deadline_exceeded"]) }
        }
        return try JSONDecoder().decode(Self.self, from: data)
    }

    func mioStatus(at now: Date) -> MioTunnelStatus? {
        guard let mio = modules.first(where: { $0.id == "mio.gateway" }) else { return nil }
        guard let checked = mio.checked_at_ms else { return .unknown }
        let nowMS = now.timeIntervalSince1970 * 1000
        let age = nowMS - Double(checked)
        guard age >= 0, Double(checked_at_ms) <= nowMS else { return .unknown }
        guard age <= Double(mio.stale_after_ms) else { return .stale }
        if mio.error_code != nil { return .failed }
        if mio.liveness == "unavailable" { return .unavailable }
        guard mio.liveness == "live" else { return .unknown }
        if mio.readiness == "ready" { return .ready }
        return mio.readiness == "unavailable" ? .notReady : .live
    }
}

struct ModuleHealth: Codable, Sendable {
    let id: String; let name: String
    let checked_at_ms: Int?; let stale_after_ms: Int
    let liveness: String; let readiness: String; let evidence: String
    let external_roundtrip: String; let tool_publication: String; let tool_count: Int?
    let provider_readiness: String; let error_code: String?
}

enum MioTunnelStatus: Sendable {
    case ready, live, notReady, unavailable, unknown, stale, failed
    var title: String {
        switch self {
        case .ready: "本机就绪"
        case .live: "本机在线 · 就绪未知"
        case .notReady: "本机未就绪"
        case .unavailable: "本机不可用"
        case .unknown: "本机状态未知"
        case .stale: "本机状态已过期"
        case .failed: "本机检查失败"
        }
    }
    static let evidenceExplanation = "仅检查本机 Mio 隧道。云端往返、工具发布及供应方状态尚未核验。"
}
