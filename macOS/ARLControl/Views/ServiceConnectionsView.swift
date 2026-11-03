import SwiftUI
import ARLCredentialOnboarding
import ARLCredentialHostCore

struct ServiceConnectionsView: View {
    let store: RuntimeStore
    let navigate: (ControlSection) -> Void
    let initialDestination: String?
    let nasSetup: ARLNASSetupModel?
    init(store: RuntimeStore, navigate: @escaping (ControlSection) -> Void, initialDestination: String? = nil, nasSetup: ARLNASSetupModel? = nil) {
        self.store = store
        self.navigate = navigate
        self.initialDestination = initialDestination
        self.nasSetup = nasSetup
    }
    private var bootstrap: CredentialHostBootstrap { store.credentialBootstrap }
    var body: some View {
        ScrollViewReader {proxy in ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                EditorialHeading(title: "服务连接", subtitle: "")
                    .padding(.bottom,8)
                connectionCard("日历",icon:"calendar",symbol:"calendar") {
                    ConnectionIndicator(ready:calendarReady,pending:store.calendarPermission.busy,title:"日历",text:calendarReady ? "已连接":nil)
                } content: {
                    if !calendarReady {calendar}
                }
                connectionCard("提醒事项",icon:"reminders",symbol:"checklist") {
                    ConnectionIndicator(ready:store.remindersFirst.value?.fresh == true && store.remindersFirst.value?.permission_state == "authorized_full",pending:store.remindersRestoring,title:"提醒事项")
                } content: { reminders }
                connectionCard("备忘录",icon:"notes",symbol:"note.text") {
                    appleStatus("备忘录",permission:store.notesDirect.permission,observation:store.notesDirect.connection.state)
                } content: { TaskNotesConnectionView(controller:store.notesDirect) }
                connectionCard("信息",icon:"messages",symbol:"message") {
                    appleStatus("信息",permission:store.messagesDirect.permission,observation:store.messagesDirect.connection.state)
                } content: { messages }
                DetailCard(title:"") {
                    HStack(spacing:12) {
                        Image(systemName:"externaldrive.connected.to.line.below").font(.title2).frame(width:32,height:32).foregroundStyle(.secondary)
                        Text("网络硬盘").font(.headline);Spacer()
                        ConnectionIndicator(ready:(nasSetup ?? store.nasSettings).snapshot.connected == .verified,pending:(nasSetup ?? store.nasSettings).isPerforming,title:"网络硬盘")
                    }
                    TaskNASConnectionView(model:nasSetup ?? store.nasSettings,preview:store.demo)
                }.id("网络硬盘")
                DisclosureGroup("其他服务") { otherServices.padding(.top,12) }.padding(.horizontal,4)
            }.padding(24).frame(maxWidth: 880, alignment: .leading).frame(maxWidth: .infinity)
                .buttonStyle(EditorialActionButtonStyle()).textFieldStyle(EditorialFieldStyle())
                .groupBoxStyle(EditorialGroupBoxStyle()).tint(EditorialStyle.accent)
        }
        .onAppear {if let initialDestination {proxy.scrollTo(initialDestination,anchor:.top)}}
        }
    }
    private var calendarReady:Bool {store.calendarPermission.state == .fullAccess && !store.calendarPermission.lastProbeFailed}
    private func connectionCard<Status:View,Content:View>(_ title:String,icon:String,symbol:String,@ViewBuilder status:@escaping ()->Status,@ViewBuilder content:@escaping ()->Content)->some View {
        DetailCard(title:"") {
            HStack(spacing:12) {
                AppIcon(id:icon,symbol:symbol,size:32)
                Text(title).font(.headline);Spacer();status()
            }
            content()
        }.id(title)
    }
    private func appleStatus(_ title:String,permission:AppleDirectPermission,observation:AppleConnectionState<AppleDirectPermission>)->some View {
        let inactive=observation.lastFailure?.issue == .targetNotRunning
        let ready=permission == .authorized && observation.lastFailure == nil && !observation.restored
        return ConnectionIndicator(ready:ready,pending:observation.refreshing,title:title,inactive:inactive,
            text:inactive ? "未运行":permission == .denied ? "待授权":nil)
    }
    private var calendar: some View {
        let permission = store.calendarPermission
        return VStack(alignment: .leading, spacing: 20) {
            if permission.state != .fullAccess { Text(calendarTitle).font(.callout.weight(.medium)) }
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
            if !authorized {Text("提醒事项访问").font(.callout.weight(.medium))}
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

private struct TaskNotesConnectionView: View {
    let controller: NotesDirectController
    @State private var appearance:UUID?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if controller.permission != .authorized || controller.connection.state.lastFailure != nil || controller.busy {
            AppleConnectionActionsView(target: .notes, permission: controller.permission, enabled: controller.enabled,
                busy: controller.busy, observation: controller.connection.state,
                check: { Task { await controller.prepareForDisplay() } }, request: request)
            }
            if controller.permission == .authorized {
                VStack(alignment: .leading, spacing: 10) {
                    Text("默认写入文件夹").font(.callout.weight(.medium))
                    if !controller.folders.isEmpty || controller.scope != nil {
                        EditorialMenu {
                            ForEach(controller.folders) { folder in
                                Button(folder.label) {
                                    controller.performUserActionAfterClick { ticket in await controller.select(folder, ticket: ticket) }
                                }
                            }
                        } label: { Text(controller.scope?.folder.label ?? "选择文件夹") }
                            .frame(maxWidth: 360, alignment: .leading)
                            .disabled(controller.busy || controller.folders.isEmpty)
                    } else {
                        if let folder = controller.scope?.folder { Text(folder.label).font(.callout).foregroundStyle(.secondary) }
                    }
                    if controller.folders.isEmpty && controller.scope == nil { Button("选择默认写入文件夹") {
                        controller.performUserActionAfterClick { ticket in await controller.loadFolders(ticket: ticket) }
                    }.disabled(controller.busy) }
                    Text("读取和搜索覆盖所有已授权文件夹。").font(.caption).foregroundStyle(.secondary)
                    if let message=controller.message {Text(message).font(.callout).foregroundStyle(.secondary)}
                    if let detail = controller.detail {
                        DisclosureGroup("连接详情") {Text(detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)}
                    }
                }
            }
        }.task {
            appearance=controller.appear()
            while !Task.isCancelled {
                await controller.prepareForDisplay()
                do{try await Task.sleep(for:.seconds(5))}catch{return}
            }
        }
            .onReceive(NotificationCenter.default.publisher(for:NSApplication.didBecomeActiveNotification)) {_ in
                Task{await controller.prepareForDisplay()}
            }
            .onDisappear { if let appearance {controller.disappear(appearance:appearance)};appearance=nil }
    }
    private func request() {
        controller.performUserActionAfterClick { ticket in await controller.checkPermission(ticket: ticket, request: true); await controller.prepareForDisplay() }
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
                EditorialMenu {
                    Button("只读访问") { model.draft.applicationScope = .readOnly }
                    Button("申请读写") { model.draft.applicationScope = .readWriteRequested }
                } label: { Text(model.draft.applicationScope == .readOnly ? "只读访问" : "申请读写") }
                    .frame(width: 180, alignment: .leading).disabled(model.isPerforming)
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
