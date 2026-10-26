import SwiftUI

struct OverviewView: View {
    let store: RuntimeStore
    var navigate: (ControlSection) -> Void = { _ in }
    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            EditorialHeading(title: "运行概览", subtitle: "")
            if let code = store.bundledRuntimeError {
                VStack(alignment: .leading, spacing: 10) {
                    Label("本机服务连接失败", systemImage: "exclamationmark.circle").font(.callout.weight(.semibold))
                    Text(code).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    Button(store.bundledRuntimeRecovering ? "正在恢复" : "恢复连接") { store.recoverBundledRuntime() }
                        .disabled(store.bundledRuntimeRecovering || store.nativeActionsHeld)
                }
            } else if let code = store.controlError {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("运行状态读取失败").font(.callout.weight(.semibold))
                        Text(code).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Spacer()
                    Button("重试") { Task { await store.refresh() } }.disabled(store.reading)
                }
            }
            VStack(spacing: 0) {
                fact("本机服务", value: Self.runtimeTitle(state: store.control.runtime.value?.state, connected: store.connected, hasIssue: store.bundledRuntimeError != nil || store.controlError != nil), symbol: "desktopcomputer")
                Divider()
                TimelineView(.periodic(from: .now, by: 5)) { timeline in
                    fact("Mio 本机连接", value: Self.mioTitle(store.modules.value?.mioStatus(at: timeline.date)), symbol: "link")
                }
                Divider()
                fact("Agent 执行", value: store.control.runtime.value.map { $0.task_execution_enabled ? "已启用" : "已停用" } ?? "未检查", symbol: "terminal")
            }
            TimelineView(.periodic(from: .now, by: 5)) { timeline in
                VStack(alignment: .leading, spacing: 14) {
                    Text("应用连接").font(.system(size: 15, weight: .semibold)).accessibilityAddTraits(.isHeader)
                    if let entries = store.control.registry.value {
                        let connected = AppRegistration.connected(entries, at: timeline.date)
                        if connected.isEmpty { Text("暂无已连接应用").foregroundStyle(.secondary).font(.callout) }
                        ForEach(connected) { app in
                            HStack(spacing: 12) {
                                AppIcon(id: app.id, symbol: app.symbol, registeredIcon: app.applicationIcon, iconHome: app.applicationIconHome, protocolIcon: true)
                                Text(app.name).font(.callout)
                                Spacer()
                                Text(app.connection).font(.callout).foregroundStyle(.secondary)
                            }
                        }
                    } else { Text("尚未检查应用连接").font(.callout).foregroundStyle(.secondary) }
                }
            }
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
        case .live: "已连接，状态待检查"
        case .notReady: "需要处理"
        case .unavailable: "未连接"
        case .failed: "检查失败"
        case .stale: "需要重新检查"
        case .unknown, nil: "未检查"
        }
    }
    private func fact(_ title: String, value: String, symbol: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).frame(width: 20).foregroundStyle(.secondary).accessibilityHidden(true)
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }.font(.system(size: 13)).padding(.vertical, 17)
    }
}
