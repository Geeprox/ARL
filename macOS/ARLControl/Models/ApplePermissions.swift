import Foundation

struct ApplePermissionRecord: Decodable, Identifiable, Sendable {
    let capability_id: String
    let operation: String
    let helper_bundle_id: String?
    let executable_sha256: String?
    let designated_requirement_sha256: String?
    let observed_at_ms: Int64?
    let permission_kind: String
    let permission_state: String
    let implementation_state: String
    let request_route_state: String
    let settings_route_state: String
    let readiness_state: String
    let enabled: Bool
    let connection_state: String
    let access_evidence: String
    let preflight_code: String
    var id: String { capability_id }
    func evidenceIsCurrent(at now: Date) -> Bool {
        guard let time=observed_at_ms, time > 0 else { return false }
        let age=now.timeIntervalSince1970*1000-Double(time)
        return age.isFinite && age >= 0 && age <= 30000
    }
    var title: String {
        if id.hasPrefix("apple.reminders."), let operation=ApplePermissionSnapshot.remindersV3Titles[id] { return operation }
        return switch id {
        case "calendar.create.v1": "创建日程"
        case "reminders.create.v1": "创建提醒"
        case "notes.create.v1": "创建笔记"
        case "notes.search.v1": "查找笔记"
        case "notes.read.v1": "核对笔记"
        case "notes.create.v2": "备忘录 · 纯文本创建 v2"
        case "notes.append.v1": "追加内容"
        case "notes.edit.v1": "编辑笔记"
        case "messages.send.v1": "发送信息"
        case "messages.receive.v1": "接收信息"
        case "local_network.connect.v1": "网络连接"
        default: "Keychain · 项目访问"
        }
    }
    var displayExplanation: String {
        if id.hasPrefix("apple.reminders."), implementation_state == "installed", !enabled {
            return "通用操作尚未启用，只显示接入状态" + "\n" + "当前只开放固定的首轮验收；此通用操作的执行授权尚未启用。"
        }
        return switch id {
        case "reminders.create.v1": "仅创建这一次提醒"
        case "notes.create.v1": "使用第一版创建接口"
        case "notes.read.v1": "只读取本次创建的备忘录"
        default: ""
        }
    }
    var permissionTitle: String {
        if permission_kind == "required_file_access" { return access_evidence == "verified" ? "访问已核验" : access_evidence == "blocked" ? "访问受阻" : ("访问未测试" + "\n" + "所需访问未测试") }
        if permission_kind == "local_network" { return access_evidence == "verified" ? "连接已核验" : access_evidence == "blocked" ? "连接受阻" : ("连接未测试" + "\n" + "连接记录未测试") }
        switch permission_state {
        case "authorized_write_only": return "已授权 · 仅写入"
        case "authorized_full": return "已授权 · 完全访问"
        case "authorized_automation": return "已授权 · 此应用自动化"
        case "not_determined": return "尚未请求"
        case "denied": return "未授权"
        case "restricted": return "系统限制"
        case "not_applicable": return "不适用"
        default: return "授权状态未核验"
        }
    }
    var stateTitle: String {
        if implementation_state == "not_implemented" { return "未实现" }
        if implementation_state == "source_only" { return "待接入" }
        if !enabled { return "已停用" }
        if connection_state == "disconnected" { return "未连接" }
        switch readiness_state {
        case "ready": return "就绪"
        case "needs_permission": return "需要权限"
        case "needs_setup": return "需要设置"
        case "needs_unlock": return "需要解锁"
        case "lock_state_unknown": return "锁定状态未核验"
        case "grant_inactive": return "执行授权未启用"
        case "grant_expired": return "执行授权已过期"
        case "budget_exhausted": return "调用次数已用完"
        case "unavailable": return "操作不可用"
        default: return "就绪状态未核验"
        }
    }
    var guidance: String {
        if id.hasPrefix("apple.reminders."),implementation_state == "installed",!enabled { return ("仅开放指定首次测试，其他操作未授权" + "\n" + "当前只开放固定的首轮验收；此通用操作的执行授权尚未启用。") }
        if id == "notes.append.v1" { return ("请核对权限与本次操作范围" + "\n" + "追加操作流程尚未导入与逐次核验；自动化权限不能证明追加就绪。") }
        if preflight_code == "calendar_setup_blocked" { return ("日历设置入口待修复，暂不能申请权限" + "\n" + "日历系统设置入口待修复核验；当前不能发起授权。") }
        if preflight_code == "identity_unverified" || preflight_code == "identity_changed" { return ("辅助程序身份未确认，请检查安装" + "\n" + "辅助程序身份未通过核验，需要检查安装。") }
        if preflight_code == "target_not_running" { return ("目标应用未启动，启动后重新检查" + "\n" + "目标应用未运行，启动后可重新检查。") }
        if permission_kind == "required_file_access" { return ("所需访问单独核对，无通用权限测试" + "\n" + "仅显示该操作所需访问的证据；完全磁盘访问没有通用精确操作前检查。") }
        if permission_kind == "local_network" { return ("请核对连接状态与使用范围" + "\n" + "需要实际连接操作验证；普通网络错误不能判定为隐私拒绝。") }
        if permission_kind == "keychain_item" { return ("真实登录信息与逐项访问权限尚未接入" + "\n" + "真实登录信息引用与项目访问控制尚未接入。") }
        if implementation_state == "not_implemented" { return ("此操作未接入，不能申请权限或执行" + "\n" + "此操作尚未接入，不能请求权限或执行。") }
        if implementation_state == "source_only" { return ("辅助程序状态与申请入口尚未安装核验" + "\n" + "辅助程序状态与请求入口尚未安装核验。") }
        if request_route_state != "available" { return ("当前没有可用的系统授权入口" + "\n" + "当前没有可用的系统授权入口。") }
        return ("系统权限与执行授权分别确认" + "\n" + "系统权限与执行授权分别核验。")
    }
    var settingsGuidance: String {
        let pane: String
        switch permission_kind {
        case "calendar_write", "calendar_full": pane = "日历"
        case "reminders_full": pane = "提醒事项"
        case "automation_notes", "automation_messages": pane = "自动化"
        case "required_file_access": pane = "完全磁盘访问"
        case "local_network": pane = "本地网络"
        default: return ""
        }
        return "系统设置 → 隐私与安全性 → \(pane)"
    }
    var requestPurpose: String {
        switch permission_kind {
        case "calendar_write": ("请核对权限与本次操作范围" + "\n" + "由日历辅助程序打开系统设置，按需请求日历写入权限，并确认默认日历及一小时、最多三次的执行范围。")
        case "reminders_full": ("请核对权限与本次操作范围" + "\n" + "由提醒事项辅助程序请求完全访问权限。系统权限包含读取和写入；此按钮不创建提醒事项。")
        case "automation_notes": ("请核对权限与本次操作范围" + "\n" + "请求此辅助程序自动化备忘录的权限；此按钮不读取或写入备忘录内容。")
        case "automation_messages": ("请核对权限与本次操作范围" + "\n" + "请求此辅助程序自动化信息应用的权限；此按钮不发送信息。")
        default: ("此操作没有系统权限申请入口" + "\n" + "当前操作没有原生权限请求入口。")
        }
    }
}

struct AppleManualRequest: Decodable, Sendable {
    let request_id: String
    let capability_id: String
    let action: String
    let outcome: String
    let in_flight: Bool
    var title: String {
        switch outcome {
        case "in_progress": ("等待系统授权流程" + "\n" + "等待原生权限流程")
        case "completed": "系统流程已结束，请核对权限状态"
        case "denied": "未获得权限"
        case "restricted": "系统限制"
        case "user_cancelled": "已取消；未建立执行授权"
        case "timed_out": in_flight ? "请求已超时，系统流程尚未结束" : "请求已超时"
        case "opened_settings": "已发送系统设置打开请求"
        case "settings_unavailable": "系统设置入口不可用"
        case "refreshed": "已重新检查"
        case "identity_changed": "辅助程序身份已变化"
        case "unavailable": "系统请求入口不可用"
        default: "需核对系统授权结果"
        }
    }
}

struct ApplePermissionSnapshot: Decodable, Sendable {
    let schema_version: Int
    let observed_at_ms: Int64
    let records: [ApplePermissionRecord]
    let manual_request: AppleManualRequest?
    static let remindersV3Titles: [String:String] = ["apple.reminders.sources.v3":"提醒来源", "apple.reminders.lists.v3":"提醒清单", "apple.reminders.list.lookup.v3":"查找清单", "apple.reminders.list.create.v3":"创建清单", "apple.reminders.query.v3":"查找提醒", "apple.reminders.get.v3":"读取提醒", "apple.reminders.create.v3":"创建提醒", "apple.reminders.update.v3":"更新提醒", "apple.reminders.complete.v3":"完成提醒", "apple.reminders.uncomplete.v3":"标为未完"]
    static let ids: Set<String> = Set(remindersV3Titles.keys).union(["calendar.create.v1","reminders.create.v1","notes.create.v1","notes.search.v1","notes.read.v1","notes.create.v2","notes.append.v1","notes.edit.v1","messages.send.v1","messages.receive.v1","local_network.connect.v1","keychain.item_access.v1"])
    static let kinds: [String:String] = remindersV3Titles.mapValues { _ in "reminders_full" }.merging(["calendar.create.v1":"calendar_write","reminders.create.v1":"reminders_full","notes.create.v1":"automation_notes","notes.search.v1":"automation_notes","notes.read.v1":"automation_notes","notes.create.v2":"automation_notes","notes.append.v1":"automation_notes","notes.edit.v1":"automation_notes","messages.send.v1":"automation_messages","messages.receive.v1":"required_file_access","local_network.connect.v1":"local_network","keychain.item_access.v1":"keychain_item"]) { _, value in value }
    static let preflightCodes: Set<String> = ["ok","not_determined","denied","restricted","native_status_unavailable","identity_unverified","identity_changed","target_not_running","automation_unknown","permission_unknown","status_timeout","status_unavailable","unimplemented","setup_required","calendar_setup_blocked","required_access_untested","required_access_verified","required_access_blocked","no_universal_preflight","keychain_contract_missing"]
    static let permissions: Set<String> = ["not_determined","authorized_write_only","authorized_full","authorized_automation","denied","restricted","unknown","not_applicable"]
    static let readiness: Set<String> = ["ready","needs_permission","needs_setup","needs_unlock","lock_state_unknown","grant_inactive","grant_expired","budget_exhausted","unavailable","unknown"]
    static let outcomes: Set<String> = ["in_progress","refreshed","opened_settings","settings_unavailable","completed","denied","restricted","user_cancelled","timed_out","unavailable","identity_changed","needs_review"]
    static func decode(_ data: Data) throws -> Self {
        guard let raw = try JSONSerialization.jsonObject(with:data) as? [String:Any], Set(raw.keys) == ["schema_version","observed_at_ms","records","manual_request"] else { throw ARLError(code:"invalid_response") }
        let recordKeys: Set<String> = ["capability_id","operation","helper_bundle_id","executable_sha256","designated_requirement_sha256","observed_at_ms","permission_kind","permission_state","implementation_state","request_route_state","settings_route_state","readiness_state","enabled","connection_state","access_evidence","preflight_code"]
        guard let records=raw["records"] as? [[String:Any]], records.allSatisfy({ Set($0.keys) == recordKeys }) else { throw ARLError(code:"invalid_response") }
        let value=try JSONDecoder().decode(Self.self,from:data)
        guard value.schema_version == 1, value.records.count == ids.count, Set(value.records.map(\.id)) == ids else { throw ARLError(code:"invalid_response") }
        for record in value.records {
            guard kinds[record.id] == record.permission_kind, preflightCodes.contains(record.preflight_code), permissions.contains(record.permission_state), readiness.contains(record.readiness_state),
                ["installed","source_only","not_implemented"].contains(record.implementation_state),
                ["available","not_installed","not_implemented","blocked_identity","requires_user_action"].contains(record.request_route_state),
                ["available","not_installed","not_implemented","blocked_identity","requires_user_action"].contains(record.settings_route_state),
                ["connected","disconnected"].contains(record.connection_state),["verified","blocked","untested"].contains(record.access_evidence) else { throw ARLError(code:"invalid_response") }
            let identity=[record.helper_bundle_id,record.executable_sha256,record.designated_requirement_sha256]
            guard identity.allSatisfy({$0 == nil}) || identity.allSatisfy({$0 != nil}) else { throw ARLError(code:"invalid_response") }
            for hash in [record.executable_sha256,record.designated_requirement_sha256].compactMap({$0}) {
                guard hash.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil else { throw ARLError(code:"invalid_response") }
            }
            let sufficient: [String:Set<String>] = ["calendar_write":["authorized_write_only","authorized_full"],"reminders_full":["authorized_full"],"automation_notes":["authorized_automation"],"automation_messages":["authorized_automation"]]
            if record.permission_state.hasPrefix("authorized") {
                let bundles: [String:String] = ["calendar_write":"local.arl.mioapplebridge","reminders_full":"local.arl.remindersbridge","automation_notes":"local.arl.notesbridge","automation_messages":"local.arl.messagesbridge"]
                guard sufficient[record.permission_kind]?.contains(record.permission_state) == true, bundles[record.permission_kind] == record.helper_bundle_id else { throw ARLError(code:"invalid_response") }
                guard record.implementation_state == "installed", record.helper_bundle_id != nil, record.observed_at_ms != nil else { throw ARLError(code:"invalid_response") }
            }
            if record.readiness_state == "ready" {
                guard record.enabled,record.connection_state == "connected",record.permission_state.hasPrefix("authorized"),record.implementation_state == "installed" else { throw ARLError(code:"invalid_response") }
            }
        }
        if let manual=value.manual_request {
            guard UUID(uuidString:manual.request_id)?.uuidString.lowercased() == manual.request_id, ids.contains(manual.capability_id),["request","open_settings","retest"].contains(manual.action),outcomes.contains(manual.outcome) else { throw ARLError(code:"invalid_response") }
        }
        return value
    }
    static var untested: Self {
        return Self(schema_version:1,observed_at_ms:0,records:ids.sorted().map { id in
            let source=id.hasPrefix("apple.reminders.") || ["calendar.create.v1","reminders.create.v1","notes.create.v1","notes.search.v1","notes.read.v1","notes.create.v2","notes.append.v1","messages.send.v1","messages.receive.v1"].contains(id)
            return ApplePermissionRecord(capability_id:id,operation:id.split(separator:".")[1].description,helper_bundle_id:nil,executable_sha256:nil,designated_requirement_sha256:nil,observed_at_ms:nil,permission_kind:Self.kinds[id]!,permission_state:"unknown",implementation_state:source ? "source_only" : "not_implemented",request_route_state:source ? "not_installed" : "not_implemented",settings_route_state:"requires_user_action",readiness_state:"unavailable",enabled:true,connection_state:"disconnected",access_evidence:"untested",preflight_code:"native_status_unavailable")
        },manual_request:nil)
    }
    func overlayReminders(_ native:RemindersFirstSnapshot?) -> Self {
        let replacements=Dictionary(uniqueKeysWithValues:Self.untested.records.filter{$0.id.hasPrefix("apple.reminders.")}.map{($0.id,$0)})
        let next=records.map { record -> ApplePermissionRecord in
            guard Self.remindersV3Titles[record.id] != nil else{return record}
            guard let native else{return replacements[record.id]!}
            // The fixed acceptance host is deployed; general per-operation RPC
            // remains disabled. Actual OS status is useful, never an effect grant.
            return ApplePermissionRecord(capability_id:record.id,operation:record.operation,helper_bundle_id:native.identity.helper_bundle_id,executable_sha256:native.identity.executable_sha256,designated_requirement_sha256:native.identity.designated_requirement_sha256,observed_at_ms:native.observed_at_ms,permission_kind:"reminders_full",permission_state:native.permission_state,implementation_state:"installed",request_route_state:"available",settings_route_state:"requires_user_action",readiness_state:"grant_inactive",enabled:false,connection_state:"connected",access_evidence:"untested",preflight_code:native.permission_state=="authorized_full" ? "ok":native.permission_state=="unknown" ? "permission_unknown":native.permission_state)
        }
        return Self(schema_version:1,observed_at_ms:native?.observed_at_ms ?? observed_at_ms,records:next,manual_request:manual_request)
    }
}
