import Foundation

/// Local deployment evidence only. This never represents EventKit authorization.
enum RemindersServiceState: String, Sendable {
    case notInstalled, verifiedDisabled, verifiedEnabled, synthetic, identityUnverified, preview, sourceHeld
    var canConnect: Bool { self == .verifiedEnabled || self == .synthetic }
    var title: String {
        switch self {
        case .notInstalled: "未配置"
        case .verifiedDisabled: "已停用"
        case .verifiedEnabled: "可连接"
        case .synthetic: "模拟服务"
        case .identityUnverified: "待核验"
        case .preview: "仅供演示"
        case .sourceHeld: "待接入"
        }
    }
}

// Narrow onboarding protocol, separate from general operation RPC/grants.
enum RemindersFirstAction: String, Codable, Sendable {
    case snapshot, request, retest, select_source, review_upgrade, run_smoke, disconnect, cancel, shutdown
    case task_prepare, task_scope, task_submit, task_status, task_cancel, task_list
}
struct RemindersFirstFrame: Codable, Sendable {
    let schema_version: Int
    let capability_id: String
    let action: RemindersFirstAction
    let request_id: String
    var task_id: String? = nil
    var title: String? = nil
    var expected_digest: String? = nil
    var offset: Int? = nil
    static let firstCapability = "reminders.first_acceptance.v1"
    static let operationIDs = Set(["sources","lists","list.lookup","list.create","query","get","create","update","complete","uncomplete"].map { "apple.reminders.\($0).v3" })
    init(action: RemindersFirstAction, requestID: UUID, capability: String = firstCapability) {
        schema_version=1;capability_id=capability;self.action=action;request_id=requestID.uuidString.lowercased()
    }
    init(task action: RemindersFirstAction, requestID: UUID, taskID: String? = nil, title: String? = nil, expected: String? = nil, offset: Int? = nil) {
        schema_version=2;capability_id="reminders.task.create.v1";self.action=action;request_id=requestID.uuidString.lowercased()
        task_id=taskID;self.title=title;expected_digest=expected;self.offset=offset
    }
    static func decode(_ data: Data) throws -> Self {
        let raw=try RemindersNativeIO.flatObject(data)
        let base:Set<String>=["schema_version","capability_id","action","request_id"]
        let value=try JSONDecoder().decode(Self.self,from:data)
        guard UUID(uuidString:value.request_id)?.uuidString.lowercased()==value.request_id else{throw RemindersTransportFault("invalid_arguments")}
        if RemindersTaskContract.actions.contains(value.action) {
            guard RemindersNativeIO.integer(raw["schema_version"])==2,value.capability_id=="reminders.task.create.v1" else{throw RemindersTransportFault("invalid_arguments")}
            var keys=base
            switch value.action {
            case .task_list:
                keys.insert("offset");guard let offset=value.offset,(0...256).contains(offset),RemindersNativeIO.integer(raw["offset"])==offset else{throw RemindersTransportFault("invalid_arguments")}
            case .task_prepare:
                keys.formUnion(["task_id","title"]);guard let title=value.title else{throw RemindersTransportFault("invalid_task_title")};try RemindersTaskContract.title(title)
            default:
                keys.insert("task_id")
                if value.action != .task_status {keys.insert("expected_digest");guard let digest=value.expected_digest,RemindersTaskContract.hash(digest) else{throw RemindersTransportFault("invalid_arguments")}}
            }
            guard Set(raw.keys)==keys,value.action == .task_list || value.task_id.map(RemindersTaskContract.uuid)==true else{throw RemindersTransportFault("invalid_arguments")}
        } else {
            guard Set(raw.keys)==base,RemindersNativeIO.integer(raw["schema_version"])==1,
                value.capability_id==firstCapability || operationIDs.contains(value.capability_id),
                value.capability_id==firstCapability || [.snapshot,.request,.retest].contains(value.action) else{throw RemindersTransportFault("invalid_arguments")}
        }
        return value
    }

}
struct RemindersFirstIdentity: Codable, Equatable, Sendable {
    let helper_bundle_id: String
    let executable_sha256: String
    let designated_requirement_sha256: String
}
struct RemindersFirstSnapshot: Codable, Sendable {
    let schema_version: Int
    let identity: RemindersFirstIdentity
    let observed_at_ms: Int64
    let enabled: Bool
    let permission_state: String
    let source_state: String
    let smoke_state: String
    let run_id: String
    let max_saves: Int
    let active_request_id: String?
    let active_action: String?
    let prompts_requested: Bool
    let data_read: Bool
    var fresh: Bool { let age=Date().timeIntervalSince1970*1000-Double(observed_at_ms);return age>=0 && age<=30000 }
    var sourceTitle:String{switch source_state{case "selected":"已选择";case "expired":"已过期，需重新确认";case "changed":"身份或来源已变化";case "needs_review":"需人工核查";case "upgrade_review":"需复核旧记录";case "reviewed":"旧记录已复核";case "upgrade_blocked":"复核证据已变化，保存已停止";default:"尚未选择"}}
    static func decode(_ data:Data) throws -> Self {
        let required:Set<String>=["schema_version","identity","observed_at_ms","enabled","permission_state","source_state","smoke_state","run_id","max_saves","prompts_requested","data_read"]
        guard let raw=try JSONSerialization.jsonObject(with:data) as? [String:Any],required.isSubset(of:Set(raw.keys)),Set(raw.keys).isSubset(of:required.union(["active_request_id","active_action"])) else {throw RemindersTransportFault("invalid_response")}
        let value=try JSONDecoder().decode(Self.self,from:data)
        guard value.schema_version==1,value.identity.helper_bundle_id=="local.arl.remindersbridge",value.max_saves==2,
            UUID(uuidString:value.run_id)?.uuidString.lowercased()==value.run_id,
            ["not_determined","authorized_full","denied","restricted","unknown"].contains(value.permission_state),
            ["unselected","selected","expired","changed","needs_review","upgrade_review","reviewed","upgrade_blocked"].contains(value.source_state),
            ["not_started","running","saved_local","needs_review","stopped","upgrade_review","historical_completed","unknown_preserved"].contains(value.smoke_state),
            [value.identity.executable_sha256,value.identity.designated_requirement_sha256].allSatisfy({$0.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil}),
            value.active_request_id==nil || UUID(uuidString:value.active_request_id!)?.uuidString.lowercased()==value.active_request_id,
            value.active_action==nil || RemindersFirstAction(rawValue:value.active_action!) != nil else {throw RemindersTransportFault("invalid_response")}
        return value
    }
}
struct RemindersFirstReply: Codable, Sendable {
    let schema_version: Int
    let request_id: String
    let action: RemindersFirstAction
    let outcome: String
    let code: String
    let snapshot: RemindersFirstSnapshot?
    var task: RemindersTaskRecord? = nil
    var task_page: RemindersTaskPage? = nil
}

enum RemindersFirstCopy {
    static func message(outcome: String, code: String) -> String {
        switch code {
        case "upgrade_review_required": return "请点击“核对旧版”。\n尚未读取提醒内容或重新保存。"
        case "upgrade_review_changed", "upgrade_evidence_unreadable", "upgrade_policy_unreviewed": return "复核证据已变化或无法核验，测试保存已停止。原记录已保留；可重新检查或断开执行范围，请勿清除记录后重试。"
        case "save_budget_consumed": return "旧记录已用完两次保存次数，不会再次保存。"
        case "saved_outcome_unknown": return "旧保存结果未知，已停止新的测试保存。可重新检查或断开；原记录将保留。"
        case "cancelled": return "已取消本次操作；没有因此恢复测试保存。"
        case "needs_permission": return "当前权限不足；来源复核未完成，未保存提醒。请核对系统权限后重新检查。"
        default: break
        }
        switch outcome {
        case "historical_completed": return "旧记录报告两次保存已完成，预算已保留；未核验当前提醒内容或云同步，不会再次保存。"
        case "unknown_preserved": return "已保留旧记录和未知结果；新的测试保存已停止。仍可重新检查或断开执行范围。"
        case "source_reviewed": return "旧来源已复核，原记录已保留。请继续选择来源；保存测试提醒仍需单独确认。"
        case "saved_local": return "两次本机保存已完成；云同步尚未核验，请检查专用测试列表。"
        case "source_selected": return "已选择你确认的来源；尚未保存测试列表或提醒。"
        case "completed": return "权限流程已结束；请核对实际状态。"
        case "refreshed": return "内部提醒事项服务已连接并重新核验；重新检查不会重试保存。"
        case "disconnected": return "执行范围已断开；旧记录与保存预算已保留，系统权限没有撤销。"
        default: return "流程结果：\(outcome)（\(code)）；请核查原请求，勿自动重复保存。"
        }
    }
}
