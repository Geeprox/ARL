import Foundation

struct RemindersSelectedSource: Codable, Equatable, Sendable {
    let id:String;let title:String;let type:Int;let default_list_id:String;let default_list_title:String
}

// One user-reviewed creation in an existing default list. This namespace never
// imports the historical acceptance run, receipt, source grant or save budget.
enum RemindersTaskState: String, Codable, Sendable {
    case draft, scoped, attempting, saved, unknown, cancelled
    var title: String {
        switch self {
        case .draft: "待选范围"
        case .scoped: "等待创建"
        case .attempting, .unknown: "结果待核"
        case .saved: "本机已存"
        case .cancelled: "已取消"
        }
    }
    var terminal: Bool { self != .draft && self != .scoped }
}
struct RemindersTaskScope: Codable, Equatable, Sendable {
    let source: RemindersSelectedSource
    let identity: RemindersFirstIdentity
    let expires_at_ms: Int64
    let expires_uptime: Double
    let host_session_id: String
}
struct RemindersTaskRecord: Codable, Sendable {
    let schema_version: Int
    let task_id: String
    let operation_id: String
    let title: String
    let identity: RemindersFirstIdentity
    let policy_sha256: String
    var state: RemindersTaskState
    var scope: RemindersTaskScope?
    var reminder_id: String?
    var digest: String { (try? RemindersTaskContract.digest(self)) ?? "" }
}
struct RemindersTaskSummary: Codable, Identifiable, Sendable {
    let task_id: String
    let title: String
    let state: RemindersTaskState
    var id: String { task_id }
}
struct RemindersTaskPage: Codable, Sendable {
    let offset: Int
    let next_offset: Int?
    let entries: [RemindersTaskSummary]
}
enum RemindersTaskContract {
    static let actions: Set<RemindersFirstAction> = [.task_prepare, .task_scope, .task_submit, .task_status, .task_cancel, .task_list]
    static func uuid(_ value: String) -> Bool { UUID(uuidString: value)?.uuidString.lowercased() == value }
    static func hash(_ value: String) -> Bool { value.utf8.count == 64 && value.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil }
    static func title(_ value: String) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.unicodeScalars.count <= 300,
              value.utf8.count <= 1200, !value.unicodeScalars.contains(where: { $0.value < 32 || (127...159).contains($0.value) || $0.properties.generalCategory == .format }) else { throw RemindersTransportFault("invalid_task_title") }
    }
    static func target(_ value: RemindersSelectedSource) throws {
        guard [0, 1, 2, 3].contains(value.type), [value.id, value.default_list_id].allSatisfy({ !$0.isEmpty && $0.utf8.count <= 1024 && !$0.unicodeScalars.contains(where: { $0.value < 32 || (127...159).contains($0.value) || $0.properties.generalCategory == .format }) }),
              [value.title, value.default_list_title].allSatisfy({ $0.utf8.count <= 512 }) else { throw RemindersTransportFault("target_changed") }
    }
    static func display(_ value: String) -> String {
        if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "未命名" }
        return value.unicodeScalars.map { scalar in
            scalar.value < 32 || (127...159).contains(scalar.value) || scalar.properties.generalCategory == .format || scalar.properties.generalCategory == .lineSeparator || scalar.properties.generalCategory == .paragraphSeparator
                ? "\\u{" + String(scalar.value, radix: 16) + "}" : scalar == "\\" ? "\\\\" : String(scalar)
        }.joined()
    }
    static func digest<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return RemindersNativeIO.hash(try encoder.encode(value))
    }
    static func operationID(_ id: String) -> String {
        let h = Array(RemindersNativeIO.hash(Data(("arl.reminders.task.create.v1:" + id).utf8)).prefix(32))
        return String(h[0..<8]) + "-" + String(h[8..<12]) + "-" + String(h[12..<16]) + "-" + String(h[16..<20]) + "-" + String(h[20..<32])
    }
}

enum RemindersTaskCopy {
    static func message(outcome: String, code: String) -> String {
        switch code {
        case "task_ready": return "内容已记录，请选定本次范围。"
        case "task_scope_selected": return "范围已确认，尚未保存。"
        case "task_saved": return "本机已保存，云同步待核。"
        case "task_cancelled": return "本次已取消，原记录保留。"
        case "task_scope_required": return "范围已失效，请重新选择。"
        case "task_outcome_unknown", "task_already_consumed": return "结果待核，本条不会再次保存。"
        case "needs_permission": return "请先允许提醒事项访问。"
        case "task_changed", "target_changed": return "内容或目标已变化，请查看记录。"
        case "task_payload_too_large": return "目标信息过长，暂不能选用。"
        case "task_not_found": return "尚无这条记录，可另建提醒。"
        case "task_capacity": return "记录已满，请保留现场并检查。"
        case "task_record_changed", "unsafe_config", "unsafe_home": return "记录未通过核验，请查看详情。"
        case "cancelled": return "本次已停止，请查看操作记录。"
        case "ok": return "已读取操作记录，未重新保存。"
        default: return "操作未完成：" + code
        }
    }
}
