import Foundation
import CoreFoundation

struct RuntimeSnapshot: Codable, Sendable {
    let schema_version: Int
    let `protocol`: String
    let version: String
    let health: Health
    let queue: Queue
    let providers: [ModelProvider]
    let capabilities: [Capability]
    let policy: Policy
    let budgets: [Budget]
    struct Health: Codable, Sendable { let live: Bool; let ready: Bool; let ui_required: Bool }
    struct Queue: Codable, Sendable { let available: Bool; let counts: [String: Int] }
    struct Policy: Codable, Sendable {
        let local_inference_enabled: Bool; let paid_inference_enabled: Bool
        let automatic_fallback: Bool; let model_downloads: Bool; let identity_verifier_configured: Bool
    }
    var outstanding: Int {
        ["queued", "running", "needs_unlock"].reduce(0) { total, state in
            let (sum, overflow) = total.addingReportingOverflow(queue.counts[state] ?? 0)
            return overflow ? Int.max : sum
        }
    }
}
struct ModelProvider: Codable, Identifiable, Sendable {
    let name: String; let availability: String; let models: [String]; let paid: Bool
    let inference_policy: String; let allowed_apps: [String]
    var id: String { name }
    var title: String {
        switch name { case "ollama": "Ollama"; case "codex_app_server": "Codex"; case "jev": "Jev"; case "mock": "测试模型"; default: name }
    }
}
struct Capability: Codable, Identifiable, Sendable {
    let name: String; let availability: String; let identity_gate: String; let authorization_gate: String
    var id: String { name }
    var isApple: Bool { name.hasPrefix("apple.") }
}
struct Budget: Codable, Identifiable, Sendable {
    let app: String; let max_pending: Int; let max_calls: Int?; let max_output_tokens: Int; let max_prompt_utf8_bytes: Int
    var id: String { app }
}
enum ControlSection: String, CaseIterable, Identifiable {
    case overview = "概览", performance = "性能", models = "本地 Agent", capabilities = "云端 Bot"
    case moments = "朋友圈"
    case credentials = "服务连接"
    case calendar = "日历", reminders = "提醒事项", messages = "Messages", notes = "备忘录"
    case logs = "日志", advanced = "管理"
    static let navigation: [Self] = [.overview, .credentials, .calendar, .reminders, .messages, .notes, .moments, .performance, .logs, .advanced]
    var id: String { rawValue }
    var displayTitle: String {
        switch self { case .models: "模型"; case .capabilities: "权限"; case .advanced: "诊断"; case .notes: "备忘"; case .logs: "运行记录"; case .messages: "信息"; default: rawValue }
    }
    var displayExplanation: String {
        switch self {
        case .performance: "查看系统与应用用量"
        case .models: "查看本机应用与模型"
        case .capabilities: "查看应用与平台工具"
        case .credentials: "查看服务连接与登录状态"
        case .messages: "查看信息连接与收发范围"
        case .notes: "查看备忘录连接与权限"
        case .advanced: "查看后台服务与访问规则"
        default: subtitle
        }
    }
    var icon: String {
        switch self { case .moments: "photo.stack"; case .overview: "square.grid.2x2"; case .performance: "chart.xyaxis.line"; case .models: "cpu"; case .capabilities: "cloud"; case .credentials: "key.horizontal"; case .calendar: "calendar"; case .reminders: "checklist"; case .messages: "message"; case .notes: "note.text"; case .logs: "list.bullet.rectangle"; case .advanced: "slider.horizontal.3" }
    }
    var subtitle: String {
        switch self { case .moments: "本地归档与 NAS"; case .overview: "运行状态"; case .performance: "系统用量"; case .models: "本机服务"; case .capabilities: "平台工具"; case .credentials: "登录状态"; case .calendar: "日程与权限"; case .reminders: "权限与来源"; case .messages: "信息设置"; case .notes: "接入状态"; case .logs: "运行记录"; case .advanced: "服务设置" }
    }
}

// Exact settings-overview schema v1. Validate before publishing a ready snapshot.
extension RuntimeSnapshot {
    static func decode(_ data: Data) throws -> RuntimeSnapshot {
        let raw = try JSONSerialization.jsonObject(with: data)
        let root = try MetadataSchema.object(raw, keys: ["schema_version", "protocol", "version", "health", "queue", "providers", "capabilities", "policy", "budgets"])
        guard try MetadataSchema.integer(root["schema_version"]) == 1,
              try MetadataSchema.string(root["protocol"]) == "arl/1" else { throw ARLError(code: "unsupported_protocol") }
        _ = try MetadataSchema.string(root["version"])
        let health = try MetadataSchema.object(root["health"], keys: ["live", "ready", "ui_required"])
        _ = try MetadataSchema.boolean(health["live"]); _ = try MetadataSchema.boolean(health["ready"])
        guard try !MetadataSchema.boolean(health["ui_required"]) else { throw ARLError(code: "invalid_response") }
        let queue = try MetadataSchema.object(root["queue"], keys: ["available", "counts"])
        _ = try MetadataSchema.boolean(queue["available"])
        let counts = try MetadataSchema.object(queue["counts"], keys: ["queued", "running", "succeeded", "failed", "cancelled", "needs_unlock", "needs_review"])
        var total = 0
        for value in counts.values {
            let (sum, overflow) = total.addingReportingOverflow(try MetadataSchema.integer(value))
            guard !overflow else { throw ARLError(code: "invalid_response") }; total = sum
        }
        for item in try MetadataSchema.array(root["providers"]) {
            let p = try MetadataSchema.object(item, keys: ["name", "availability", "models", "paid", "inference_policy", "allowed_apps"])
            _ = try MetadataSchema.string(p["name"])
            try MetadataSchema.enumeration(p["availability"], values: ["ready", "unavailable", "not_ready", "disabled", "unknown"])
            try MetadataSchema.enumeration(p["inference_policy"], values: ["disabled", "explicit_route_only"])
            _ = try MetadataSchema.boolean(p["paid"])
            for value in try MetadataSchema.array(p["models"]) { _ = try MetadataSchema.string(value) }
            for value in try MetadataSchema.array(p["allowed_apps"]) { _ = try MetadataSchema.string(value) }
        }
        for item in try MetadataSchema.array(root["capabilities"]) {
            let c = try MetadataSchema.object(item, keys: ["name", "availability", "identity_gate", "authorization_gate"])
            _ = try MetadataSchema.string(c["name"])
            try MetadataSchema.enumeration(c["availability"], values: ["ready", "needs_permission", "adapter", "disabled", "unavailable", "not_configured", "unknown"])
            try MetadataSchema.enumeration(c["identity_gate"], values: ["verified_peer_required", "none"])
            try MetadataSchema.enumeration(c["authorization_gate"], values: ["permission_required", "authorization_not_checked", "not_required"])
        }
        let policy = try MetadataSchema.object(root["policy"], keys: ["local_inference_enabled", "paid_inference_enabled", "automatic_fallback", "model_downloads", "identity_verifier_configured"])
        for key in ["local_inference_enabled", "identity_verifier_configured"] { _ = try MetadataSchema.boolean(policy[key]) }
        for key in ["paid_inference_enabled", "automatic_fallback", "model_downloads"] {
            guard try !MetadataSchema.boolean(policy[key]) else { throw ARLError(code: "invalid_response") }
        }
        for item in try MetadataSchema.array(root["budgets"]) {
            let b = try MetadataSchema.object(item, keys: ["app", "max_pending", "max_calls", "max_output_tokens", "max_prompt_utf8_bytes"])
            _ = try MetadataSchema.string(b["app"])
            for key in ["max_pending", "max_output_tokens"] { _ = try MetadataSchema.integer(b[key]) }
            if !(b["max_calls"] is NSNull) { _ = try MetadataSchema.integer(b["max_calls"]) }
            guard try MetadataSchema.integer(b["max_prompt_utf8_bytes"]) == 1024 else { throw ARLError(code: "invalid_response") }
        }
        return try JSONDecoder().decode(Self.self, from: data)
    }
}
private enum MetadataSchema {
    static func object(_ value: Any?, keys: Set<String>) throws -> [String: Any] {
        guard let object = value as? [String: Any], Set(object.keys) == keys else { throw ARLError(code: "invalid_response") }; return object
    }
    static func string(_ value: Any?) throws -> String {
        guard let string = value as? String, !string.isEmpty, string.unicodeScalars.count <= 200 else { throw ARLError(code: "invalid_response") }; return string
    }
    static func boolean(_ value: Any?) throws -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw ARLError(code: "invalid_response") }; return number.boolValue
    }
    static func integer(_ value: Any?) throws -> Int {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let integer = Int(number.stringValue), integer >= 0 else { throw ARLError(code: "invalid_response") }; return integer
    }
    static func array(_ value: Any?) throws -> [Any] {
        guard let array = value as? [Any], array.count <= 100 else { throw ARLError(code: "invalid_response") }; return array
    }
    static func enumeration(_ value: Any?, values: Set<String>) throws {
        guard values.contains(try string(value)) else { throw ARLError(code: "invalid_response") }
    }
}
