import SwiftUI

struct ApplicationConnectionsView: View {
    let registry: [AppRegistration]?
    let nasEnabled: Bool
    let nasChangesAllowed: Bool
    @AppStorage("nasModelControlDirectory") private var controlDirectory = ""
    @State private var monitor = NASModelRoutingMonitor()
    @State private var selectedApp: Selection?
    @State private var friday: FridayModelUsage?
    @State private var fridayAvailable = false
    @State private var fridayGeneration = UUID()
    @State private var naming: NamingConnection?
    @State private var fridaySaving = false

    private enum Selection: Identifiable {
        case nas(NASApplication), friday, naming

        var id: String {
            switch self {
            case .nas(let app): app.id
            case .friday: "friday"
            case .naming: "baby-naming"
            }
        }
    }

    private struct NamingConnection {
        let path: String
        let online: Bool
        let usage: NamingModelUsage?
    }

    private var applications: [NASApplication] {
        nasEnabled && monitor.path == controlDirectory ? monitor.applications : []
    }
    private var namingConnection: NamingConnection? {
        naming?.path == controlDirectory ? naming : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("应用连接").font(.system(size: 15, weight: .semibold)).accessibilityAddTraits(.isHeader)
            TimelineView(.periodic(from: .now, by: 3)) { timeline in
                let connected = AppRegistration.connected(registry ?? [], at: timeline.date)
                let fridayRegistration = nasEnabled ? connected.first { $0.id == FridayModelUsage.appID } : nil
                if connected.isEmpty && applications.isEmpty && !fridayAvailable && namingConnection == nil {
                    Text(registry == nil ? "尚未检查应用连接" : "暂无已连接应用")
                        .foregroundStyle(.secondary).font(.callout)
                }
                VStack(spacing: 3) {
                    if fridayRegistration != nil || fridayAvailable {
                        fridayRow(fridayRegistration)
                    }
                    ForEach(connected.filter { !nasEnabled || $0.id != FridayModelUsage.appID }) { app in
                        HStack(spacing: 12) {
                            AppIcon(id: app.id, symbol: app.symbol, registeredIcon: app.applicationIcon,
                                    iconHome: app.applicationIconHome, protocolIcon: true)
                            Text(app.name).font(.callout.weight(.medium))
                            Spacer()
                            ConnectionIndicator(ready: true, title: app.name).padding(.trailing, 22)
                        }.padding(.horizontal, 8).frame(minHeight: 52)
                    }
                    ForEach(applications) { app in
                        let connection = monitor.snapshot.connection(for: app, at: timeline.date)
                        applicationRow(app.name, id: "nas-application-" + app.id,
                                       status: connection.state.title, ready: connection.state == .connected,
                                       route: connection.route?.title ?? "通道未确认", selection: .nas(app)) {
                            AppIcon(id: app.id, symbol: app.symbol, protocolIcon: true)
                        }
                    }
                    if let namingConnection {
                        applicationRow(NamingModelUsage.title, id: "nas-application-baby-naming",
                                       status: namingConnection.online ? "NAS 服务在线" : "NAS 状态暂不可用",
                                       ready: namingConnection.online,
                                       route: namingConnection.online ? "OpenAI API" : "通道未确认", selection: .naming) {
                            AppIcon(id: "baby-naming", symbol: "character.book.closed", protocolIcon: true)
                        }
                    }
                }
                if nasEnabled, controlDirectory == monitor.path, monitor.checked, applications.isEmpty {
                    Text("NAS 应用状态暂不可用").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .task(id: controlDirectory) {
            guard nasEnabled else { return }
            let path = controlDirectory
            await monitor.monitor(path) { found in
                if controlDirectory == path { controlDirectory = found }
            }
        }
        .task {
            guard nasEnabled else { return }
            while !Task.isCancelled {
                if !fridaySaving {
                    let generation = fridayGeneration
                    let value = try? await FridayModelUsage.read()
                    guard !Task.isCancelled else { return }
                    if !fridaySaving && generation == fridayGeneration {
                        fridayAvailable = value != nil
                        if let value { friday = value }
                    }
                }
                try? await Task.sleep(for: .seconds(5))
            }
        }
        .task(id: controlDirectory) {
            guard nasEnabled, !controlDirectory.isEmpty else { return }
            let path = controlDirectory
            guard let database = NamingModelUsage.database(for: path) else { return }
            while !Task.isCancelled {
                async let online = NamingModelUsage.online()
                let usage = try? await Task.detached { try NamingModelUsage.read(database: database) }.value
                let ready = await online
                guard !Task.isCancelled, controlDirectory == path else { return }
                if ready || usage != nil || namingConnection != nil {
                    naming = NamingConnection(path: path, online: ready, usage: usage)
                }
                try? await Task.sleep(for: .seconds(15))
            }
        }
        .sheet(item: $selectedApp) { app in
            switch app {
            case .nas(let application):
                NASApplicationChannelSheet(app: application, monitor: monitor, changesAllowed: nasChangesAllowed)
                    .id(controlDirectory)
            case .friday:
                FridayApplicationSheet(usage: $friday, available: $fridayAvailable, generation: $fridayGeneration,
                                       saving: $fridaySaving, changesAllowed: nasChangesAllowed)
            case .naming:
                NamingApplicationSheet(online: namingConnection?.online == true, usage: namingConnection?.usage)
            }
        }
    }

    private func fridayRow(_ registration: AppRegistration?) -> some View {
        applicationRow("Friday", id: "friday-application",
                       status: registration == nil ? "本机模型服务在线 · ARL 未连接" : "ARL 已连接",
                       ready: true, route: fridayAvailable ? friday?.routeTitle ?? "通道未确认" : "通道未确认",
                       selection: .friday) {
            AppIcon(id: FridayModelUsage.appID, symbol: registration?.symbol ?? "house",
                    registeredIcon: registration?.applicationIcon, iconHome: registration?.applicationIconHome,
                    protocolIcon: true)
        }
    }

    private func applicationRow<Icon: View>(_ title: String, id: String, status: String, ready: Bool, route: String,
                                            selection: Selection, @ViewBuilder icon: () -> Icon) -> some View {
        Button { selectedApp = selection } label: {
            HStack(spacing: 12) {
                icon()
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.callout.weight(.medium)).foregroundStyle(EditorialStyle.graphite)
                    ConnectionIndicator(ready:ready,title:title,inactive:!ready,text:status)
                }
                Spacer(minLength: 12)
                Text(route).font(.callout).foregroundStyle(.secondary)
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary).accessibilityHidden(true)
            }.padding(.horizontal, 8).frame(minHeight: 52).contentShape(Rectangle())
        }
        .buttonStyle(EditorialDestinationButtonStyle())
        .accessibilityLabel(title)
        .accessibilityValue("\(status)，\(route)")
        .accessibilityIdentifier(id)
    }
}

private struct NASApplicationChannelSheet: View {
    let app: NASApplication
    let monitor: NASModelRoutingMonitor
    let changesAllowed: Bool
    @Environment(\.dismiss) private var dismiss
    @AppStorage("nasModelControlDirectory") private var controlDirectory = ""
    @State private var editedRoute: NASModelRoute?
    @State private var editRevision: String?
    @State private var savedRevision: String?
    @State private var saving = false
    @State private var message: String?

    private var policy: NASModelPolicy? {
        monitor.path == controlDirectory ? monitor.snapshot.policy : nil
    }
    private var configuredRoute: NASModelRoute? { policy?.apps[app.id]?.mode }
    private var route: Binding<NASModelRoute> {
        Binding {
            editedRoute ?? configuredRoute ?? .codex
        } set: { value in
            if editedRoute == nil { editRevision = policy?.revision }
            editedRoute = value
            savedRevision = nil
            message = nil
        }
    }
    private var canSave: Bool {
        !saving && changesAllowed && editedRoute != nil && configuredRoute != nil && editedRoute != configuredRoute
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 3)) { timeline in
            let connection = monitor.path == controlDirectory
                ? monitor.snapshot.connection(for: app, at: timeline.date)
                : NASModelConnection(state: .unavailable)
            VStack(alignment: .leading, spacing: 18) {
                ApplicationSheetHeading(id: app.id, title: app.name, symbol: app.symbol, status: connection.state.title)
                Divider()
                VStack(alignment: .leading, spacing: 9) {
                    MetadataRow(title: "当前通道", value: connection.route?.title ?? "未确认")
                    if let status = monitor.snapshot.status, monitor.path == controlDirectory, status.isFresh(at: timeline.date),
                       let activity = status.apps[app.id] {
                        MetadataRow(title: "今日 API 请求", value: "\(activity.apiRequests.formatted()) 次")
                        MetadataRow(title: "今日已报告 API Token", value: activity.reportedTokens.formatted())
                        let appLimit = activity.dailyApiRequests
                        let globalLimit = status.globalDailyApiRequests
                        MetadataRow(title: "每日 API 请求上限", value: appLimit == nil && globalLimit == nil ? "已关闭"
                                    : "应用 \(usageLimit(appLimit)) · 全局 \(usageLimit(globalLimit))")
                        if let recent = activity.recentRequest { MetadataRow(title: "最近请求", value: recent) }
                        if let reason = activity.fallbackReason { MetadataRow(title: "最近路由原因", value: reason) }
                    } else {
                        Text("今日用量暂不可用").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if configuredRoute != nil {
                    NASModelRoutePicker(route: route).disabled(saving || !changesAllowed)
                        .accessibilityIdentifier("nas-application-channel-picker")
                } else {
                    Text("路由配置暂不可读").font(.caption).foregroundStyle(.secondary)
                }
                if let feedback = message ?? acknowledgement(at: timeline.date) {
                    Text(feedback).font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
                    Button(saving ? "正在保存" : "保存") { save() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canSave)
                }
            }.padding(24).frame(width: 450).tint(EditorialStyle.accent)
        }
    }

    private func acknowledgement(at date: Date) -> String? {
        guard let savedRevision else { return nil }
        if let policy, policy.revision != savedRevision { return "配置已更新" }
        if let status = monitor.snapshot.status, status.isFresh(at: date) {
            if status.policyInvalid { return "NAS 保留上次有效配置" }
            if status.appliedRevision == savedRevision { return "已生效" }
        }
        return "已保存，等待 NAS 应用"
    }

    private func save() {
        guard canSave, let policy, let editedRoute else { return }
        guard policy.revision == editRevision else {
            self.editedRoute = nil
            editRevision = nil
            message = "配置已更新，请重新选择通道。"
            return
        }
        var draft = policy
        draft.apps[app.id]?.mode = editedRoute
        let path = controlDirectory
        saving = true
        message = nil
        Task {
            defer { saving = false }
            do {
                let saved = try await monitor.save(draft, in: path)
                self.editedRoute = nil
                editRevision = nil
                savedRevision = saved.revision
            } catch NASModelSettingsFile.Failure.changed {
                self.editedRoute = nil
                editRevision = nil
                message = "配置已更新，请重新选择通道。"
            } catch {
                message = "写入失败，请检查 NAS 挂载和权限。"
            }
        }
    }
}

private struct ApplicationSheetHeading: View {
    let id: String
    let title: String
    let symbol: String
    let status: String

    var body: some View {
        HStack(spacing: 12) {
            AppIcon(id: id, symbol: symbol, protocolIcon: true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private func usageLimit(_ count: Int?) -> String {
    count.map { "\($0.formatted()) 次" } ?? "已关闭"
}

private struct NamingApplicationSheet: View {
    let online: Bool
    let usage: NamingModelUsage?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ApplicationSheetHeading(id: "baby-naming", title: NamingModelUsage.title, symbol: "character.book.closed",
                                    status: online ? "NAS 服务在线" : "NAS 状态暂不可用")
            Divider()
            VStack(alignment: .leading, spacing: 9) {
                MetadataRow(title: online ? "当前通道" : "配置通道", value: "OpenAI API · Responses")
                if let usage {
                    MetadataRow(title: "今日 API 请求", value: "\(usage.requests.formatted()) 次")
                    MetadataRow(title: "今日成功请求", value: "\(usage.successfulRequests.formatted()) 次")
                    MetadataRow(title: "今日已报告 API Token", value: usage.tokens.formatted())
                    if let model = usage.lastModel {
                        MetadataRow(title: "最近成功模型", value: usage.lastTier.map { model + " · " + $0 } ?? model)
                    }
                } else {
                    Text("今日用量暂不可用").font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Link("打开起名工作台", destination: NamingModelUsage.portal)
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }.padding(24).frame(width: 450).tint(EditorialStyle.accent)
    }
}

private struct FridayApplicationSheet: View {
    @Binding var usage: FridayModelUsage?
    @Binding var available: Bool
    @Binding var generation: UUID
    @Binding var saving: Bool
    let changesAllowed: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var draft: FridayModelUsage.Mode?
    @State private var editBase: FridayModelUsage?
    @State private var feedback: String?
    @State private var awaitingReadback = false

    private var readyToSave: Bool {
        guard changesAllowed, available, !saving, let usage, let draft else { return false }
        let needsAPI = draft == .auto || draft == .openai
        return !usage.matches(draft) && (!needsAPI || usage.apiKeyConfigured)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ApplicationSheetHeading(id: "friday", title: "Friday", symbol: "house",
                                    status: available ? "本机模型服务在线" : "本机模型服务暂不可用")
            Divider()
            if let usage, let mode = usage.mode {
                let used = usage.usage.used
                let limits = usage.usage.limits
                VStack(alignment: .leading, spacing: 9) {
                    MetadataRow(title: available ? "当前通道" : "上次配置通道", value: usage.routeTitle)
                    MetadataRow(title: "今日 API 请求", value: "\(used.requests.formatted()) / \(limits.requests.formatted()) 次")
                    MetadataRow(title: "今日文本 Token", value: "\(used.textTokens.formatted()) / \(limits.textTokens.formatted())")
                    if used.images > 0 || used.voiceSeconds > 0 {
                        MetadataRow(title: "今日图片与语音", value: "\(used.images.formatted()) 张 · \(used.voiceSeconds.formatted()) 秒")
                    }
                    if usage.usage.uncertainRequests > 0 {
                        MetadataRow(title: "待核对的 API 请求", value: "\(usage.usage.uncertainRequests.formatted()) 次")
                    }
                    if let last = usage.recentRequest { MetadataRow(title: "最近请求", value: last) }
                }
                Picker("文字通道", selection: Binding(get: { draft ?? mode }, set: {
                    if draft == nil { editBase = usage }
                    draft = $0
                    feedback = nil
                    awaitingReadback = false
                })) {
                    ForEach(FridayModelUsage.Mode.allCases) { mode in
                        Text(mode.title).tag(mode)
                            .disabled(mode != usage.mode && (mode == .auto || mode == .openai) && !usage.apiKeyConfigured)
                    }
                }.pickerStyle(.menu).disabled(!changesAllowed || !available || saving)
                if !available { Text("显示上次读取的用量。连接恢复后会自动更新。").font(.caption).foregroundStyle(.secondary) }
                if !usage.apiKeyConfigured {
                    Text("在 Friday 的「智能服务」中配置 OpenAI Key 后，可切换到 API。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let feedback { Text(feedback).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
                Button(saving ? "正在保存" : "保存", action: save).keyboardShortcut(.defaultAction).disabled(!readyToSave)
            }
        }.padding(24).frame(width: 450).tint(EditorialStyle.accent)
            .onChange(of: available) { _, _ in reconcileReadback() }
            .onChange(of: usage?.config) { _, _ in reconcileReadback() }
    }

    private func save() {
        guard readyToSave, let draft, let editBase else { return }
        saving = true
        generation = UUID()
        awaitingReadback = false
        Task {
            defer { saving = false }
            do {
                usage = try await FridayModelUsage.save(draft, expected: editBase)
                finishSave()
            } catch {
                let latest = try? await FridayModelUsage.read()
                available = latest != nil
                if let latest { usage = latest }
                feedback = "暂未确认保存。已保留你的选择。"
                awaitingReadback = true
                reconcileReadback()
            }
        }
    }

    private func reconcileReadback() {
        guard awaitingReadback, available, let usage, let draft else { return }
        if usage.matches(draft) { finishSave() }
        else { editBase = usage }
    }

    private func finishSave() {
        draft = nil
        editBase = nil
        awaitingReadback = false
        feedback = "已生效"
    }
}
