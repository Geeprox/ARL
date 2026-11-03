import SwiftUI
import Darwin
import CryptoKit

struct PreferencesView: View {
    @AppStorage("refreshAutomatically") private var refresh = true
    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: EditorialStyle.sectionSpacing) {
            EditorialHeading(title: "偏好设置", subtitle: "")
            Text("模型与套餐请在主窗口的“模型”页设置。").font(.caption).foregroundStyle(.secondary)
            DetailCard(title: "状态更新") {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("自动刷新").font(.callout.weight(.medium))
                        Text("每 5 秒").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    Toggle("自动刷新", isOn: $refresh).labelsHidden().toggleStyle(.switch)
                        .accessibilityLabel("自动刷新")
                }
                Divider()
                HStack {
                    Text("手动刷新").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Text("⌘ R").font(.system(.caption, design: .monospaced).weight(.medium))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(EditorialStyle.canvas, in: RoundedRectangle(cornerRadius: 4))
                        .accessibilityLabel("Command R")
                }
            }
        }.padding(24)
        }.frame(width: 540, height: 310)
            .background(EditorialStyle.canvas).tint(EditorialStyle.accent)
    }
}
struct StatusMenu: View {
    let store: RuntimeStore
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text(store.demo ? "ARL · 演示" : "ARL · \(store.title)")
        if let snapshot = store.snapshot { Text("待处理 \(snapshot.outstanding)") }
        Divider()
        Button("打开 ARL") {
            NSApp.setActivationPolicy(.regular)
            openWindow(id: "control")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("刷新状态") { Task { await store.refresh() } }.keyboardShortcut("r")
        SettingsLink { Text("偏好设置") }
        Divider()
        Button("退出界面") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
    }
}

