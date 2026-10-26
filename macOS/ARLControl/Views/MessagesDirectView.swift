import SwiftUI
import AppKit

struct MessagesDirectView: View {
    let controller: MessagesDirectController
    @State private var email = ""
    @State private var plaintext = ""
    @State private var draftID = UUID()
    @State private var query = ""
    var body: some View {
        ScrollView {
            DetailCard(title: "信息") {
                Text("选择账号，查询会话或发送信息。").font(.callout).foregroundStyle(.secondary)
                AppleConnectionActionsView(target: .messages, permission: controller.permission,
                    enabled: controller.enabled, busy: controller.busy, observation: controller.connection.state,
                    check: { Task { await controller.prepareForDisplay() } },
                    request: { if let ticket = controller.ticket() { Task { await controller.checkPermission(ticket: ticket, request: true); await controller.prepareForDisplay() } } })
                if controller.permission == .authorized {
                    if controller.selectedAccount == nil {
                        Text("请选择已有的发送账号。").font(.callout).foregroundStyle(.secondary)
                    }
                    Button(controller.accounts.isEmpty ? "选择账号" : "刷新账号") { if let ticket = controller.ticket() { Task { await controller.loadAccounts(ticket: ticket) } } }
                        .disabled(controller.busy)
                }
                if let scan = controller.accountScan {
                    Text("账户 \(scan.total) · 可用 \(scan.accounts.count) · 未接入 \(scan.excluded)")
                        .font(.caption).foregroundStyle(.secondary)
                    if scan.accounts.isEmpty && scan.failures.isEmpty {
                        Text("未找到可用发送账号，请在系统信息中检查登录。").font(.caption).foregroundStyle(.secondary)
                    }
                    if !scan.failures.isEmpty { Text("\(scan.failures.count) 个账户读取失败").font(.callout).foregroundStyle(.secondary) }
                }
                if controller.accountScanIsStale, let last = controller.lastAccountScan {
                    Text("最近记录：\(last.accounts.count) 个发送账户；当前连接尚未核验，原选择已暂停。")
                        .font(.caption).foregroundStyle(.secondary)
                    if let observed = controller.accountObservedAt {
                        Text(observed, format: .dateTime.month().day().hour().minute()).font(.caption).foregroundStyle(.secondary)
                    }
                }
                ForEach(controller.accounts) { account in
                    HStack {
                        Text(account.label)
                        Spacer()
                        Button(controller.selectedAccount == account ? "已选择" : "选用账户") { draftID = UUID(); controller.select(account) }
                            .disabled(controller.busy || controller.selectedAccount == account)
                    }
                }
                if let account = controller.selectedAccount {
                    Divider()
                    Text("发送账户：\(account.label)").font(.callout.bold())
                    HStack {
                        TextField("会话名称", text: $query)
                        Button(query.isEmpty ? "列出会话" : "查找会话") {
                            let exactQuery = query
                            if let ticket = controller.ticket() { Task { await controller.loadChats(query: exactQuery, ticket: ticket) } }
                        }.disabled(controller.busy)
                    }
                    if let result = controller.chats {
                        Text("检查 \(result.scanned) / \(result.total) 个 · 最多 50 个").font(.caption).foregroundStyle(.secondary)
                        ForEach(result.chats) { chat in Text(chat.name.isEmpty ? "未命名会话" : chat.name).textSelection(.enabled) }
                    }
                    Text("系统未提供消息收读接口。").font(.caption).foregroundStyle(.secondary)
                    TextField("邮箱或国际格式手机号", text: $email).disabled(controller.busy)
                    Text("填写明确地址，发送时核对唯一收件人。").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $plaintext).frame(minHeight: 130).disabled(controller.busy)
                        .accessibilityLabel("待发送信息全文")
                    Text("提交后，送达请在系统信息查看。").font(.caption).foregroundStyle(.secondary)
                    Button("发送信息") {
                        let text = plaintext, address = email, submittedDraftID = draftID
                        if let ticket = controller.ticket() { Task { await controller.send(plaintext: text, email: address, draftID: submittedDraftID, ticket: ticket) } }
                    }.disabled(controller.busy || !controller.canSubmitDraft(draftID) || controller.permission != .authorized ||
                        (try? MessagesDirectContract.address(email)) == nil || plaintext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if controller.busy { HStack { ProgressView().controlSize(.small); Button("停止操作") { controller.cancel() } } }
                if !controller.businessLogAvailable { Text("业务日志写入失败，操作仍可继续。").font(.caption).foregroundStyle(.secondary) }
                if let message = controller.message { Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
                DisclosureGroup("连接详情") {
                    Text("Apple 登录和自动化权限分别核验。")
                    Text("收发地址请在信息设置中选择。")
                    Text("ARL 不收密码，不读取通讯录。")
                    Text("群聊发送和附件暂未开放。")
                    Text("公开接口不提供历史正文或接收通知。")
                    Text("结果不明时不会自动重发。")
                    if let account = controller.selectedAccount { Text(account.id).textSelection(.enabled) }
                    if let id = controller.lastOperationID { Text("操作记录：" + id).textSelection(.enabled) }
                    if let scan = controller.accountScan {
                        ForEach(MessagesDirectService.allCases, id: \.self) { service in
                            Text(service.rawValue + " · " + String(scan.services[service, default: 0]))
                        }
                        ForEach(scan.failures) { item in
                            Text("账户 \(item.index) · " + item.fault.diagnostic).textSelection(.enabled)
                        }
                    }
                    if let detail = controller.detail { Text(detail).textSelection(.enabled) }
                }.font(.caption).foregroundStyle(.secondary)
            }.padding(22).frame(maxWidth: 1180, alignment: .leading).frame(maxWidth: .infinity)
        }
        .task {
            controller.appear(); await controller.prepareForDisplay()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { break }
                await controller.prepareForDisplay()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await controller.prepareForDisplay() }
        }
        .onDisappear { controller.disappear() }
        .onChange(of: email) { draftID = UUID(); controller.targetEdited() }
        .onChange(of: plaintext) { draftID = UUID() }
        .onChange(of: controller.selectedAccount) { acknowledgeAcceptedDraft() }
        .onChange(of: controller.lastTerminal) { acknowledgeAcceptedDraft() }
    }
    private func acknowledgeAcceptedDraft() {
        guard controller.lastTerminal?.shouldClear(id: draftID, account: controller.selectedAccount, email: email, plaintext: plaintext) == true else { return }
        plaintext = ""; draftID = UUID()
    }
}
