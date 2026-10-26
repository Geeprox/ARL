import SwiftUI
import FinderSync
import AppKit

struct FinderActionsSettingsView: View {
    let preview: Bool
    @State private var extensionEnabled = false
    private var installed: Bool {
        !preview && Bundle.main.builtInPlugInsURL.map {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("ARLFinderActions.appex/Contents/Info.plist").path)
        } == true
    }
    var body: some View {
        DetailCard(title: "访达动作") {
            Text("右键拷贝路径，或在终端打开目录。").font(.callout).foregroundStyle(.secondary)
            HStack {
                StatusBadge(title: installed ? (extensionEnabled ? "已启用" : "待启用") : "待安装")
                Button("系统启用") { FIFinderSyncController.showExtensionManagementInterface() }.disabled(!installed)
                Button("刷新状态") { refresh() }.disabled(!installed)
            }
            Text("只在用户目录和挂载卷提供动作。").font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("使用详情") {
                Text("在系统扩展设置中勾选访达动作。")
                Text("多选路径会完整复制并换行。")
                Text("终端打开仅支持单个目录。")
                Text("网络硬盘使用已挂载的本机路径。")
                Text("未挂载硬盘请先在访达中连接。")
                Text("系统目录或其他位置可能不支持。")
                Text("菜单不可见时，请重新打开窗口。")
            }.font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }
    private func refresh() { extensionEnabled = installed && FIFinderSyncController.isExtensionEnabled }
}
