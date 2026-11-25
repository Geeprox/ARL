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
        .tint(EditorialStyle.accent).frame(minWidth: 760, minHeight: 540)
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
                    case .models:
                        CodexPackagesSettingsView(home:store.service.home.appendingPathComponent("CodexPackages"),
                            enabled:!store.demo && !store.isolated && !store.nativeActionsHeld && store.codex.enabled, controller:codexSettings ?? store.codex)
                    case .capabilities:
                        RegistryView(feature: store.control.registry)
                    case .moments: MomentsView(controller: store.moments, nas: store.nasSettings)
                    case .calendar, .reminders, .notes, .messages, .credentials, .logs: EmptyView()
                    case .advanced:
                        RuntimeDiagnosticsSummary(store: store, navigate: navigate)
                        AdvancedView(store: store)
                        RuntimeOperationRecovery(store: store)
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
                Image(systemName: "arrow.clockwise").font(.system(size: 14)).frame(width: 16, height: 40)
            }.help("刷新状态（⌘R）").accessibilityLabel("刷新").disabled(store.reading)
            }
            SettingsLink { Image(systemName: "gearshape").font(.system(size: 14)).frame(width: 16, height: 40) }
                .help("偏好设置（⌘,）").accessibilityLabel("偏好设置")
        }.buttonStyle(EditorialActionButtonStyle(emphasis: .quiet))
            .accessibilityElement(children: .contain)
    }
}


private struct RuntimeDiagnosticsSummary: View {
    let store: RuntimeStore
    let navigate: (ControlSection) -> Void
    @State private var managed: Bool?
    var body: some View {
        DetailCard(title: "运行状态") {
            HStack {
                Label("本机服务", systemImage:"desktopcomputer").font(.callout.weight(.medium))
                Spacer(); ConnectionIndicator(ready:store.connected,title:"本机服务")
            }
            Divider()
            HStack {
                Image(systemName:"shield.lefthalf.filled").font(.callout).frame(width:16)
                VStack(alignment:.leading,spacing:5) {
                    Text("自动守护").font(.callout.weight(.medium))
                    Text("后台异常退出后自动重新启动").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                ConnectionIndicator(ready:managed == true && BundledRuntimeOwner.current?.watchdogRunning == true,
                    pending:managed == nil,title:"自动守护",text:managed == nil ? "检查中":managed == true && BundledRuntimeOwner.current?.watchdogRunning == true ? "运行中":"未接管")
            }
            if managed == false && !store.demo {
                Text("系统尚未接管此进程。退出并重新打开 ARL 后会再次尝试接管。").font(.caption).foregroundStyle(.secondary)
            }
            if let snapshot = store.snapshot {
                Divider()
                let counts = snapshot.queue.counts
                let active = (counts["queued"] ?? 0) + (counts["running"] ?? 0)
                let review = counts["needs_review"] ?? 0
                let unlock = counts["needs_unlock"] ?? 0
                HStack {
                    Label("任务队列",systemImage:"rectangle.stack").font(.callout.weight(.medium));Spacer()
                    Text(snapshot.queue.available ? (active == 0 ? "暂无排队或运行任务" : "\(active) 项排队或运行") : "暂时无法读取")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if snapshot.queue.available && (review > 0 || unlock > 0) {
                    RuntimeTaskAttention(service: store.service, reviewCount: review, unlockCount: unlock)
                }
            }
            if store.bundledRuntimeError != nil {
                Text("后台服务异常，正在尝试恢复。").font(.callout).foregroundStyle(.orange)
                if let code = store.bundledRuntimeError {
                    Text(code).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Button(store.bundledRuntimeRecovering ? "正在恢复":"重启后台服务") {
                    store.recoverBundledRuntime(restartAll: true)
                }.disabled(store.bundledRuntimeRecovering || store.nativeActionsHeld)
            }
            if store.controlError != nil {
                Text("暂时无法读取服务状态，将自动重试。").font(.caption).foregroundStyle(.secondary)
            }
        }.task {
            while !Task.isCancelled {
                managed = await Task.detached {ManagedLaunch.supervisingCurrentProcess()}.value
                do {try await Task.sleep(for:.seconds(10))} catch {return}
            }
        }
    }
}

private struct RuntimeTaskAttention: View {
    let service: SettingsService
    let reviewCount: Int
    let unlockCount: Int
    @AppStorage("viewedRuntimeTaskReceipts") private var storedReceipts = ""
    @State private var expanded = false
    @State private var items: [RuntimeTaskAttentionPage.Item] = []
    @State private var total: Int?
    @State private var nextOffset: Int?
    @State private var loadID = UUID()
    @State private var loading = false
    @State private var readFailed = false

    private var expectedCount: Int { reviewCount + unlockCount }
    private var viewed: Set<String> { Set(storedReceipts.split(separator: "\n").map(String.init)) }
    private var unseen: Int? {
        guard !readFailed, total == expectedCount, items.count == expectedCount, nextOffset == nil else { return nil }
        return items.count { !viewed.contains($0.id) }
    }
    private var summary: String {
        if unseen == 0 { return "\(expectedCount) 项已查看" }
        if unlockCount == 0 { return "\(unseen ?? reviewCount) 项待核对" }
        if reviewCount == 0 || unseen == unlockCount { return "\(unlockCount) 项等待解锁" }
        return "\(unseen ?? expectedCount) 项需关注"
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(items) { item in
                    Divider()
                    taskRow(item, seen: viewed.contains(item.id))
                }
                if loading {
                    ProgressView("正在读取任务…").controlSize(.small)
                } else if readFailed {
                    Text("暂时无法读取任务详情。").font(.caption).foregroundStyle(.secondary)
                    Button("重新读取") { Task { await load() } }
                } else if items.isEmpty {
                    Text("当前没有需关注的任务。").font(.caption).foregroundStyle(.secondary)
                } else if let nextOffset {
                    Button("查看更多任务") { Task { await load(offset: nextOffset) } }
                }
            }.padding(.top, 6)
        } label: {
            Label(summary, systemImage: unseen == 0 ? "checkmark.circle" : "exclamationmark.circle")
                .font(.callout.weight(.medium)).foregroundStyle(unseen == 0 ? Color.secondary : Color.orange)
        }
        .accessibilityIdentifier("runtime-task-attention")
        .task(id: [reviewCount, unlockCount, expanded ? 1 : 0]) {
            await load(keepVisiblePages: true)
            while expanded && !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                if !loading { await load(keepVisiblePages: true) }
            }
        }
    }

    private func taskRow(_ item: RuntimeTaskAttentionPage.Item, seen: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title(item.kind)).font(.callout.weight(.semibold))
                Spacer(minLength: 8)
                Text(item.state == .needsUnlock ? "等待解锁" : seen ? "已查看" : "结果待核对")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("\(source(item.source)) · \(Date(timeIntervalSince1970: Double(item.updated_at_ms) / 1000).formatted(date: .abbreviated, time: .shortened))")
                .font(.caption).foregroundStyle(.secondary)
            Text(guidance(item)).font(.callout).fixedSize(horizontal: false, vertical: true)
            if item.state == .needsReview {
                Button(seen ? "撤销已查看" : "标记已查看") {
                    var updated = viewed
                    if seen { updated.remove(item.id) } else { updated.insert(item.id) }
                    storedReceipts = updated.sorted().joined(separator: "\n")
                }.controlSize(.small)
            }
        }
    }

    private func load(offset: Int = 0, keepVisiblePages: Bool = false) async {
        let id = UUID()
        loadID = id; loading = true; readFailed = false
        defer { if loadID == id { loading = false } }
        do {
            var page = try await service.readTaskAttention(offset: offset)
            let reset = offset == 0 || page.total != total
            if reset && offset != 0 { page = try await service.readTaskAttention(offset: 0) }
            let pageTotal = page.total
            var received = page.items
            var receivedIDs = Set(received.map(\.id))
            if reset && keepVisiblePages {
                let previousCount = items.count
                while let cursor = page.next_offset, cursor < previousCount {
                    let next = try await service.readTaskAttention(offset: cursor)
                    guard loadID == id, !Task.isCancelled else { return }
                    guard next.total == pageTotal else {
                        readFailed = true
                        return
                    }
                    received.append(contentsOf: next.items.filter { receivedIDs.insert($0.id).inserted })
                    page = next
                }
            }
            guard loadID == id, !Task.isCancelled else { return }
            let existing = Set(items.map(\.id))
            items = reset ? received : items + received.filter { !existing.contains($0.id) }
            total = page.total; nextOffset = page.next_offset
        } catch {
            guard loadID == id, !Task.isCancelled else { return }
            readFailed = true
        }
    }

    private func title(_ kind: RuntimeTaskAttentionPage.Item.Kind) -> String {
        switch kind {
        case .codex: "Codex 模型任务"
        case .model: "模型任务"
        case .calendar: "日历操作"
        case .reminders: "提醒事项操作"
        case .nas: "NAS 操作"
        case .other: "应用任务"
        }
    }

    private func source(_ source: RuntimeTaskAttentionPage.Item.Source) -> String {
        switch source {
        case .friday: "由 Friday 发起"
        case .tisra: "由 Tisra 发起"
        case .mio: "由 Mio 发起"
        case .arlAcceptance: "ARL 验收记录"
        case .other: "来源应用未标识"
        }
    }

    private func guidance(_ item: RuntimeTaskAttentionPage.Item) -> String {
        if item.state == .needsUnlock { return "解锁这台 Mac 后，回到发起任务的应用继续。" }
        if item.source == .arlAcceptance && item.reason == "codex_scope_unavailable" {
            return "这次验收的 Codex 调用授权中断，后台没有确认完整结果。可以标记已查看。"
        }
        switch item.reason {
        case "codex_scope_unavailable": return "任务使用的 Codex 授权已不可用，请先在发起应用核对结果。"
        case "tool_contract_changed": return "任务使用的能力已有变更，请先在发起应用核对原操作。"
        default: return "后台没有确认原任务的结果，请先在发起应用核对。"
        }
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
            EditorialMenu {
                ForEach(catalog?.models ?? []) { option in
                    Button { controller.selectExecution(option.selecting(from: selection)) } label: {
                        Label(option.display_name, systemImage: option.id == selection?.model ? "checkmark" : "cpu")
                    }
                }
            } label: { Text(model?.display_name ?? selection?.model ?? "未载入").frame(maxWidth: .infinity, alignment: .leading) }
                .frame(width: 220).disabled(!configurable)
                .accessibilityLabel("Codex 模型").accessibilityValue(model?.display_name ?? "未载入")
        }
    }
    private var effortControl: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("思考强度").font(.caption).foregroundStyle(.secondary)
            EditorialMenu {
                ForEach(model?.efforts ?? []) { effort in
                    Button { if var next = selection { next.reasoning_effort = effort.id; controller.selectExecution(next) } } label: {
                        Label(effort.title, systemImage: selection?.reasoning_effort == effort.id ? "checkmark" : "brain")
                    }
                }
            } label: { Text(selection.map { CodexEffortOption.title($0.reasoning_effort) } ?? "未载入").frame(maxWidth: .infinity, alignment: .leading) }
                .frame(width: 140).disabled(!configurable || model == nil)
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
        if let record = store.codex.taskRecord, !record.permitsNewIntent {
            DetailCard(title: "需要核对的模型任务") {
                MetadataRow(title: "任务", value: record.jobID?.uuidString.lowercased() ?? record.operationID.uuidString.lowercased())
                MetadataRow(title: "状态", value: record.phase)
                if let text = record.reply?.text { Text(text).font(.callout).textSelection(.enabled) }
                HStack {
                    Button("查看执行结果") { store.codex.inspectOriginal() }.disabled(!store.codex.canInspect)
                    Button("取消原任务") { store.codex.requestCancel() }
                        .disabled(record.jobID == nil || record.permitsNewIntent)
                }
                if let message = store.codex.message { Text(message).font(.caption).foregroundStyle(.secondary) }
            }
        }
        if let reminders = store.remindersProduct, let task = reminders.task,
           ["attempting","unknown","needs_review"].contains(task.state) {
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
