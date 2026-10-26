import SwiftUI

/// The SDK is the sole source of credential and connection state.
@MainActor
public struct CredentialConnectionPanel: View {
    private let purpose: CredentialPurpose
    private let onboarding: CredentialOnboarding
    @State private var snapshot: CredentialSnapshot
    @State private var loaded = false
    @State private var visible = false
    @State private var showingEntry = false
    @State private var confirmingRemoval = false
    @State private var message: String?
    @State private var activity: Activity?
    @State private var activityID: UUID?
    @State private var activityTask: Task<Void, Never>?
    @State private var cancelling = false
    @State private var musicLogin = MusicLoginPresentation()
    @State private var presentationGeneration = UUID()

    private enum Activity: Equatable {
        case refresh, prepareMusic, musicStatus, musicLogin, test, remove
        var title: String {
            switch self {
            case .refresh: "读取中"
            case .prepareMusic: "准备登录"
            case .musicStatus: "检查登录"
            case .musicLogin: "取码中"
            case .test: "连接中"
            case .remove: "移除中"
            }
        }
        var canCancel: Bool {
            switch self {
            case .prepareMusic, .musicStatus, .musicLogin, .test: true
            case .refresh, .remove: false
            }
        }
    }

    public init(purpose: CredentialPurpose, onboarding: CredentialOnboarding) {
        self.purpose = purpose
        self.onboarding = onboarding
        _snapshot = State(initialValue: .init(purpose: purpose, reference: nil, state: .notConfigured, lastTest: nil))
    }

    public var body: some View {
        GroupBox(purpose.title) {
            VStack(alignment: .leading, spacing: 12) {
                if loaded { Text(snapshot.state.title).font(.headline) }
                else { ProgressView("读取中").controlSize(.small) }
                if let result = snapshot.lastTest {
                    Text("上次检查：\(result.checkedAt.formatted(date: .abbreviated, time: .shortened)) · \(result.state.title)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
                if let loginMessage = musicLogin.phase.message {
                    Text(loginMessage).font(.callout)
                }
                if snapshot.reference == nil { credentialActions }

                if snapshot.reference != nil {
                    connectionActions
                }
                if let activity {
                    HStack {
                        ProgressView(cancelling ? "正在取消"
                                     : activity == .musicLogin && musicLogin.phase == .waitingForScan
                                        ? "等待网易云音乐App扫码确认" : activity.title)
                            .controlSize(.small)
                        if activity.canCancel {
                            Button("取消操作", action: cancelActivity).disabled(cancelling)
                        }
                    }
                    if activity == .musicLogin, !cancelling {
                        Text("关闭面板会取消等待，过期后刷新。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let image = musicLogin.image, activity == .musicLogin, !cancelling {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("请用网易云音乐App扫描登录码").font(.headline)
                        Image(decorative: image, scale: 1)
                            .interpolation(.none)
                            .resizable()
                            .frame(width: CGFloat(image.width * max(1, 280 / image.width)),
                                   height: CGFloat(image.height * max(1, 280 / image.height)))
                            .accessibilityLabel("本次网易云登录二维码")
                            .accessibilityHint(("使用手机上的网易云音乐 App 扫码，并在手机上确认登录"))
                        Text("只在本人手机扫码，勿转发。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if snapshot.reference != nil { managementActions }
                DisclosureGroup("服务详情") {
                    Text(snapshot.explanation)
                    Text(operationExplanation)
                    HStack {
                        Link("设置说明", destination: purpose.setupURL)
                        Link("官方后台", destination: purpose.consoleURL)
                    }
                    if purpose != .neteaseMusic {
                        LegacyTravelMigrationPanel(purpose: purpose, onboarding: onboarding) { result in
                            presentationGeneration = UUID()
                            snapshot = result.snapshot; loaded = true; message = result.message
                        }.disabled(!loaded || activity != nil || showingEntry)
                    }
                }.font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
        .task {
            guard activity == nil else { return }
            let current = await onboarding.snapshot(purpose: purpose)
            guard !Task.isCancelled, activity == nil else { return }
            snapshot = current
            loaded = true
        }
        .sheet(isPresented: $showingEntry, onDismiss: entryDismissed) {
            CredentialEntrySheet(purpose: purpose, onboarding: onboarding, replacing: snapshot.reference) { result in
                presentationGeneration = UUID()
                musicLogin.invalidate()
                snapshot = result.snapshot
                loaded = true
                message = result.message
            }
        }
        .confirmationDialog("移除登录", isPresented: $confirmingRemoval, titleVisibility: .visible) {
            Button("移除登录", role: .destructive) { start(.remove) }.help("移除本机密钥及登录状态")
            Button("取消", role: .cancel) {}
        } message: {
            Text(purpose == .neteaseMusic
                 ? ("将移除此应用保存的网易云应用密钥和登录状态；服务方服务密钥和账号授权不会被撤销。")
                 : ("仅本机移除，不撤销服务方密钥" + "\n" + "服务方 Key 不会被撤销；如需撤销或轮换，请到官方控制台处理。"))
        }
        .onAppear { visible = true }
        .onDisappear {
            visible = false
            presentationGeneration = UUID()
            cancelActivity()
            musicLogin.invalidate()
        }
    }

    private var credentialActions: some View {
        HStack {
            Button(snapshot.reference == nil ? "填写密钥" : "更新密钥") {
                message = nil
                musicLogin.invalidate()
                showingEntry = true
            }
            .help(snapshot.reference == nil ? "填写此服务的官方密钥" : "更新此服务的官方密钥")
            .disabled(!loaded || activity != nil || (snapshot.reference == nil && snapshot.state == .setupRequired))

        }
    }

    private var connectionActions: some View {
        HStack {
            if purpose == .neteaseMusic {
                Button(musicLogin.phase.loginButtonTitle) { start(.musicLogin) }.help(musicLogin.phase.loginButtonExplanation).disabled(activity != nil)
            } else {
                Button("测试连接") { start(.test) }.disabled(activity != nil)
            }
        }
    }

    private var managementActions: some View {
        Menu("登录管理") {
            Button("更新密钥") { message = nil; musicLogin.invalidate(); showingEntry = true }
            if purpose == .neteaseMusic { Button("检查登录") { start(.musicStatus) } }
            Button("刷新状态") { start(.refresh) }
            Button("移除登录", role: .destructive) { confirmingRemoval = true }
        }.disabled(!loaded || activity != nil || showingEntry)
    }

    private var operationExplanation: String {
        switch purpose {
        case .nasSMB: "请在硬盘设置中配置 NAS；此通用面板不接收 NAS 凭据。"
        case .neteaseMusic:
            ("保存会立即验证连接；需要登录时请单独扫码。验证只读取歌单，不执行写入。刷新状态只读取此应用保存的状态。")
        case .amapMapsWeather:
            ("天气测试可能消耗额度" + "\n" + "测试发送一次固定的天气请求，可能消耗调用额度。不会读取订单或进行预订。")
        case .fliggyTravelReadOnly:
            ("旅行测试可能消耗额度" + "\n" + "测试先检查随机无效 Key 是否被拒绝，再用所填 Key 发出只读搜索；最多两次请求，可能消耗调用额度。不会读取订单或进行预订。")
        }
    }

    private func entryDismissed() {
        // Save and verification have completed before the sheet dismisses.
        guard activity == nil else { return }
        start(.refresh, preservingMessage: true)
    }

    private func start(_ next: Activity, preservingMessage: Bool = false) {
        guard visible, activity == nil else { return }
        let reference = snapshot.reference
        guard next == .refresh || reference != nil else { return }
        let id = UUID()
        let generation = presentationGeneration
        if next == .musicLogin {
            guard let reference, musicLogin.begin(id: id, reference: reference) else { return }
        } else if next != .refresh { musicLogin.invalidate() }
        activityID = id
        activity = next
        cancelling = false
        if !preservingMessage { message = nil }
        activityTask = Task { @MainActor in
            defer {
                if activityID == id {
                    activity = nil
                    activityID = nil
                    activityTask = nil
                    cancelling = false
                }
            }
            do {
                try Task.checkCancellation()
                switch next {
                case .refresh:
                    let current = await onboarding.snapshot(purpose: purpose)
                    guard acceptsCompletion(id, generation: generation) else { return }
                    if snapshot.reference != current.reference { musicLogin.invalidate() }
                    snapshot = current
                case .prepareMusic, .musicStatus, .musicLogin:
                    guard let reference else { return }
                    let operation: MusicOperation = next == .prepareMusic ? .prepare : next == .musicStatus ? .status : .login
                    let current = try await onboarding.performMusic(reference, operation: operation) { url in
                        let diagnostic=MusicDiagnostics.current
                        Task { @MainActor in
                            // A closed view, replaced credential, completed or cancelled
                            // request must never publish a queued QR into another session.
                            guard acceptsCompletion(id, generation: generation), snapshot.reference == reference,
                                  activity == .musicLogin, !cancelling else {
                                diagnostic?.record(.qr_display,.ignored,reason:.stale_callback)
                                return
                            }
                            switch musicLogin.receive(url, id: id, reference: reference) {
                            case .displayed: diagnostic?.record(.qr_display,.succeeded)
                            case .rejected:
                                diagnostic?.record(.qr_display,.invalid_response,reason:.qr_render)
                                cancelActivity()
                            case .ignored: diagnostic?.record(.qr_display,.ignored,reason:.stale_callback)
                            }
                        }
                    }
                    guard acceptsCompletion(id, generation: generation), snapshot.reference == reference else { return }
                    snapshot = current
                    if next == .musicLogin { musicLogin.complete(current.state, id: id, reference: reference) }
                    if next == .prepareMusic { message = ("本地准备已完成；当前状态以此处显示为准。请单独扫码登录。") }
                case .test:
                    guard let reference else { return }
                    let current = try await onboarding.testConnection(reference)
                    guard acceptsCompletion(id, generation: generation), snapshot.reference == reference else { return }
                    snapshot = current
                case .remove:
                    guard let reference else { return }
                    let receipt = try await onboarding.disconnect(reference)
                    let current = await onboarding.snapshot(purpose: purpose)
                    guard acceptsCompletion(id, generation: generation), snapshot.reference == reference else { return }
                    snapshot = current
                    message = receipt.localRemoved && !receipt.providerRevoked && snapshot.state == .notConfigured && snapshot.reference == nil
                        ? ("本机登录信息已移除，服务权限不变" + "\n" + "本机密钥已移除；服务方权限未撤销。")
                        : ("移除未确认，刷新状态；服务权限不变" + "\n" + "本地移除未确认；请刷新状态。服务方权限未撤销。")
                }
            } catch {
                // Errors and cancellation cannot be used to invent a persisted SDK state.
                let current = await onboarding.snapshot(purpose: purpose)
                guard acceptsCompletion(id, generation: generation) else { return }
                snapshot = current
                if next == .musicLogin, let reference {
                    musicLogin.fail(error, id: id, reference: reference)
                } else {
                    message = error is CancellationError
                        ? ("已申请取消，显示本机状态，未重试" + "\n" + "已请求取消；以下显示当前本地状态，未自动重试。")
                        : failureMessage(error, activity: next)
                }
            }
            loaded = true
        }
    }

    private func cancelActivity() {
        musicLogin.cancel()
        guard activity?.canCancel == true, !cancelling else { return }
        cancelling = true
        activityTask?.cancel()
    }

    private func acceptsCompletion(_ id: UUID, generation: UUID) -> Bool {
        visible && activityID == id && presentationGeneration == generation
    }

    private func failureMessage(_ error: any Error, activity: Activity) -> String {
        if let error=error as? MusicDiagnosticFailure { return error.diagnostic.message }
        if error as? MusicReadRuntimeFailure == .cleanupUnproven {
            return ("上一次连接仍在结束；完成清理前无法开始新操作。请稍后重试。")
        }
        return switch error as? CredentialError {
        case .deploymentNotApproved, .identityMismatch:
            ("接入或身份未通过，已重新读取状态" + "\n" + "应用接入尚未完成或身份校验未通过；已重新读取本地状态。")
        case .staleReference, .missing:
            "登录信息已变，请重新选择"
        case .busy:
            ("已有操作进行中，请等待或在原页取消" + "\n" + "此服务已有操作正在进行；请等待或在原面板取消。")
        default:
            activity == .prepareMusic
                ? ("登录信息已存，准备未完成，未重试" + "\n" + "服务密钥已保存，但本地准备未完成；已刷新状态，未自动重试。")
                : activity == .remove
                    ? ("仅本机移除，服务方权限不变" + "\n" + "未能确认本地移除；已刷新状态，服务方权限未撤销。")
                    : ("操作未完成，已刷新，未自动重试" + "\n" + "操作未完成；已刷新本地状态，未自动重试。")
        }
    }
}
