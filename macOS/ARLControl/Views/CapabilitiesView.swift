import SwiftUI

struct CapabilitiesView: View {
    let snapshot: RuntimeSnapshot?
    let control: ControlPlaneState
    let connected: Bool
    var modules: MetadataFeature<ModulesSnapshot> = .unsupported
    var permissions: MetadataFeature<ApplePermissionSnapshot> = .unsupported
    var mioCalendarPermission: MetadataFeature<MioCalendarPermissionStatus> = .unsupported
    var calendarPermission: CalendarPermissionController?
    var notesDirect: NotesDirectController?
    var messagesDirect: MessagesDirectController?
    var runtimeDisabled = false
    var preview = false
    var permissionBusy = false
    var permissionMessage: String?
    var performPermission: (String,String) -> Void = { _,_ in }
    var navigate: (ControlSection) -> Void = { _ in }
    var nativeActionsHeld = false
    var body: some View {
        ApplePermissionsView(feature:permissions,connected:connected,disabled:runtimeDisabled,preview:preview,busy:permissionBusy,actionMessage:permissionMessage,perform:performPermission,navigate:navigate,nativeActionsHeld:nativeActionsHeld,calendarManagedByMain:calendarPermission != nil,notesManagedByMain:notesDirect != nil)
        if let notesDirect {
            DetailCard(title: "备忘录") {
                permissionObservation(notesDirect.connection.state)
                MetadataRow(title: "已接入", value: "标题查找、正文读取、新建笔记")
                MetadataRow(title: "尚未接入", value: "追加、编辑与 Mio 调用")
                Button("打开备忘录设置") { navigate(.notes) }
            }
        }
        if let messagesDirect {
            DetailCard(title: "信息") {
                permissionObservation(messagesDirect.connection.state)
                MetadataRow(title: "已接入", value: "单个邮箱文字发送")
                MetadataRow(title: "尚未接入", value: "历史读取、接收与 Mio 调用")
                Button("打开信息设置") { navigate(.messages) }
            }
        }
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            DetailCard(title: "创建日程") {
                MetadataRow(title: calendarPermission?.lastProbeFailed == true ? "最近权限" : "应用权限", value: calendarPermission?.state.title ?? "待检查")
                MetadataRow(title: "执行入口", value: "ARL 日历")
                if let observed = calendarPermission?.observedAt {
                    Text(observed, format: .dateTime.month().day().hour().minute()).font(.caption).foregroundStyle(.secondary)
                }
                if calendarPermission?.lastProbeFailed == true {
                    Text("状态暂未更新，保留最近权限观测。").font(.caption).foregroundStyle(.secondary)
                }
                if calendarPermission?.state == .notDetermined {
                    Button("允许创建") { Task { await calendarPermission?.request() } }
                        .disabled(calendarPermission?.canAct != true || nativeActionsHeld || preview)
                }
                if let message = calendarPermission?.message {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
                Button("打开日历") {navigate(.calendar)}
                    .font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("权限详情") {
                    MetadataRow(title: "授权应用", value: "ARL")
                    MetadataRow(title: "旧版服务", value: mioCalendarPermission.value?.permissionTitle(nowMS: Int64(timeline.date.timeIntervalSince1970 * 1000)) ?? "待检查")
                    Text("旧版服务权限不能代替 ARL 权限。")
                    if let status = calendarPermission?.nativeStatus { Text("系统代码：\(status)") }
                    if let detail = calendarPermission?.requestDiagnostic { Text(detail).textSelection(.enabled) }
                    Link("系统设置", destination: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
                }.font(.caption).foregroundStyle(.secondary)
            }
        }
        if let snapshot {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
            let mioStatus = modules.value?.mioStatus(at: Date())
            VStack(alignment: .leading, spacing: 18) {
                HStack { Label("Mio 连接", systemImage: "cloud").font(.callout.weight(.medium)); Spacer(); StatusBadge(title: mioStatus?.title ?? "暂无状态", color: mioStatus == .ready ? .green : .orange).help(MioTunnelStatus.evidenceExplanation) }.padding(.horizontal, 4)
                Text("工具发布状态尚未确认").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 4)
                DetailCard(title: "平台服务") {
                    let platform = snapshot.capabilities.filter { $0.name.hasPrefix("mio_") || $0.name.hasPrefix("netease.") }
                    if platform.isEmpty { Text("暂无平台工具").font(.callout).foregroundStyle(.secondary) }
                    ForEach(platformGroups(platform).filter { $0.id != "mio" }, id: \.id) { group in
                        DisclosureGroup {
                            VStack(spacing: 10) { ForEach(group.tools) { tool in MetadataRow(title: tool.name, value: capabilityState(tool)) } }.padding(.leading, 50).padding(.vertical, 10)
                        } label: { HStack(spacing: 14) { AppIcon(id: group.id, symbol: group.symbol, size: 36); VStack(alignment: .leading, spacing: 4) { Text(group.title).font(.callout.weight(.medium)); Text("\(group.tools.count) 项工具").font(.caption).foregroundStyle(.secondary) }; Spacer(); StatusBadge(title: platformState(group), color: platformState(group) == "可用" ? .green : .orange) }.padding(.vertical, 8) }
                    }
                }

            }
            }
        } else { EmptyRuntimeView() }
    }
    @ViewBuilder private func permissionObservation(_ state: AppleConnectionState<AppleDirectPermission>) -> some View {
        let title: String = switch state.value {
        case .authorized: "已授权"
        case .notDetermined: "尚未允许"
        case .denied: "未获允许"
        case .unknown, nil: "状态待更新"
        }
        MetadataRow(title: state.showingLastKnown ? "最近权限" : "应用权限", value: title)
        if let observed = state.observedAt {
            Text(observed, format: .dateTime.month().day().hour().minute()).font(.caption).foregroundStyle(.secondary)
        }
        if let failure = state.lastFailure {
            Text(failure.issue == .targetNotRunning && state.value == nil ? "应用尚未运行，连接时会查询权限。" : failure.issue.title).font(.caption).foregroundStyle(.secondary)
        }
    }
    private struct PlatformGroup { let id: String; let title: String; let symbol: String; let tools: [Capability] }
    private func platformState(_ group: PlatformGroup) -> String {
        group.tools.allSatisfy { capabilityState($0) == "可用" } ? "可用" : group.tools.contains { capabilityState($0) == "可用" } ? "部分可用" : "待检查"
    }
    private func platformGroups(_ tools: [Capability]) -> [PlatformGroup] {
        let entries = ServiceConnectionCatalog.load()?.services ?? []
        let grouped = Dictionary(grouping: tools) { tool in
            entries.first { entry in entry.tool_prefixes.contains { tool.name.hasPrefix($0) } }?.id
                ?? (tool.name == "mio_tunnel_ping" ? "mio" : "platform")
        }
        return grouped.keys.sorted().map { id in
            let entry = entries.first { $0.id == id }
            return PlatformGroup(id: id, title: entry?.name ?? (id == "mio" ? "Mio 连接" : "平台工具"),
                                 symbol: entry?.symbol ?? "puzzlepiece.extension", tools: grouped[id] ?? [])
        }
    }
    private func capabilityState(_ tool: Capability) -> String {
        if tool.availability == "ready" { return tool.authorization_gate == "not_required" ? "可用" : tool.authorization_gate == "permission_required" ? "需要权限" : "待核授权" }
        switch tool.availability { case "not_configured": return "未配置"; case "needs_permission": return "需要权限"; case "adapter": return "已声明"; case "disabled": return "已关闭"; case "unavailable": return "服务故障"; default: return "未知" }
    }
}
