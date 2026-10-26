import SwiftUI

struct MessagesProductView: View {
    @Bindable var store: MessagesProductStore
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("信息 · 接入设置").font(.title2.weight(.semibold))
                        Text(store.held ? "信息接入尚未开放。原生授权与群测试由独立审核安排，刷新不会启动服务。" :
                            store.synthetic ? "合成数据演示；结果不代表真实账户、系统权限或群消息。" : "本次仅允许已审核群的有界文字测试。没有持续发送授权。")
                        HStack {
                            Text(textLabel).font(.headline)
                            Spacer()
                            Button("读取接入状态") { Task { await store.refreshStatus() } }.disabled(store.held || store.busy)
                        }
                        if let error = store.lastError { Text("需要重新核验：\(error)").font(.caption).foregroundStyle(.secondary) }
                        if store.sendAttemptObserved { Text("本次发送尝试已占用，不会因取消、重连或重新生成审核单而补充预算。").font(.caption).foregroundStyle(.secondary) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("能力状态") {
                    VStack(alignment: .leading, spacing: 8) {
                        LabeledContent("文字接收与发送", value: textLabel)
                        LabeledContent("图片传输", value: "源模块已实现；本次未开放、未实测")
                        LabeledContent("视频传输", value: "源模块已实现；本次未开放、未实测")
                        LabeledContent("图像与视频理解", value: "本次不执行")
                        LabeledContent("同一 Mio 入站触发", value: "外部链路未验证")
                        Text("文字状态仅描述本次群测试。接收权限、发送 Automation、群范围和消息证据分别核验。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                GroupBox("账户与系统授权") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(store.snapshot?.account.state == "reported_signed_in" ? "用户已在信息中报告登录；Apple 服务端状态未检查。" : "在系统信息应用中确认账户，再手动报告登录状态。")
                        HStack { action("开始设置", .begin); action("打开信息", .openMessages); action("我已登录", .confirmAccount) }
                        Text("接收路径：\(store.snapshot?.permissions.receive_access ?? "unknown")；发送权限：\(store.snapshot?.permissions.send_automation ?? "unknown")")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack { action("打开完全磁盘访问设置", .receiveSettings); action("重测读取权限", .retestAccess) }
                        HStack { action("允许信息发送", .requestSend); action("重测发送权限", .retestSend); action("重新核验权限", .refresh) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("群与成员审核") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("仅列出最多 20 个已有 iMessage 群的名称与成员，不读取消息正文。必须逐一审核所选群的全部成员。")
                            .font(.caption).foregroundStyle(.secondary)
                        action("读取群列表", .discoverGroups)
                        ForEach(store.candidates) { choice in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(choice.name).font(.headline)
                                ForEach(Array(choice.participants.enumerated()), id: \.offset) { _, participant in Text(participant).textSelection(.enabled) }
                                Button("已审核这些成员，选择此群") { Task { await store.selectGroup(choice.id) } }
                                    .disabled(store.busy || !store.evidenceCurrent)
                            }.padding(8)
                        }
                        if let group = store.selectedGroup { Text("已选择：\(group.name) · \(group.participants.count) 位成员") }
                        else if store.snapshot?.selection.state == "selected" {
                            Text("宿主保留群范围；本界面尚未重新审核成员。重连前先停用并确认清理。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        action("生成本次文字审核单", .prepareTest)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                if let plan = store.review {
                    GroupBox("本次文字测试审核单") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("仅一个已审核群、一个持久操作 UUID、一次文字发送。最多 15 分钟，另有 180 秒验证看门狗；未知结果占用发送预算，不自动重发。")
                            Text("操作：\(plan.operation_id)").font(.caption).textSelection(.enabled)
                            Text("截止：\(Date(timeIntervalSince1970: min(plan.expires_at, store.trialCeiling ?? plan.expires_at)).formatted())").font(.caption)
                            LabeledContent("先接收", value: plan.receive_text)
                            LabeledContent("唯一发送", value: plan.send_text)
                            LabeledContent("发送后接收", value: plan.confirmation_text)
                            Text(Self.readScope).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            Toggle("我已审核所选群的全部成员、上述文字及完整读取范围", isOn: Binding(get: { store.scopeApproved }, set: { store.approveReview($0) }))
                                .disabled(store.busy || !store.evidenceCurrent)
                            action("开始这一次文字测试", .startTest)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                HStack { action("取消并确认清理", .cancel); action("停用并确认清理", .disable); action("重新审核连接", .reconnect) }
                Text("取消需等待宿主确认清理。连接中断、取消超时或未知发送结果会阻止重连；重启只读取状态，不恢复发送。锁屏与保持唤醒的实测记录独立；休眠、注销和 FileVault 首次解锁另行验证。")
                    .font(.caption).foregroundStyle(.secondary)
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
    private func action(_ label: String, _ value: MessagesProductAction) -> some View {
        Button(label) { Task { await store.perform(value) } }.disabled(!store.can(value))
    }
    private var textLabel: String {
        switch store.textState {
        case .held: "等待独立审核"
        case .unknown: "证据未知或已过期"
        case .setupRequired: "需要完成设置"
        case .reviewRequired: "需要审核群与本次测试"
        case .verifying: "本次验证中"
        case .trialVerified: "仅本次文字收发已验证"
        case .syntheticTrial: "仅合成文字测试通过"
        case .interrupted: "已中断，需要读取新状态"
        case .cleanupUncertain: "清理结果未知，禁止重连"
        }
    }
    static let readScope = "读取范围：显式只读重测 SELECT 1；最多 20 个群、每群最多 17 个成员行，仅接受 2–16 位成员，私有标签最多 40 KiB。适配器从当前群高水位开始，在过滤之前读取该群的新行，包括有界正文与附件元数据，每页最多 32 行；寻找挑战期间其他新文字可留在私有发件箱。两个挑战是验收条件，不是两行读取上限。普通 imsg 独立匹配该群最近发出文字，从发送前时间减 2 秒开始、最多轮询 8 秒，可能读取测试前内容；失败诊断可查看匹配目标成员的近期未关联空白发出行的行号，并读取选中群的账户/路由元数据。整个链路不承诺零历史、零既有内容或只读挑战。没有任意回溯、其他群正文、附件字节、媒体发送或 Mio 披露。内容留在批准的私有范围，随后清理本次私有内容，保留最小游标、去重和发送/授权墓碑；不删除信息原件或系统权限。"
}
