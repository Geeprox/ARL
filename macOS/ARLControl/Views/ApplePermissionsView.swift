import SwiftUI

struct ApplePermissionsView: View {
    let feature: MetadataFeature<ApplePermissionSnapshot>
    let connected: Bool
    let disabled: Bool
    let preview: Bool
    let busy: Bool
    let actionMessage: String?
    let perform: (String, String) -> Void
    var navigate: (ControlSection) -> Void = { _ in }
    var nativeActionsHeld = false
    var calendarManagedByMain = false
    var notesManagedByMain = false
    @State private var requesting: ApplePermissionRecord?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            DetailCard(title: "苹果应用") {
                if nativeActionsHeld { Text("应用接入待核验。").foregroundStyle(.secondary) }
                else if !connected { Text(disabled ? "后台服务已停用" : "等待后台服务连接").foregroundStyle(.secondary) }
                else if feature.value == nil { Text(feature.explanation).foregroundStyle(.secondary) }
                if connected {
                    VStack(spacing: 0) {
                        ForEach(groups) { group in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(group.title).font(.callout.weight(.semibold))
                                    Spacer()
                                    StatusBadge(title: operationSummary(group, at: timeline.date), color: group.records.contains { $0.readiness_state == "ready" && $0.evidenceIsCurrent(at: timeline.date) } ? .green : .secondary).help(operationSummary(group, at: timeline.date) == "部分可用" ? "只有部分操作可用" : "")
                                }
                                ForEach(Self.scopeRows(group.records, at: timeline.date)) { scope in
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(scope.title).font(.caption)
                                            Text(scope.kind).font(.caption2).foregroundStyle(.secondary)
                                            if let record = group.records.first(where: { $0.id == scope.id }), !record.displayExplanation.isEmpty { Text(record.displayExplanation).font(.caption).foregroundStyle(.secondary) }
                                            if scope.kind == "应用控制" { Text("允许控制指定的系统应用").font(.caption2).foregroundStyle(.secondary) }
                                            if scope.kind == "提醒权限" { Text("允许读取及写入系统提醒事项").font(.caption2).foregroundStyle(.secondary) }
                                        }
                                        Spacer()
                                        Text(scope.permission).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                if let section = group.records.compactMap({ PermissionRouteRegistry.section(for: $0.id) }).first {
                                    Button("前往设置") { navigate(section) }.controlSize(.small)
                                } else if let record = group.records.first(where: { PermissionRouteRegistry.usesRuntimeManualRoute($0.id) }) {
                                    HStack {
                                        if record.request_route_state == "available" && record.evidenceIsCurrent(at: timeline.date) {
                                            Button("申请权限") { requesting = record }.help("申请所选操作的系统权限").disabled(!canAct)
                                        }
                                        Button("重新检查") { perform(record.id, "retest") }.disabled(!canAct)
                                    }.controlSize(.small)
                                }
                                Text("权限与操作范围分别确认").font(.caption).foregroundStyle(.secondary)
                                DisclosureGroup("权限详情") {
                                    VStack(alignment: .leading, spacing: 7) {
                                        ForEach(group.records) { record in
                                            HStack { Text(record.title); Spacer(); Text(record.stateTitle) }
                                            if let helper = record.helper_bundle_id { Text("辅助程序：\(helper)").foregroundStyle(.secondary) }
                                        }
                                        if let record = group.records.first, !record.settingsGuidance.isEmpty { Text(record.settingsGuidance) }
                                    }.font(.caption).foregroundStyle(.secondary).padding(.top, 6)
                                }.help("查看操作内容及对应权限").font(.caption)
                            }.padding(.vertical, 12)
                            if group.id != groups.last?.id { Divider() }
                        }
                    }
                }
                if let request = feature.value?.manual_request { Text(request.title).help(request.outcome == "restricted" ? "系统限制所需权限" : "").font(.caption).foregroundStyle(.secondary) }
                if let actionMessage { Text(actionMessage).font(.caption).foregroundStyle(.secondary) }
            }
            .alert("申请权限", isPresented: Binding(get: { requesting != nil }, set: { if !$0 { requesting = nil } }), presenting: requesting) { record in
                Button("继续") { perform(record.id, "request"); requesting = nil }
                Button("取消", role: .cancel) { requesting = nil }
            } message: { record in Text("申请所选操作的系统权限" + "\n" + record.requestPurpose) }
        }
    }

    private struct Group: Identifiable {
        let id: String
        let title: String
        let records: [ApplePermissionRecord]
    }
    private var groups: [Group] {
        let records = (feature.value?.records ?? []).filter { PermissionRouteRegistry.section(for: $0.id) == nil && !(calendarManagedByMain && $0.id.contains("calendar")) && !(notesManagedByMain && $0.id.hasPrefix("notes.")) }
        let grouped = Dictionary(grouping: records) { record -> String in
            if record.id.contains("reminders") { return "reminders" }
            if record.id.contains("calendar") { return "calendar" }
            if record.id.contains("notes") { return "notes" }
            if record.id.contains("messages") { return "messages" }
            if record.id.contains("network") { return "network" }
            return "keychain"
        }
        let names = ["reminders": "提醒事项", "calendar": "日历", "notes": "备忘录", "messages": "信息", "network": "本地网络", "keychain": "钥匙串"]
        return ["calendar", "reminders", "notes", "messages", "network", "keychain"].compactMap { id in
            grouped[id].map { Group(id: id, title: names[id] ?? id, records: $0) }
        }
    }
    struct ScopeRow: Identifiable {
        let id: String
        let title: String
        let kind: String
        let permission: String
    }
    static func scopeRows(_ records: [ApplePermissionRecord], at date: Date) -> [ScopeRow] {
        records.map { record in
            let kind = switch record.permission_kind {
            case "required_file_access": "文件访问"
            case "automation_messages", "automation_notes": "应用控制"
            case "reminders_full": "提醒权限"
            case "calendar_write": "日历写入"
            case "local_network": "本地网络"
            case "keychain_item": "登录项目"
            default: "系统权限"
            }
            return ScopeRow(id: record.id, title: record.title, kind: kind,
                     permission: record.evidenceIsCurrent(at: date) ? record.permissionTitle : "待检查")
        }
    }
    private func operationSummary(_ group: Group, at date: Date) -> String {
        if group.records.contains(where: { $0.readiness_state == "ready" && $0.enabled && $0.evidenceIsCurrent(at: date) }) { return "部分可用" }
        if group.records.allSatisfy({ $0.implementation_state == "not_implemented" }) { return "未接入" }
        return "未开放"
    }
    private var canAct: Bool { !nativeActionsHeld && connected && !disabled && !preview && feature.value != nil && !busy && feature.value?.manual_request?.in_flight != true }
}
