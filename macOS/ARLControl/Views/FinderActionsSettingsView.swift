import SwiftUI
import FinderSync
import AppKit

struct FinderActionsSettingsView: View {
    let preview: Bool
    @State private var extensionEnabled = false
    private var installed: Bool {
        !preview && Bundle.main.builtInPlugInsURL.map {
            FileManager.default.fileExists(atPath:$0.appendingPathComponent("ARLFinderActions.appex/Contents/Info.plist").path)
        } == true
    }
    var body: some View {
        DetailCard(title:"") {
            HStack(spacing:12) {
                Image(systemName:"folder.badge.gearshape").font(.system(size:22)).foregroundStyle(.secondary).frame(width:32)
                Text("访达右键菜单").font(.headline);Spacer()
                ConnectionIndicator(ready:extensionEnabled,title:"访达扩展",inactive:!extensionEnabled,text:installed ? (extensionEnabled ? "扩展已启用":"待启用"):"未安装")
            }
            Text("在访达中右键文件或文件夹，选择「访达动作」。").font(.callout).foregroundStyle(.secondary)
            HStack(alignment:.top,spacing:24) {
                action("拷贝路径",symbol:"doc.on.doc",detail:"完整路径，多选时逐行拷贝")
                action("在终端打开",symbol:"terminal",detail:"在所选文件夹中打开终端")
            }
            if installed && !extensionEnabled {
                Button("启用访达扩展…") {FIFinderSyncController.showExtensionManagementInterface()}
            }
        }.onAppear{refresh()}
            .onReceive(NotificationCenter.default.publisher(for:NSApplication.didBecomeActiveNotification)){_ in refresh()}
    }
    private func action(_ title:String,symbol:String,detail:String)->some View {
        HStack(alignment:.top,spacing:10) {
            Image(systemName:symbol).font(.system(size:16)).frame(width:20).padding(.top,1)
            VStack(alignment:.leading,spacing:5) {Text(title).font(.callout.weight(.medium));Text(detail).font(.caption).foregroundStyle(.secondary)}
        }.frame(maxWidth:.infinity,alignment:.leading)
    }
    private func refresh() {extensionEnabled = installed && FIFinderSyncController.isExtensionEnabled}
}
