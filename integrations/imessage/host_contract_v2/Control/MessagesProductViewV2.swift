import SwiftUI
import AppKit

struct MessagesProductViewV2: View {
    @Bindable var store: MessagesProductStoreV2
    @State private var messagesOpenFailed = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if store.held {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("信息连接").font(.title2.weight(.semibold))
                            Text("尚未开放").font(.headline)
                            Text(store.holdReason?.detail ?? "接入尚未开放，系统权限未知。")
                                .foregroundStyle(.secondary)
                            Text("可先在系统信息应用中确认账户；ARL 此时不读取群信息、消息正文或发送内容。")
                                .font(.caption).foregroundStyle(.secondary)
                            if store.holdReason == .admissionMissing {
                                Button("打开信息") { openSystemMessages() }
                                    .help("仅打开系统信息应用，由你确认账户；不申请权限或发送信息")
                                if messagesOpenFailed { Text("请从应用程序中打开信息。").font(.caption).foregroundStyle(.secondary) }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    capabilityStatus
                    authorizationDisclosure
                } else {
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("信息设置").font(.title2.weight(.semibold))
                        Text(store.held ? ("信息接入尚未开放。系统授权与群测试由独立审核安排，刷新不会启动服务。") :
                            store.synthetic ? ("模拟数据演示；结果不代表真实账户、系统权限或群消息。") : ("本次仅允许已审核群的限范围的文字测试。没有持续发送授权。"))
                        HStack {
                            Text(textLabel).font(.headline)
                            Spacer()
                            Button("读取状态") { Task { await store.refreshStatus() } }.help("仅查看本次信息连接状态").disabled(store.held || store.busy)
                        }
                        if let diagnostic = store.diagnostic {
                            Text(diagnostic.title).font(.headline)
                            Text(diagnostic.nextStep).font(.caption).foregroundStyle(.secondary)
                            Text("诊断代码：\(diagnostic.code)").font(.caption).textSelection(.enabled)
                        }
                        if store.candidateVerified && store.authority == nil { Text(("服务候选身份已核验，运行状态尚不可读取。手动开始设置可尝试固定启动路径；系统权限与消息能力仍未知。")).font(.caption).foregroundStyle(.secondary) }
                        if let authority = store.authority {
                            Text(("本次截止时间、发送结果与清理状态" + "\n" + "本次原生截止：\(Date(timeIntervalSince1970: authority.deadline).formatted()) · 发送：\(sendOutcomeLabel(authority.send.outcome)) · 清理轮次：\(authority.cleanup.epoch)")).font(.caption).foregroundStyle(.secondary)
                        }
                        if store.sendAttemptObserved { Text(("本次发送次数已用，取消或重连不补充" + "\n" + "本次发送尝试已占用，不会因取消、重连或重新生成审核单而补充限额。")).font(.caption).foregroundStyle(.secondary) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                capabilityStatus
                authorizationDisclosure
                GroupBox("账号权限") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(store.evidenceCurrent && store.snapshot?.account.state == "reported_signed_in" ? ("仅用户报告登录，Apple状态未查" + "\n" + "用户已在信息中报告登录；Apple 服务端状态未检查。") : ("先在系统信息应用登录，再报告状态" + "\n" + "在系统信息应用中确认账户，再手动报告登录状态。"))
                        HStack { action(store.authority == nil ? "启动已审核服务并开始设置" : "开始设置", .begin); action("打开信息", .openMessages); action("报告登录", .confirmAccount).help("仅报告登录，未检查Apple状态") }
                        LabeledContent("接收读取路径", value: permissionLabel(store.evidenceCurrent ? store.snapshot?.permissions.receive_access : nil))
                        LabeledContent("发送自动化权限", value: permissionLabel(store.evidenceCurrent ? store.snapshot?.permissions.send_automation : nil))
                        LabeledContent("发送结果回读", value: permissionLabel(store.evidenceCurrent ? store.snapshot?.permissions.send_readback_access : nil))
                        HStack { action("接收设置", .receiveSettings).help("打开完全磁盘访问设置；只核对信息辅助程序"); action("检查读取", .retestAccess).help("仅显式只读路径检查，不读取消息正文") }
                        HStack { action("发送授权", .requestSend).help("由信息辅助程序申请自动化信息权限；不发送信息"); action("检查发送", .retestSend).help("重新核对自动化权限与结果回读路径"); action("检查权限", .refresh).help("显式重新核对本次权限状态") }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("审核群组") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(("请审核全部成员及本次读取范围" + "\n" + "仅列出最多 20 个已有 iMessage 群的名称与成员，不读取消息正文。必须逐一审核所选群的全部成员。"))
                            .font(.caption).foregroundStyle(.secondary)
                        action("读取群组", .discoverGroups).help("最多20个群，不读取消息正文")
                        ForEach(store.candidates) { choice in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(choice.name).font(.headline)
                                ForEach(Array(choice.participants.enumerated()), id: \.offset) { _, participant in Text(participant).textSelection(.enabled) }
                                Button("选择此群") { Task { await store.selectGroup(choice.id) } }.help("确认已审核此群的全部成员")
                                    .disabled(store.busy || !store.evidenceCurrent)
                            }.padding(8)
                        }
                        if let group = store.selectedGroup { Text("已选择：\(group.name) · \(group.participants.count) 位成员") }
                        else if store.snapshot?.selection.state == "selected" {
                            Text(("请审核全部成员及本次读取范围" + "\n" + "负责程序保留群范围；本界面尚未重新审核成员。重连前先停用并确认清理。"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        action("生成审核", .prepareTest).help("生成本次文字测试的审核内容")
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.help("逐一审核所选群的全部成员")
                if let plan = store.review {
                    GroupBox("本次文字测试审核单") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(("请求结果未知时，请核对后再操作" + "\n" + "仅一个已审核群、一个持久操作 UUID、一次文字发送。最多 15 分钟，另有 180 秒验证时限；未知结果占用发送限额，不自动重发。"))
                            Text("操作：\(plan.operation_id)").font(.caption).textSelection(.enabled)
                            Text("截止：\(Date(timeIntervalSince1970: min(plan.expires_at, store.authority?.deadline ?? store.trialCeiling ?? plan.expires_at)).formatted())").font(.caption)
                            if let group = store.selectedGroup {
                                LabeledContent("确切收件群", value: group.name)
                                Text("全部收件成员（\(group.participants.count) 位）").font(.headline)
                                ForEach(Array(group.participants.enumerated()), id: \.offset) { _, participant in
                                    Text(participant).textSelection(.enabled)
                                }
                            } else {
                                Text("缺少确切收件范围，不能开始测试。").foregroundStyle(.secondary)
                            }
                            LabeledContent("接收文字", value: plan.receive_text).help("测试前需收到的完整文字")
                            LabeledContent("发送文字", value: plan.send_text).help("本次唯一一次要发送的完整文字")
                            LabeledContent("确认文字", value: plan.confirmation_text).help("发送后需收到的确认文字")
                            Text(Self.readScope).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            Toggle(("请审核全部成员及本次读取范围" + "\n" + "我已审核所选群的全部成员、上述文字及完整读取范围"), isOn: Binding(get: { store.scopeApproved }, set: { store.approveReview($0) }))
                                .disabled(store.busy || !store.evidenceCurrent)
                            action("开始测试", .startTest).help("只执行本次已审核的文字测试")
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                HStack { action("取消清理", .cancel).help("取消测试并等待清理确认"); action("停用清理", .disable).help("停用连接并等待清理确认"); action("审核重连", .reconnect).help("重新审核本次连接范围") }
                Text(("请求结果未知时，请核对后再操作" + "\n" + "取消需等待负责程序确认清理。连接中断、取消超时或未知发送结果会阻止重连；重启只读取状态，不恢复发送。锁屏与保持唤醒的实测记录独立；休眠、注销和 FileVault 首次解锁另行验证。"))
                    .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(22)
        }
        .task {
            guard !store.held else { return }
            await store.refreshStatus()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { break }
                store.expireEvidence()
                await store.refreshStatus()
            }
        }
        .onDisappear { store.interrupt() }
    }
    private var capabilityStatus: some View {
        GroupBox("功能状态") {
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("个人文字", value: "尚未接入")
                LabeledContent("群聊文字", value: textLabel)
                LabeledContent("图片视频", value: "未开放")
                LabeledContent("内容理解", value: "不执行")
                LabeledContent("Mio 触发", value: "尚未验证")
                LabeledContent("锁屏且保持唤醒", value: "待实测")
                LabeledContent("休眠、注销与首次解锁", value: "尚未验证")
                Text("群聊仅一个已审核群、2–16 位收件成员、最多 15 分钟及一次文字发送。文字试验不证明个人消息、附件或后台持续可用。")
                    .font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private var authorizationDisclosure: some View {
        GroupBox("授权对象") {
            VStack(alignment: .leading, spacing: 8) {
                Text("读取与发送由 ARL 信息辅助程序处理。授权前先完成辅助程序安装与身份核验。")
                Text("核对对象：ARL Messages Bridge · local.arl.messagesbridge")
                    .font(.caption).textSelection(.enabled)
                Text("基础文字发送的系统授权是自动化“信息”；完全磁盘访问不是所有发送能力的统一前提。仅发送、不读聊天的调用链尚未接入。")
                Text("本次群试验含群信息、接收与发送结果回读；这些读取路径需单独核对辅助程序的完全磁盘访问及获批范围。")
                Text("使用本页“发送授权”允许信息辅助程序自动化“信息”；此按钮不发送信息、不读取聊天。")
                Text("身份和被动状态检查不读取聊天。“检查读取”会打开信息数据库检查路径访问，不查询正文；该结果只证明限定路径访问。")
                Text("收到的附件读取与用户主动选文件发送分别审核；本次两者均未开放、未实测。")
                Text("无需联系人权限。不会扫描联系人；群名称与成员仅在范围获批后手动读取。")
                Text("系统权限、群成员范围与每次发送批准分别核对。发送前会再次列出确切群、全部成员及完整文字。")
            }.font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func openSystemMessages() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.MobileSMS") else {
            messagesOpenFailed = true; return
        }
        messagesOpenFailed = !NSWorkspace.shared.open(url)
    }
    private func permissionLabel(_ state: String?) -> String {
        switch state {
        case "verified": "限定只读路径检查通过"
        case "blocked": "限定读取路径受阻"
        case "authorized_automation": "自动化已允许，送达仍需验证"
        case "not_determined": "尚未由用户决定"
        case "denied": "未允许，可手动核对自动化设置"
        case "restricted": "系统限制，需核对限制原因"
        default: "未知或尚未检查"
        }
    }
    private func sendOutcomeLabel(_ state: String) -> String {
        switch state {
        case "unused": "本次次数未使用"
        case "accepted": "命令已接受，送达另行确认"
        default: "次数已占用，结果未知，不能重发"
        }
    }
    private func action(_ label: String, _ value: MessagesProductAction) -> some View {
        Button(label) { Task { await store.perform(value) } }.disabled(!store.can(value))
    }
    private var textLabel: String {
        switch store.textState {
        case .held: "等待独立审核"
        case .unknown: "核对记录未知或已过期"
        case .setupRequired: "需要先完成设置"
        case .reviewRequired: ("需要审核群组与本次测试" + "\n" + "需要审核群与本次测试")
        case .verifying: ("正在验证本次测试" + "\n" + "本次验证中")
        case .trialVerified: "仅本次文字收发已验证"
        case .syntheticTrial: ("仅模拟文字测试通过" + "\n" + "仅合成文字测试通过")
        case .interrupted: "已中断，需要重新读取状态"
        case .cleanupUncertain: ("清理结果未知，不能重新连接" + "\n" + "清理结果未知，禁止重连")
        }
    }
    static let readScope = ("读取范围：显式只读重测 SELECT 1；最多 20 个群、每群最多 17 个成员行，仅接受 2–16 位成员，私有标签最多 40 KiB。适配器从当前群高水位开始，在过滤之前读取该群的新行，包括有界正文与附件基本信息，每页最多 32 行；寻找挑战期间其他新文字可留在私有发件箱。两个挑战是验收条件，不是两行读取上限。普通 imsg 独立匹配该群最近发出文字，从发送前时间减 2 秒开始、最多轮询 8 秒，可能读取测试前内容；失败诊断可查看匹配目标成员的近期未关联空白发出行的行号，并读取选中群的账户/路由基本信息。整个链路不承诺零历史、零既有内容或只读挑战。没有任意回溯、其他群正文、附件字节、媒体发送或 Mio 披露。内容留在批准的私有范围，随后清理本次私有内容，保留最小游标、去重和发送/授权墓碑；不删除信息原件或系统权限。")
}
