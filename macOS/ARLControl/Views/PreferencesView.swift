import SwiftUI

struct PreferencesView: View {
    let nasRoutingEnabled: Bool
    let nasChangesAllowed: Bool
    @AppStorage("refreshAutomatically") private var refresh = true
    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: EditorialStyle.sectionSpacing) {
            EditorialHeading(title: "偏好设置", subtitle: "")
            Text("模型与套餐请在主窗口的“模型”页设置。").font(.caption).foregroundStyle(.secondary)
            if nasRoutingEnabled { NASModelRoutingSettings(changesAllowed: nasChangesAllowed) }
            DetailCard(title: "状态更新") {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("自动刷新主窗口状态").font(.callout.weight(.medium))
                        Text("每 5 秒").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    Toggle("自动刷新主窗口状态", isOn: $refresh).labelsHidden().toggleStyle(.switch)
                }
                Divider()
                HStack {
                    Text("手动刷新").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Text("⌘ R").font(.system(.caption, design: .monospaced).weight(.medium))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(EditorialStyle.canvas, in: RoundedRectangle(cornerRadius: 4))
                        .accessibilityLabel("Command R")
                }
            }
        }.padding(24)
        }.frame(width: 610, height: 560)
            .background(EditorialStyle.canvas).tint(EditorialStyle.accent)
    }
}

private struct NASModelRoutingSettings: View {
    let changesAllowed: Bool
    @AppStorage("nasModelControlDirectory") private var controlDirectory = ""
    @State private var monitor = NASModelRoutingMonitor()
    @State private var draft: NASModelPolicy?
    @State private var saved: NASModelPolicy?
    @State private var message: String?
    @State private var saving = false

    private var status: NASModelStatus? { monitor.snapshot.status }

    var body: some View {
        DetailCard(title: "NAS 应用模型通道") {
            if let draft {
                if let status, status.fresh {
                    let usage = status.globalDailyApiRequests.map { "\(status.apiRequests) / \($0)" }
                        ?? String(status.apiRequests)
                    Text("今日 API 用量 \(usage) 次")
                        .font(.callout)
                    if !status.apiConfigured {
                        Text("NAS 尚未配置 OpenAI Key").font(.caption).foregroundStyle(.secondary)
                    }
                }
                limitControls("限制全部应用的每日 API 请求量", Binding(
                    get: { self.draft?.globalDailyApiRequests },
                    set: { self.draft?.globalDailyApiRequests = $0 }
                ), defaultValue: 10)
                ForEach(NASApplication.allCases) { app in
                    if let config = draft.apps[app.id] {
                        Divider()
                        applicationRow(app, config)
                    }
                }
                Text("已启用的上限按北京时间零点重置。设为 0 可暂停 API 调用。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("保存") { save(draft) }
                        .disabled(!changesAllowed || saving || !draft.valid || draft == saved || monitor.snapshot.policy == nil)
                    if let status, status.fresh {
                        Text(status.policyInvalid ? "NAS 保留上次有效配置"
                             : saved?.revision == status.appliedRevision ? "已生效" : "等待 NAS 应用")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("NAS 状态暂不可用").font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else {
                Text(monitor.checked ? "读取路由配置失败，请检查 NAS 挂载与目录。"
                     : "连接路由器的控制目录后，可以为各应用选择通道并设置每日 API 上限。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            Button("选择 NAS 控制目录…") { chooseDirectory() }
        }
        .task(id: controlDirectory) {
            let path = controlDirectory
            if monitor.path != path {
                draft = nil
                saved = nil
                message = nil
            }
            await monitor.monitor(path) { found in
                if controlDirectory == path { controlDirectory = found }
            }
        }
        .onChange(of: monitor.snapshot.policy) { _, policy in
            if let policy, monitor.path == controlDirectory, draft == saved {
                draft = policy
                saved = policy
            }
        }
    }

    private func applicationRow(_ app: NASApplication, _ config: NASModelPolicy.Application) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(app.name).font(.callout.weight(.semibold))
            NASModelRoutePicker(route: binding(app.id, \.mode, config.mode))
            if config.mode != .codex {
                TextField("OpenAI 模型", text: binding(app.id, \.apiModel, config.apiModel))
                limitControls("限制每日 API 请求量", binding(app.id, \.dailyApiRequests, config.dailyApiRequests),
                              defaultValue: 1)
            }
            if let status, status.fresh, let activity = status.apps[app.id] {
                Text("今日 API \(activity.apiRequests) 次 · Codex \(activity.codexReady ? "可用" : "暂不可用")")
                    .font(.caption).foregroundStyle(.secondary)
                if let provider = activity.lastProviderTitle {
                    Text("最近请求 · \(provider)\(activity.lastReason == "daily_api_limit" ? " · API 达到日上限" : "")")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func limitControls(_ title: String, _ limit: Binding<Int?>, defaultValue: Int) -> some View {
        Toggle(title, isOn: Binding(get: { limit.wrappedValue != nil },
                                    set: { limit.wrappedValue = $0 ? (limit.wrappedValue ?? defaultValue) : nil }))
        if limit.wrappedValue != nil {
            TextField("每日 API 请求上限", value: Binding(get: { limit.wrappedValue ?? defaultValue },
                                                         set: { limit.wrappedValue = $0 }), format: .number)
        }
    }

    private func binding<Value>(_ app: String, _ field: WritableKeyPath<NASModelPolicy.Application, Value>, _ fallback: Value) -> Binding<Value> {
        Binding(get: { draft?.apps[app]?[keyPath: field] ?? fallback },
                set: { draft?.apps[app]?[keyPath: field] = $0 })
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "连接"
        if panel.runModal() == .OK, let url = panel.url {
            controlDirectory = url.path
        }
    }

    private func save(_ policy: NASModelPolicy) {
        guard changesAllowed else { return }
        saving = true
        message = nil
        let path = controlDirectory
        Task {
            defer { saving = false }
            do {
                let applied = try await monitor.save(policy, in: path)
                guard controlDirectory == path else { return }
                draft = applied
                saved = applied
            } catch NASModelSettingsFile.Failure.changed {
                guard controlDirectory == path else { return }
                message = "配置已在别处更新，请重新打开偏好设置后再保存。"
            } catch {
                guard controlDirectory == path else { return }
                message = "写入路由配置失败，请检查 NAS 挂载和权限。"
            }
        }
    }
}

struct NASModelRoutePicker: View {
    @Binding var route: NASModelRoute

    var body: some View {
        Picker("模型通道", selection: $route) {
            ForEach(NASModelRoute.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .pickerStyle(.menu)
    }
}

struct StatusMenu: View {
    let store: RuntimeStore
    let bindWindow: (OpenWindowAction) -> Void
    let presentWindow: () -> Void
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text(store.demo ? "ARL · 演示" : "ARL · \(store.title)")
        if let snapshot = store.snapshot, snapshot.outstanding > 0 { Text("待处理 \(snapshot.outstanding)") }
        Divider()
        Button("打开 ARL") {
            bindWindow(openWindow)
            presentWindow()
        }
        Button("刷新状态") { Task { await store.refresh() } }.keyboardShortcut("r")
        SettingsLink { Text("偏好设置") }
        Divider()
        Button("退出 ARL") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
    }
}

