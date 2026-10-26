import SwiftUI
import AppKit
import ARLCredentialHostCore

struct ContentView: View {
    let store: RuntimeStore
    let codexSettings: CodexNativeController?
    @State private var selection: ControlSection?
    @AppStorage("refreshAutomatically") private var autoRefresh = true
    init(store: RuntimeStore, initialSection: ControlSection = .overview, codexSettings: CodexNativeController? = nil) {
        self.store = store
        self.codexSettings = codexSettings
        _selection = State(initialValue: initialSection)
    }
    private var current: ControlSection { selection ?? .overview }
    var body: some View {
        HSplitView {
            EditorialSidebar(selection: $selection, connected: store.connected, statusColor: store.color)
            VStack(spacing: 0) { sectionContent }
                .buttonStyle(EditorialActionButtonStyle())
                .textFieldStyle(EditorialFieldStyle())
                .groupBoxStyle(EditorialGroupBoxStyle())
                .controlSize(.regular)
                .background(EditorialStyle.canvas)
                .toolbar {
                    if #available(macOS 26.0, *) {
                        ToolbarItem { RuntimeToolbarActions(store: store, diagnostics: [.advanced, .performance, .logs].contains(current)) }.sharedBackgroundVisibility(.hidden)
                    } else {
                        ToolbarItem { RuntimeToolbarActions(store: store, diagnostics: [.advanced, .performance, .logs].contains(current)) }
                    }
                }
                .safeAreaInset(edge: .bottom) { updateStatus }
        }
        .toolbarBackground(EditorialStyle.canvas, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .tint(EditorialStyle.accent).frame(minWidth: 850, minHeight: 580)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await store.refresh() }
        }
        .task {
            await store.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { break }
                if autoRefresh { await store.refresh() }
            }
        }
    }

    @ViewBuilder private var sectionContent: some View {
        if current == .logs { LogsView(store: store).padding(24) }
        else if current == .credentials { ServiceConnectionsView(store: store, navigate: navigate) }
        else if [.calendar, .reminders, .notes, .messages].contains(current) {
            ServiceConnectionsView(store: store, navigate: navigate, initialDestination: connectionDestination).id(current)
        }
        else {
            ScrollView {
                VStack(alignment: .leading, spacing: EditorialStyle.sectionSpacing) {
                    if current != .overview {
                    HStack(alignment: .firstTextBaseline) {
                        EditorialHeading(title: current == .models ? "模型" : current == .capabilities ? "应用接入" : current == .advanced ? "运行诊断" : current.displayTitle, subtitle: "").help(current.displayExplanation)
                        Spacer(minLength: 12)
                        if let label = store.previewLabel { StatusBadge(title: label) }
                    }
                    }
                    switch current {
                    case .overview: OverviewView(store: store, navigate: navigate)
                    case .performance: MetricsView(store: store)
                    case .models: ModelConnectionSettings(controller: codexSettings ?? store.codex)
                    case .capabilities:
                        RegistryView(feature: store.control.registry)
                        ApplePermissionsView(feature: store.permissions, connected: store.connected,
                            disabled: store.errorCode == "user_disabled", preview: store.demo,
                            busy: store.permissionBusy, actionMessage: store.permissionMessage,
                            perform: store.performPermission, navigate: navigate, nativeActionsHeld: store.nativeActionsHeld,
                            calendarManagedByMain: true, notesManagedByMain: true)
                    case .moments: MomentsView(controller: store.moments, nas: store.nasSettings)
                    case .calendar, .reminders, .notes, .messages, .credentials, .logs: EmptyView()
                    case .advanced:
                        RuntimeDiagnosticsSummary(store: store, navigate: navigate)
                        RuntimeOperationRecovery(store: store)
                        AdvancedView(store: store)
                    }
                }.padding(24).frame(maxWidth: 1180, alignment: .leading).frame(maxWidth: .infinity, alignment: .center)
            }.id(selection)
        }
    }

    private var connectionDestination: String {
        switch current {
        case .calendar: "日历"
        case .reminders: "提醒事项"
        case .notes: "备忘录"
        case .messages: "信息"
        default: "日历"
        }
    }

    private func navigate(_ section: ControlSection) { selection = section }
    private var updateStatus: some View {
        HStack(spacing: 12) {
            Text(store.demo ? "演示数据" : "本机")
            Spacer(minLength: 12)
            if let date = store.lastUpdated { Text("更新于 \(date.formatted(date: .omitted, time: .standard))").monospacedDigit() }
        }.font(.caption2).foregroundStyle(.secondary)
            .padding(.horizontal, 24).padding(.vertical, 9).frame(maxWidth: .infinity)
            .background(EditorialStyle.canvas)
            .overlay(alignment: .top) { Rectangle().fill(EditorialStyle.rule).frame(height: 0.5) }
    }
}

private struct RuntimeToolbarActions: View {
    let store: RuntimeStore
    let diagnostics: Bool
    var body: some View {
        HStack(spacing: 6) {
            if diagnostics {
            Button { Task { await store.refresh(resetLogs: true) } } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 14))
            }.help("刷新状态（⌘R）").accessibilityLabel("刷新").disabled(store.reading)
            }
            SettingsLink { Image(systemName: "gearshape").font(.system(size: 14)) }
                .help("偏好设置（⌘,）").accessibilityLabel("偏好设置")
        }.buttonStyle(EditorialActionButtonStyle(emphasis: .quiet))
            .accessibilityElement(children: .contain)
    }
}


private struct RuntimeDiagnosticsSummary: View {
    let store: RuntimeStore
    let navigate: (ControlSection) -> Void
    var body: some View {
        DetailCard(title: "运行检查") {
            Button("应用接入") { navigate(.capabilities) }
            if let code = store.bundledRuntimeError {
                Text("连接服务异常").font(.callout)
                Text(code).font(.caption.monospaced()).textSelection(.enabled)
                Button(store.bundledRuntimeRecovering ? "正在恢复" : "恢复后台") { store.recoverBundledRuntime() }
                    .disabled(store.bundledRuntimeRecovering)
            }
            if let code = store.controlError {
                Text("状态读取失败").font(.callout)
                Text(code).font(.caption.monospaced()).textSelection(.enabled)
                Button("重新读取状态") { Task { await store.refresh() } }.disabled(store.reading)
            }
            if let snapshot = store.snapshot {
                MetadataRow(title: "未完任务", value: snapshot.queue.available ? String(snapshot.outstanding) : "暂不可读")
                MetadataRow(title: "等待解锁", value: snapshot.queue.available ? String(snapshot.queue.counts["needs_unlock"] ?? 0) : "—")
                MetadataRow(title: "待核对", value: snapshot.queue.available ? String(snapshot.queue.counts["needs_review"] ?? 0) : "—")
            }
        }
        RegistryView(feature: store.control.registry)
    }
}

struct ModelConnectionSettings: View {
    let controller: CodexNativeController
    private var selection: CodexExecutionSelection? { controller.executionSelection }
    private var catalog: CodexExecutionCatalog? { controller.executionCatalog }
    private var model: CodexExecutionModel? { catalog?.models.first { $0.id == selection?.model } }
    private var configurable: Bool { catalog?.isValid == true && catalog?.selection_enabled == true && !controller.busy }
    private var needsCheck: Bool { controller.errorCode != nil || controller.status?.state != "ready" || catalog == nil }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .firstTextBaseline) {
                Text("Codex").font(.system(size: 17, weight: .semibold))
                Spacer(minLength: 16)
                Text(connectionTitle).font(.caption).foregroundStyle(.secondary)
                if needsCheck {
                    Button(controller.statusReading ? "正在检查" : "检查连接") { Task { await controller.refreshStatus() } }
                        .disabled(controller.statusReading || !controller.enabled)
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 18) { modelControl; effortControl; fastControl }
                VStack(alignment: .leading, spacing: 18) { modelControl; effortControl; fastControl }
            }
            if let message = controller.message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            } else if let code = controller.errorCode ?? controller.status?.reason ?? controller.status?.last_error_code {
                Text("连接未完成（" + code + "）。").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if let selection, catalog?.selection_enabled == true, catalog?.permits(selection) != true {
                Text("保存的组合不可用，请重新选择。").font(.caption).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: 650, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
            .task { await controller.refreshStatus() }
    }
    private var modelControl: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("模型").font(.caption).foregroundStyle(.secondary)
            Menu {
                ForEach(catalog?.models ?? []) { option in
                    Button { controller.selectExecution(option.selecting(from: selection)) } label: {
                        Label(option.display_name, systemImage: option.id == selection?.model ? "checkmark" : "cpu")
                    }
                }
            } label: { Text(model?.display_name ?? selection?.model ?? "未载入").frame(maxWidth: .infinity, alignment: .leading) }
                .modifier(EditorialMenuSurface()).frame(width: 220).disabled(!configurable)
                .accessibilityLabel("Codex 模型").accessibilityValue(model?.display_name ?? "未载入")
        }
    }
    private var effortControl: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("思考强度").font(.caption).foregroundStyle(.secondary)
            Menu {
                ForEach(model?.efforts ?? []) { effort in
                    Button { if var next = selection { next.reasoning_effort = effort.id; controller.selectExecution(next) } } label: {
                        Label(effort.title, systemImage: selection?.reasoning_effort == effort.id ? "checkmark" : "brain")
                    }
                }
            } label: { Text(selection.map { CodexEffortOption.title($0.reasoning_effort) } ?? "未载入").frame(maxWidth: .infinity, alignment: .leading) }
                .modifier(EditorialMenuSurface()).frame(width: 140).disabled(!configurable || model == nil)
                .accessibilityLabel("Codex 思考强度")
        }
    }
    private var fastControl: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("加速").font(.caption).foregroundStyle(.secondary)
            Button {
                if var next = selection { next.service_tier = next.fast ? "default" : "fast"; controller.selectExecution(next) }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: selection?.fast == true ? "bolt.fill" : "bolt")
                    Text(model?.fast_available == true ? selection?.fast == true ? "开启" : "关闭" : "不可用")
                }.frame(width: 82, height: EditorialStyle.controlHeight)
            }.buttonStyle(EditorialActionButtonStyle(emphasis: selection?.fast == true ? .primary : .secondary))
                .disabled(!configurable || model?.fast_available != true)
                .accessibilityLabel("Codex 加速").accessibilityValue(selection?.fast == true ? "开启" : "关闭")
                .accessibilityAddTraits(selection?.fast == true ? .isSelected : [])
                .help(model?.fast_available == true ? "使用 Fast 档位，可能更快消耗额度。" : "当前模型未提供 Fast。")
        }
    }
    private var connectionTitle: String {
        if controller.statusReading { return "正在检查" }
        if controller.errorCode != nil || controller.status?.last_error_code != nil { return "连接失败" }
        guard let status = controller.status else { return "未检查" }
        switch status.state {
        case "ready": return "连接检查通过"
        case "preflight_pending": return "正在检查"
        case "budget_exhausted": return "调用额度已用完"
        case "not_configured": return "未连接"
        default: return "需要处理"
        }
    }
}

/// Read-only receipts and recovery remain available after removal of business composers.
private struct RuntimeOperationRecovery: View {
    let store: RuntimeStore
    var body: some View {
        if let record = store.codex.taskRecord {
            DetailCard(title: "Codex 原任务") {
                MetadataRow(title: "任务", value: record.jobID?.uuidString.lowercased() ?? record.operationID.uuidString.lowercased())
                MetadataRow(title: "状态", value: record.phase)
                if let text = record.reply?.text { Text(text).font(.callout).textSelection(.enabled) }
                HStack {
                    Button("核对原任务") { store.codex.inspectOriginal() }.disabled(!store.codex.canInspect)
                    Button("取消原任务") { store.codex.requestCancel() }
                        .disabled(record.jobID == nil || record.permitsNewIntent)
                }
                if let message = store.codex.message { Text(message).font(.caption).foregroundStyle(.secondary) }
            }
        }
        if let reminders = store.remindersProduct {
            DetailCard(title: "提醒事项操作记录") {
                HStack {
                    Button("读取记录") { reminders.refreshHistory() }.disabled(reminders.busy)
                    if reminders.pendingTaskID != nil {
                        Button("核对原操作") { reminders.refreshOperation() }.disabled(reminders.busy)
                    }
                }
                ForEach(reminders.history) { row in
                    Button(row.title + " · " + row.state) { reminders.run(.init(.status, taskID: row.task_id)) }.disabled(reminders.busy)
                }
                if reminders.historyNextOffset != nil { Button("更多记录") { reminders.refreshHistory(more: true) }.disabled(reminders.busy) }
                if let task = reminders.task { MetadataRow(title: "原操作状态", value: task.state + " · " + task.code) }
                if let message = reminders.message { Text(message).font(.caption).foregroundStyle(.secondary) }
            }
        }
        if let calendar = store.calendarBusiness, let id = calendar.currentTaskID {
            DetailCard(title: "日历原操作") {
                Text(id).font(.caption.monospaced()).textSelection(.enabled)
                Button("核对原操作") { Task { await calendar.status(taskID: id) } }.disabled(calendar.busy)
                if let message = calendar.message { Text(message).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
}
