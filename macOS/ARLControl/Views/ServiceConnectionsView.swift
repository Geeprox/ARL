import SwiftUI
import ARLCredentialOnboarding
import ARLCredentialHostCore

struct ServiceConnectionsView: View {
    let store: RuntimeStore
    let navigate: (ControlSection) -> Void
    @State private var destination: String
    @SceneStorage("serviceConnections.destination") private var savedDestination = "日历"
    @SceneStorage("serviceConnections.category") private var legacyCategory = ""
    let initialDestination: String?
    let nasSetup: ARLNASSetupModel?
    init(store: RuntimeStore, navigate: @escaping (ControlSection) -> Void, initialDestination: String? = nil, nasSetup: ARLNASSetupModel? = nil) {
        self.store = store
        self.navigate = navigate
        self.initialDestination = initialDestination
        self.nasSetup = nasSetup
        _destination = State(initialValue: initialDestination ?? "日历")
    }
    private let destinations = ["日历", "提醒事项", "备忘录", "网络硬盘", "信息", "其他服务"]
    private var bootstrap: CredentialHostBootstrap { store.credentialBootstrap }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                EditorialHeading(title: "服务连接", subtitle: "")
                ScrollView(.horizontal) {
                    HStack(spacing: 4) {
                        ForEach(destinations, id: \.self) { name in
                            Button { destination = name } label: {
                                Text(name).font(.system(size: 13, weight: destination == name ? .semibold : .regular))
                                    .padding(.horizontal, 13).frame(height: 34)
                            }.buttonStyle(ConnectionDestinationStyle(selected: destination == name))
                                .accessibilityAddTraits(destination == name ? .isSelected : [])
                        }
                    }.padding(3)
                }.scrollIndicators(.hidden).fixedSize(horizontal: false, vertical: true)
                Divider()
                connectionDetails.frame(maxWidth: 700, alignment: .leading)
            }.padding(28).frame(maxWidth: 1100, alignment: .leading).frame(maxWidth: .infinity)
                .buttonStyle(EditorialActionButtonStyle()).textFieldStyle(EditorialFieldStyle())
                .groupBoxStyle(EditorialGroupBoxStyle()).tint(EditorialStyle.accent)
        }
        .onAppear {
            if initialDestination == nil, destinations.contains(savedDestination) { destination = savedDestination }
            if legacyCategory == "硬盘" { destination = "网络硬盘"; legacyCategory = "" }
            if !destinations.contains(destination) { destination = "日历" }
        }
        .onChange(of: destination) { savedDestination = destination }
    }
    @ViewBuilder private var connectionDetails: some View {
        switch destination {
        case "网络硬盘": TaskNASConnectionView(model: nasSetup ?? store.nasSettings, preview: store.demo)
        case "备忘录": TaskNotesConnectionView(controller: store.notesDirect)
        case "提醒事项": reminders
        case "信息": messages
        case "其他服务": otherServices
        default: calendar
        }
    }
    private var calendar: some View {
        let permission = store.calendarPermission
        return VStack(alignment: .leading, spacing: 20) {
            Text(calendarTitle).font(.system(size: 17, weight: .semibold))
            Group {
                if permission.busy { ProgressView("等待系统授权").controlSize(.small) }
                else if permission.lastProbeFailed {
                    Button("重试") { permission.refresh() }.disabled(!permission.canAct)
                } else if permission.state == .notDetermined || permission.state == .writeOnly {
                    Button("允许查看与编辑日历") { Task { await permission.requestFullAccess() } }
                        .buttonStyle(EditorialActionButtonStyle(emphasis: .primary))
                        .disabled(!permission.canAct || store.demo || store.nativeActionsHeld)
                } else if permission.state == .denied || permission.state == .restricted {
                    Link("在系统设置中核对", destination: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
                } else if permission.state == .unknown {
                    Button("检查日历权限") { permission.refresh() }.disabled(!permission.canAct)
                }
                if let message = permission.message { Text(message).font(.caption).foregroundStyle(.secondary) }
            }
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 10) {
                    if permission.lastProbeFailed { Text("权限更新失败") }
                    if let at = permission.observedAt { Text(at, format: .dateTime.month().day().hour().minute()) }
                    Button("刷新权限") { permission.refresh() }.disabled(!permission.canAct)
                    if let diagnostic = permission.requestDiagnostic { Text(diagnostic).textSelection(.enabled) }

                }.font(.caption).foregroundStyle(.secondary).padding(.top, 10)
            }.font(.caption)
        }
    }
    private var calendarTitle: String {
        let p = store.calendarPermission
        if p.lastProbeFailed { return "权限更新失败" }
        switch p.state {
        case .notDetermined: return "待授权"
        case .writeOnly: return "仅允许添加日程"
        case .fullAccess: return "已允许查看与编辑"
        case .denied: return "日历访问已关闭"
        case .restricted: return "系统限制访问"
        case .disabled: return store.demo ? "演示模式" : "日历未启用"
        case .unknown: return "权限待检查"
        }
    }
    private var reminders: some View {
        let value = store.remindersFirst.value
        let authorized = value?.fresh == true && value?.permission_state == "authorized_full"
        return VStack(alignment: .leading, spacing: 20) {
            Text(authorized ? "已授权" : "提醒事项访问").font(.system(size: 17, weight: .semibold))
            Group {
                if store.remindersRestoring || store.permissionBusy { ProgressView("正在处理").controlSize(.small) }
                else if !authorized, value?.fresh == true && value?.permission_state == "not_determined" {
                    Button("允许提醒事项访问") { store.performRemindersFirst(.request) }
                        .disabled(!store.canInspectReminders || store.demo || store.nativeActionsHeld)
                        .buttonStyle(EditorialActionButtonStyle(emphasis: .primary))
                } else if !authorized, ["denied", "restricted"].contains(value?.permission_state ?? "") {
                    Link("在系统设置中核对", destination: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders")!)
                } else if !authorized {
                    Button("连接提醒事项") { store.restoreRemindersConnection() }
                        .disabled(store.demo || store.nativeActionsHeld).buttonStyle(EditorialActionButtonStyle(emphasis: .primary))
                }
                if let message = store.remindersStatusFailure ?? store.remindersMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
            }
            if authorized, let controller = store.remindersProduct { RemindersDefaultListSettings(controller: controller, disabled: store.nativeActionsHeld || store.demo) }
        }
    }
    private var otherServices: some View {
        VStack(alignment: .leading, spacing: 20) {
            if !bootstrap.configured {
                Text("安全存储未连接").font(.callout).foregroundStyle(.secondary)
            }
            if let catalog = ServiceConnectionCatalog.load() {
                ForEach(catalog.services.filter { $0.id != "codex" }, id: \.id) { entry in
                    if entry.configuration == "native_credentials", let raw = entry.credential_purpose,
                       let purpose = ARLCredentialOnboarding.CredentialPurpose(rawValue: raw) {
                        CredentialConnectionPanel(purpose: purpose, onboarding: bootstrap.service)
                    }
                }
            } else { Text("服务列表不可用").font(.callout).foregroundStyle(.secondary) }
            DisclosureGroup("连接诊断") {
                VStack(alignment: .leading, spacing: 10) {
                    Text(store.credentialOwnerStatus.title)
                    Text(store.credentialOwnerStatus.detail)
                    if let message = store.credentialOwnerMessage { Text(message) }
                    if store.credentialOwnerStatus.canRequestRecovery {
                        Button(store.credentialOwnerRecovering ? "核对中" : "恢复连接") { store.recoverCredentialOwner() }.disabled(!store.canRecoverCredentialOwner)
                    } else { Button("检查连接") { store.observeCredentialOwner() } }
                }.font(.caption).foregroundStyle(.secondary).padding(.top, 10)
            }
        }.onAppear { store.observeCredentialOwner() }
    }
    private var messages: some View {
        let controller = store.messagesDirect
        return AppleConnectionActionsView(target: .messages, permission: controller.permission,
            enabled: controller.enabled, busy: controller.busy, observation: controller.connection.state,
            check: { Task { await controller.prepareForDisplay() } },
            request: { if let ticket = controller.ticket() { Task { await controller.checkPermission(ticket: ticket, request: true) } } })
            .task { controller.appear(); await controller.prepareForDisplay() }
            .onDisappear { controller.disappear() }
    }

}

private struct ConnectionDestinationStyle: ButtonStyle {
    let selected: Bool
    @Environment(\.isFocused) private var focused
    @State private var hovered = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.foregroundStyle(EditorialStyle.graphite)
            .background(selected ? EditorialStyle.panel : hovered || configuration.isPressed ? Color.primary.opacity(0.035) : .clear, in: RoundedRectangle(cornerRadius: 7))
            .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(focused ? EditorialStyle.accent : .clear, lineWidth: 2) }
            .onHover { hovered = $0 }
    }
}

private struct TaskNotesConnectionView: View {
    let controller: NotesDirectController
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            AppleConnectionActionsView(target: .notes, permission: controller.permission, enabled: controller.enabled,
                busy: controller.busy, observation: controller.connection.state,
                check: { Task { await controller.prepareForDisplay() } }, request: request)
            if controller.permission == .authorized {
                VStack(alignment: .leading, spacing: 10) {
                    Text("默认文件夹").font(.callout.weight(.medium))
                    if !controller.folders.isEmpty {
                        Menu {
                            ForEach(controller.folders) { folder in
                                Button(folder.label) {
                                    if let ticket = controller.ticket() { Task { await controller.select(folder, ticket: ticket) } }
                                }
                            }
                        } label: { Text(controller.scope?.folder.label ?? "选择文件夹") }
                            .modifier(EditorialMenuSurface()).frame(maxWidth: 360, alignment: .leading)
                            .disabled(controller.busy)
                    } else {
                        if let folder = controller.scope?.folder { Text(folder.label).font(.callout).foregroundStyle(.secondary) }
                    }
                    Button(controller.folders.isEmpty ? "选择文件夹" : "刷新文件夹") {
                        if let ticket = controller.ticket() { Task { await controller.loadFolders(ticket: ticket) } }
                    }.disabled(controller.busy)
                    if let detail = controller.detail { Text(detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                }
            }
        }.task { controller.appear(); await controller.prepareForDisplay() }
            .onDisappear { controller.disappear() }
    }
    private func request() {
        if let ticket = controller.ticket() {
            Task { await controller.checkPermission(ticket: ticket, request: true); await controller.prepareForDisplay() }
        }
    }
}

private struct TaskNASConnectionView: View {
    @ObservedObject var model: ARLNASSetupModel
    var preview = false
    @StateObject private var discovery = NASDiscoveryModel()
    @State private var account = ""
    @State private var secret = ""
    @State private var action: Task<Void, Never>?
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if !preview { NASDiscoverySection(discovery: discovery, setup: model) }
            if let owner = model.serverSetupOwner {
                NASServerSetupSections(owner: owner, setup: model)
            } else {
                legacyConfiguration
            }
        }.frame(maxWidth: 600, alignment: .leading)
            .onAppear { model.refreshCachedStatus() }
            .onChange(of: model.draft) { clearCredentialFields(); model.invalidateDirectories() }
            .onDisappear { clearCredentialFields(); discovery.cancel(); model.invalidateDirectories() }
    }
    private var legacyConfiguration: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("设备与访问范围").font(.system(size: 17, weight: .semibold))
            field("设备地址", text: $model.draft.address)
            field("共享目录", text: $model.draft.share)
            field("目录范围", text: $model.draft.root)
            HStack {
                Text("访问方式").frame(width: 90, alignment: .leading)
                Menu {
                    Button("只读访问") { model.draft.applicationScope = .readOnly }
                    Button("申请读写") { model.draft.applicationScope = .readWriteRequested }
                } label: { Text(model.draft.applicationScope == .readOnly ? "只读访问" : "申请读写") }
                    .modifier(EditorialMenuSurface()).frame(width: 180, alignment: .leading).disabled(model.isPerforming)
            }.font(.callout)
            HStack {
                Text("连接端口").frame(width: 90, alignment: .leading)
                TextField("连接端口", value: $model.draft.port, format: .number).labelsHidden().frame(width: 110)
                Spacer(minLength: 0)
            }.font(.callout)
            Stepper("连接时限：\(model.draft.connectionTimeoutSeconds) 秒", value: $model.draft.connectionTimeoutSeconds, in: 1...30)
                .font(.callout)
            Button("保存设置") { perform(.saveConfiguration) }.disabled(!model.admission(for: .saveConfiguration).isAllowed)
            Divider()
            Text("登录信息").font(.callout.weight(.semibold))
            field("账号", text: $account).privacySensitive().disabled(!model.canEditCredentialFields)
            HStack {
                Text("密码").frame(width: 90, alignment: .leading)
                SecureField("密码", text: $secret).labelsHidden().privacySensitive().disabled(!model.canEditCredentialFields)
            }
            Button("保存登录") {
                guard let intent = model.beginManualActionAfterClick(.saveCredential) else { return }
                let input = ARLNASCredentialInput(username: account, password: secret)
                clearCredentialFields()
                action = Task {
                    defer { input.clear() }
                    await model.saveCredentialAfterClick(input, manualIntent: intent)
                }
            }.disabled(!model.admission(for: .saveCredential).isAllowed || account.isEmpty || secret.isEmpty)
            Divider()
            HStack {
                Button("连接目录") { perform(.testConnection) }.disabled(!model.admission(for: .testConnection).isAllowed)
                Button("重新连接") { perform(.reconnect) }.disabled(!model.admission(for: .reconnect).isAllowed)
                Button("断开") { perform(.stop) }.disabled(!model.admission(for: .stop).isAllowed)
            }
            if model.isPerforming { ProgressView("正在处理").controlSize(.small) }
            if let fault = model.lastFault { Text(faultTitle(fault)).font(.caption).foregroundStyle(.secondary) }
            else if model.snapshot.provider == .unsupported { Text("硬盘服务未连接").font(.caption).foregroundStyle(.secondary) }
        }
    }
    private func field(_ title: String, text: Binding<String>) -> some View {
        HStack {
            Text(title).frame(width: 90, alignment: .leading)
            TextField(title, text: text).labelsHidden().disabled(model.isPerforming)
        }.font(.callout)
    }
    private func perform(_ kind: ARLNASManualAction) {
        if kind == .stop { action?.cancel() }
        guard let intent = model.beginManualActionAfterClick(kind) else { return }
        action = Task { await model.performAfterClick(intent) }
    }
    private func faultTitle(_ fault: ARLNASFault) -> String {
        switch fault {
        case .authenticationFailed, .credentialInvalid: "登录失败，请核对账号和密码。"
        case .connectionFailed, .transportTimeout, .transportFailed: "连接失败，请核对地址与网络。"
        case .accessDenied, .readDenied: "访问被拒，请核对目录授权。"
        case .configurationNotSaved: "请先保存当前设置。"
        case .credentialNotSaved: "请先保存登录信息。"
        case .configurationChanged, .staleGeneration, .sourceChanged: "设置已变化，请重新连接。"
        case .writeOutcomeUncertain: "原操作结果待核。"
        case .hostNotConfigured: "硬盘服务未连接。"
        case .userCancelled: "操作已取消。"
        default: "连接未完成（" + fault.rawValue + "）。"
        }
    }
    private func clearCredentialFields() { account = ""; secret = "" }
}
