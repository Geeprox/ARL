import SwiftUI

struct RemindersFirstSliceView: View {
    let store: RuntimeStore
    @State private var confirming: RemindersFirstAction?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            VStack(alignment: .leading, spacing: 18) {
                if let controller=store.remindersProduct {
                    RemindersProductView(controller:controller,permissionState:store.remindersFirst.value?.permission_state,
                        connect:store.restoreRemindersConnection,requestPermission:{store.performRemindersFirst(.request)})
                }
                DisclosureGroup("旧标题任务") {RemindersTaskComposerView(store:store)}
                DisclosureGroup("旧验收") {
            DetailCard(title: "测试记录") {
                let value = store.remindersFirst.value
                HStack {
                    Text(permissionTitle(value)).help(value?.permission_state == "restricted" ? "系统限制所需访问" : "").font(.callout)
                    Spacer()
                    StatusBadge(title: statusTitle(value), color: value?.permission_state == "authorized_full" && value?.source_state == "selected" && value?.fresh == true ? .green : .secondary).help(value?.smoke_state == "saved_local" ? "仅确认本机保存完成" : "")
                }
                Text(nextStep(value)).font(.callout).foregroundStyle(.secondary)
                if !store.remindersServiceState.canConnect {
                    Text("提醒服务不可用，请检查安装。").font(.caption).foregroundStyle(.secondary)
                } else if value == nil {
                    Button("检查连接") { store.performRemindersFirst(.snapshot) }.disabled(!store.canInspectReminders)
                } else if value?.fresh == false {
                    Button("重新检查") { store.performRemindersFirst(.retest) }.disabled(!store.canInspectReminders)
                } else if value?.active_request_id != nil || store.remindersRequestID != nil {
                    Button("取消操作") { store.cancelRemindersFirst() }
                } else if value?.source_state == "upgrade_review" {
                    Button("核对旧版") { store.performRemindersFirst(.review_upgrade) }.help("核对升级前留下的记录").disabled(!canReview(value))
                } else if value?.permission_state == "not_determined" && value?.smoke_state == "not_started" {
                    Text("允许读取及写入系统提醒事项").font(.caption).foregroundStyle(.secondary)
                    Button("允许访问") { store.performRemindersFirst(.request) }.help("允许读取及写入系统提醒事项").disabled(!canReview(value))
                } else if value?.permission_state == "authorized_full" && value?.smoke_state == "not_started" && value?.source_state != "selected" {
                    Button(value?.source_state == "expired" ? "重选来源" : "选择来源") {
                        store.performRemindersFirst(.select_source)
                    }.help("选择系统提醒事项的来源").disabled(!canSelectSource(value))
                } else if value?.permission_state == "authorized_full" && value?.source_state == "selected" && value?.smoke_state == "not_started" {
                    Button("保存测试") { confirming = .run_smoke }.help("仅保存本次测试提醒").disabled(!canAct(value))
                }
                if let message = store.remindersMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
                Text("来源与测试保存分别确认").font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("连接详情") {
                    VStack(alignment: .leading, spacing: 8) {
                        if let value {
                            Text("来源：\(value.sourceTitle) · 保存记录：\(smokeTitle(value))")
                            Text("测试记录：\(value.run_id) · 上限两次").textSelection(.enabled)
                            HStack {
                                Button("重新检查") { store.performRemindersFirst(.retest) }.disabled(!store.canInspectReminders)
                                Button("停用操作") { store.performRemindersFirst(.disconnect) }.help("保留记录，系统权限不变").disabled(!canAct(value))
                            }.controlSize(.small)
                        }
                        if ["denied", "restricted"].contains(value?.permission_state ?? "") { Text("系统设置 → 隐私与安全性 → 提醒事项") }
                    }.font(.caption).foregroundStyle(.secondary).padding(.top, 6)
                }.help("查看连接及系统权限").font(.caption)
            }
            .alert("保存测试", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })) {
                Button("确认保存") { store.performRemindersFirst(.run_smoke); confirming = nil }
                Button("取消", role: .cancel) { confirming = nil }
            } message: {
                Text("创建一个清单和一个提醒。\n共保存两次，来源可能同步。")
            }
                }
            }
        }
    }
    private func permissionTitle(_ value: RemindersFirstSnapshot?) -> String {
        guard value?.fresh == true else { return "待检查" }
        switch value?.permission_state {
        case "authorized_full": return "允许读写"
        case "not_determined": return "未申请"
        case "denied": return "未授权"
        case "restricted": return "系统限制"
        default: return "待检查"
        }
    }
    private func statusTitle(_ value: RemindersFirstSnapshot?) -> String {
        if !store.remindersServiceState.canConnect { return store.remindersServiceState.title }
        guard let value else { return "等待连接" }
        if value.active_request_id != nil { return "操作中" }
        if value.source_state == "upgrade_review" { return "待核记录" }
        if value.source_state == "upgrade_blocked" { return "暂停保存" }
        if value.smoke_state == "historical_completed" { return "旧版记录" }
        if value.smoke_state == "unknown_preserved" { return "结果未知" }
        if !value.enabled { return "操作停用" }
        if value.smoke_state == "saved_local" { return "本机已存" }
        if value.source_state == "expired" { return "来源过期" }
        if value.source_state == "selected" { return "来源已选" }
        return "等待设置"
    }
    private func nextStep(_ value: RemindersFirstSnapshot?) -> String {
        guard let value else { return "先检查连接，再设置权限。" }
        if value.fresh == false { return "状态已过期，请重新检查。" }
        if value.source_state == "upgrade_review" { return "旧记录待复核，测试保存暂不开始。" }
        if value.source_state == "upgrade_blocked" { return "旧证据变化，测试保存已停止。" }
        if value.smoke_state == "historical_completed" { return "旧记录已用完限额，内容尚未重验。" }
        if value.smoke_state == "unknown_preserved" { return "旧测试结果待核，原操作不重放。" }
        if value.permission_state == "denied" || value.permission_state == "restricted" { return "请在系统设置允许后重新检查。" }
        if value.permission_state == "authorized_full" && value.source_state == "expired" { return "来源过期，请重新选择。" }
        if value.permission_state == "authorized_full" && value.source_state == "selected" { return value.smoke_state == "saved_local" ? "本机已保存，云同步待核。" : "来源已选，保存仍需确认。" }
        return "按下面的步骤继续设置。"
    }
    private func smokeTitle(_ value: RemindersFirstSnapshot) -> String {
        switch value.smoke_state {
        case "saved_local": "本机保存已完成"
        case "historical_completed": "旧记录报告已完成，未重验内容"
        case "unknown_preserved", "needs_review": "结果未知，测试保存已停止"
        case "upgrade_review": "待升级复核"
        case "running": "进行中"
        default: "尚未开始"
        }
    }
    private func canReview(_ value: RemindersFirstSnapshot?) -> Bool {
        store.connected && store.remindersServiceState.canConnect && !store.demo && !store.permissionBusy && value?.fresh == true && value?.active_request_id == nil
    }
    private func canAct(_ value: RemindersFirstSnapshot?) -> Bool {
        store.connected && store.remindersServiceState.canConnect && !store.demo && !store.permissionBusy && value?.enabled == true && value?.fresh == true && value?.active_request_id == nil
    }
    private func canSelectSource(_ value: RemindersFirstSnapshot?) -> Bool {
        store.connected && store.remindersServiceState.canConnect && !store.demo && !store.permissionBusy && value?.fresh == true && value?.active_request_id == nil && value?.permission_state == "authorized_full" && value?.smoke_state == "not_started"
    }
}

private struct RemindersTaskComposerView: View {
    let store: RuntimeStore
    @State private var title = ""
    @State private var draftTaskID = UUID().uuidString.lowercased()
    private var available: Bool { store.canInspectReminders && store.remindersFirst.value?.active_request_id == nil }
    private var permissionReady: Bool { store.remindersFirst.value?.permission_state == "authorized_full" }
    var body: some View {
        DetailCard(title: "提醒事项") {
            Text("每条提醒单独确认范围。").font(.callout).foregroundStyle(.secondary)
            if store.remindersFirst.value?.smoke_state == "unknown_preserved" {
                Text("旧测试结果待核，原记录保留。").font(.caption).foregroundStyle(.secondary)
            }
            if let status=store.remindersFirst.value {
                let title = status.permission_state == "authorized_full" ? "允许读写" : status.permission_state == "not_determined" ? "尚未允许" : status.permission_state == "denied" ? "未获允许" : "状态待更新"
                Text((status.fresh ? "应用权限：":"最近权限：") + title).font(.caption).foregroundStyle(.secondary)
                Text(Date(timeIntervalSince1970:Double(status.observed_at_ms)/1000),format:.dateTime.month().day().hour().minute()).font(.caption).foregroundStyle(.secondary)
                if status.permission_state == "not_determined" {
                    Button("允许访问") { store.performRemindersFirst(.request) }.disabled(!available)
                } else if ["denied","restricted"].contains(status.permission_state) {
                    Link("系统设置",destination:URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders")!)
                }
            } else {
                Text(store.remindersRestoring ? "正在连接提醒服务…":"提醒服务尚未连接").font(.caption).foregroundStyle(.secondary)
            }
            if let failure=store.remindersStatusFailure {
                Text("最近更新未完成：" + failure).font(.caption).foregroundStyle(.secondary)
                Button("恢复连接") { store.restoreRemindersConnection() }.disabled(store.remindersRestoring || store.permissionBusy)
            }
            if let task = store.remindersTask {
                taskView(task)
            } else if let id = store.remindersTaskCurrentID {
                Text("操作记录待核，请先查看结果。").font(.callout).foregroundStyle(.secondary)
                Button("查看结果") { store.performRemindersTask(.task_status, taskID: id) }.disabled(!store.canInspectReminders)
                if store.remindersTaskMissing { Button("另建提醒") { store.startAnotherReminder(); title = ""; draftTaskID = UUID().uuidString.lowercased() }.disabled(!available) }
            } else {
                TextField("提醒内容", text: $title).disabled(store.permissionBusy)
                Button("创建提醒") {
                    store.createReminder(title:title,taskID:draftTaskID)
                }.disabled(!available || (try? RemindersTaskContract.title(title)) == nil)
            }
            if store.remindersRequestID != nil || store.remindersFirst.value?.active_request_id != nil {
                HStack { ProgressView().controlSize(.small); Button("取消操作") { store.cancelRemindersFirst() } }
            }
            if let message = store.remindersTaskMessage { Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
            historyView
        }
        .task { await store.prepareRemindersPage() }
    }
    @ViewBuilder private func taskView(_ task: RemindersTaskRecord) -> some View {
        HStack { Text(task.title).font(.headline).textSelection(.enabled); Spacer(); Text(task.state.title).font(.caption).foregroundStyle(.secondary) }
        if let scope = task.scope {
            Text("列表：" + RemindersTaskContract.display(scope.source.default_list_title)).font(.callout)
            Text("来源：" + RemindersTaskContract.display(scope.source.title)).font(.caption).foregroundStyle(.secondary)
        }
        if store.remindersTaskUnconfirmed {
            Text("结果未确认，请先查看同一条记录。").font(.callout).foregroundStyle(.secondary)
            Button("查看结果") { store.performRemindersTask(.task_status, taskID: task.task_id) }.disabled(!store.canInspectReminders)
        } else if task.state == .draft || task.state == .scoped {
            let needsScope = task.state == .draft || store.remindersTaskNeedsScope || (task.scope?.expires_at_ms ?? 0) <= Int64(Date().timeIntervalSince1970 * 1000)
            HStack {
                if needsScope {
                    Button("选择范围") { store.performRemindersTask(.task_scope, taskID: task.task_id, expected: task.digest) }.disabled(!available || !permissionReady)
                } else {
                    Button("确认创建") { store.performRemindersTask(.task_submit, taskID: task.task_id, expected: task.digest) }.disabled(!available || !permissionReady)
                }
                Menu("更多") {
                    if task.state == .scoped { Button("重选范围") { store.performRemindersTask(.task_scope, taskID: task.task_id, expected: task.digest) } }
                    Button("取消本次") { store.performRemindersTask(.task_cancel, taskID: task.task_id, expected: task.digest) }
                }.disabled(!available)
            }
            Text("本次只创建一条，不修改已有提醒。").font(.caption).foregroundStyle(.secondary)
        } else {
            if task.state == .unknown || task.state == .attempting {
                Text("结果待核，本条不会再次保存。").font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Button("查看结果") { store.performRemindersTask(.task_status, taskID: task.task_id) }.disabled(!store.canInspectReminders)
                Button("另建提醒") { store.startAnotherReminder(); title = ""; draftTaskID = UUID().uuidString.lowercased() }.disabled(!available)
            }
        }
        DisclosureGroup("操作详情") {
            Text("操作：" + task.task_id).textSelection(.enabled)
            if let scope = task.scope {
                Text("范围有效至：" + Date(timeIntervalSince1970: Double(scope.expires_at_ms) / 1000).formatted(date: .omitted, time: .standard))
            }
            Text("重启或停用后，需要重新确认范围。")
            Text("本机保存与云端同步分别核验。")
        }.font(.caption).foregroundStyle(.secondary)
    }
    private var historyView: some View {
        DisclosureGroup("操作记录") {
            Button("查看记录") { store.performRemindersTask(.task_list, offset: 0) }.disabled(!store.canInspectReminders)
            if let page = store.remindersTaskPage {
                if page.entries.isEmpty { Text("暂无新任务记录").foregroundStyle(.secondary) }
                ForEach(page.entries) { row in
                    HStack {
                        Text(row.title).lineLimit(2); Spacer(); Text(row.state.title).foregroundStyle(.secondary)
                        Button("查看") { store.performRemindersTask(.task_status, taskID: row.task_id) }.disabled(!store.canInspectReminders)
                    }
                }
                HStack {
                    if page.offset > 0 { Button("上一页") { store.performRemindersTask(.task_list, offset: max(0, page.offset - 5)) }.disabled(!store.canInspectReminders) }
                    if let next = page.next_offset { Button("下一页") { store.performRemindersTask(.task_list, offset: next) }.disabled(!store.canInspectReminders) }
                }
            }
        }.font(.caption)
    }
}
