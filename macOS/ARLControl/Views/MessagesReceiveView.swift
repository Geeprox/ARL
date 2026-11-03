import SwiftUI

struct MessagesReceiveView: View {
    let controller: MessagesReceiveController
    @State private var consumerAppID = ""
    @State private var reviewedScope = false
    @State private var confirmDiscard = false
    var body: some View {
        DetailCard(title: "接收新信息") {
            Text("选择一个 iMessage 会话，把之后的新文字交给指定本机应用。")
                .font(.callout).foregroundStyle(.secondary)
            Text("读取需要 ARL 的完全磁盘访问权限。只有点击列出会话后才读取目录；不会读取旧消息正文。")
                .font(.caption).foregroundStyle(.secondary)
            Text(controller.agentTransportAvailable ? "本机接收通道已就绪，应用仍须完成授权握手。" : "本机应用接收通道尚未就绪，请先恢复运行时连接。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("列出接收会话") { reviewedScope = false; Task { await controller.loadConversations() } }
                Button("查看已保存范围") { Task { await controller.loadSavedStatus() } }
            }.disabled(controller.busy || !controller.enabled)
            ForEach(controller.selections, id: \.conversation.rowID) { selection in
                VStack(alignment: .leading, spacing: 4) {
                    Text(selection.conversation.name.isEmpty ? selection.conversation.participants.joined(separator: "、") : selection.conversation.name)
                    Text(selection.conversation.account).font(.caption).foregroundStyle(.secondary)
                    Button(controller.selected?.conversation == selection.conversation ? "已选择" : "选用此会话") {
                        reviewedScope = false; controller.select(selection)
                    }.disabled(controller.busy)
                }
            }
            if controller.nextBeforeRowID != nil {
                Button("下一页会话") { reviewedScope = false; Task { await controller.loadConversations(nextPage: true) } }.disabled(controller.busy)
            }
            if let selected = controller.selected {
                Divider()
                Text("接收账号：" + selected.conversation.account)
                Text("会话：" + selected.conversation.guid).font(.caption).textSelection(.enabled)
                Text("全部对端：" + selected.conversation.participants.joined(separator: "、")).font(.callout)
                TextField("已授权本机应用 ID", text: $consumerAppID)
                    .accessibilityLabel("接收信息的本机应用 ID")
                Text("该应用还须完成受信握手，并获授信息接收能力。Mio 不会取得此范围。")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("已核对账号、会话、全部对端及接收应用", isOn: $reviewedScope)
                Button("从现在开始接收") { Task { await controller.start(consumerAppID: consumerAppID) } }
                    .disabled(controller.busy || !controller.agentTransportAvailable || !reviewedScope || consumerAppID.isEmpty)
            }
            if let status = controller.status {
                Text(status.running ? "正在接收" : status.enabled ? "范围已保存，接收已暂停" : "接收已停止")
                if let scope = status.scope {
                    Text(scope.conversation.account + " → " + scope.consumerAppID).font(.caption)
                    Text(scope.conversation.participants.joined(separator: "、")).font(.caption).textSelection(.enabled)
                }
                Text("\(status.pendingCount) 条新信息等待应用确认").font(.caption).foregroundStyle(.secondary)
                HStack {
                    if status.enabled && !status.running { Button("从现在继续接收") { Task { await controller.resume() } }.disabled(!controller.agentTransportAvailable) }
                    if status.enabled { Button("停止接收") { Task { await controller.stopReceiving() } } }
                    if !status.enabled && status.pendingCount > 0 { Button("清除本机待确认副本") { confirmDiscard = true } }
                }.disabled(controller.busy)
            }
            if controller.busy { ProgressView().controlSize(.small) }
            if let message = controller.message { Text(message).font(.callout).foregroundStyle(.secondary) }
            Text("只交付新入站纯文本。富内容、未知消息类型和超限内容会明确标记；资料库或成员变化时暂停。重开后由你点击继续，不回溯暂停期间的消息。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .confirmationDialog("清除待确认信息的本机副本？系统信息原件不会改动。", isPresented: $confirmDiscard) {
            Button("清除副本", role: .destructive) { Task { await controller.discardPending() } }
            Button("取消", role: .cancel) {}
        }
    }
}
