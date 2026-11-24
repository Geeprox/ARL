import SwiftUI

struct OverviewView: View {
    let store: RuntimeStore
    var navigate: (ControlSection) -> Void = { _ in }
    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            EditorialHeading(title: "运行概览", subtitle: "")
            if store.bundledRuntimeError != nil || store.bundledRuntimeRecovering {
                VStack(alignment: .leading, spacing: 10) {
                    EditorialNotice(title: "后台服务正在恢复",
                                    detail: "ARL 会自动重试，也可以立即重试。",
                                    symbol: "arrow.clockwise", color: .orange)
                    Button(store.bundledRuntimeRecovering ? "正在重试" : "立即重试") { store.recoverBundledRuntime() }
                        .disabled(store.bundledRuntimeRecovering || store.nativeActionsHeld)
                }
            } else if store.controlError != nil {
                VStack(alignment: .leading, spacing: 10) {
                    EditorialNotice(title: "暂时无法读取运行状态", detail: "",
                                    symbol: "exclamationmark.circle", color: .orange)
                    Button(store.reading ? "正在更新" : "立即更新") { Task { await store.refresh() } }.disabled(store.reading)
                }
            }
            VStack(spacing: 0) {
                fact("本机服务", value: Self.runtimeTitle(state: store.control.runtime.value?.state, connected: store.connected, hasIssue: !store.connected && (store.bundledRuntimeError != nil || store.controlError != nil)), symbol: "desktopcomputer")
                Divider()
                TimelineView(.periodic(from: .now, by: 5)) { timeline in
                    fact("Mio 本机连接", value: Self.mioTitle(store.modules.value?.mioStatus(at: timeline.date)), symbol: "link")
                }
                if let queue=store.scheduler {
                    Divider()
                    fact("模型任务",value:Self.queueTitle(running:queue.running, queued:queue.queued),symbol:"cpu")
                }
            }
            ApplicationConnectionsView(registry: store.control.registry.value,
                                       nasEnabled: !store.demo && !store.isolated,
                                       nasChangesAllowed: !store.nativeActionsHeld)
        }.frame(maxWidth: 880, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
    }
    static func runtimeTitle(state: String?, connected: Bool, hasIssue: Bool) -> String {
        if hasIssue { return "需要处理" }
        guard connected else { return "未连接" }
        switch state {
        case "ready": return "运行中"
        case "starting": return "正在启动"
        case "stopping": return "正在停止"
        case "stopped": return "已停止"
        case "error": return "需要处理"
        default: return "未检查"
        }
    }
    static func mioTitle(_ status: MioTunnelStatus?) -> String {
        switch status {
        case .ready: "已连接"
        case .live: "等待隧道就绪"
        case .notReady: "需要处理"
        case .unavailable: "未连接"
        case .failed: "状态暂不可用"
        case .stale: "等待状态更新"
        case .unknown, nil: "未检查"
        }
    }
    static func queueTitle(running: Int, queued: Int) -> String {
        switch (running, queued) {
        case (0, 0): "空闲"
        case (0, _): "\(queued) 项排队"
        case (_, 0): "\(running) 项执行中"
        default: "\(running) 项执行中 · \(queued) 项排队"
        }
    }
    private func fact(_ title: String, value: String, symbol: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).frame(width: 20).foregroundStyle(.secondary).accessibilityHidden(true)
            Text(title)
            Spacer()
            if ["运行中","已连接"].contains(value) {ConnectionIndicator(ready:true,title:title)}
            else if ["未检查","正在启动","等待状态更新","等待隧道就绪"].contains(value) {
                ConnectionIndicator(ready:false,pending:true,title:title,text:value)
            }
            else {Text(value).foregroundStyle(.secondary)}
        }.font(.system(size: 13)).padding(.vertical, 17)
    }
}
