import SwiftUI
import AppKit
import ARLCredentialOnboarding

struct MomentsView: View {
    let controller: MomentsController
    @ObservedObject var nas: ARLNASSetupModel
    @State private var choosingNAS = false
    @State private var confirmingImages = false
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            GroupBox {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Label("本地朋友圈", systemImage: "photo.stack")
                            .font(.headline)
                        Spacer()
                        ConnectionIndicator(ready:controller.collecting && controller.running,
                            pending:controller.collecting && !controller.running,title:"朋友圈采集",inactive:!controller.collecting,
                            text:controller.collecting ? (controller.running ? "后台运行":"准备中") : "已暂停")
                    }
                    Text("自动读取本机微信已保存的朋友圈，备份文字、互动和媒体。Mac 需要保持运行。")
                        .foregroundStyle(.secondary)
                    if controller.configuration != nil {
                        LazyVGrid(columns:[GridItem(.adaptive(minimum:140),alignment:.leading)],alignment:.leading,spacing:12) {
                            metric("已归档",value:controller.postCount,unit:"条朋友圈")
                            metric("等待下载",value:controller.remainingImages,unit:"张图片")
                            metric("下载未完成",value:controller.failedImages,unit:"张图片")
                        }
                        if let date = controller.captureDate { Text("最近读取本机数据 \(date.formatted())").font(.caption).foregroundStyle(.secondary) }
                        if let latest = controller.latestPost, let date=ISO8601DateFormatter().date(from:latest) {
                            Text("最新归档 \(date.formatted(date:.abbreviated,time:.shortened))").font(.caption).foregroundStyle(.secondary)
                        }
                        HStack {
                            Button("打开朋友圈",systemImage:"arrow.up.right") { NSWorkspace.shared.open(controller.viewerURL) }
                                .buttonStyle(EditorialActionButtonStyle(emphasis:.primary))
                            Button(controller.collecting ? "暂停采集" : "启动采集") { Task { await controller.toggle() } }.disabled(controller.busy)
                            if controller.failedImages>0 || controller.remainingImages>0 {
                                if controller.canReconfirmImages {
                                    Button(controller.recoveryPending ? "正在恢复…":"恢复图片下载…",systemImage:"play") {
                                        confirmingImages=controller.prepareImageResume()
                                    }.disabled(!controller.collecting || controller.recoveryPending)
                                } else {
                                Button(controller.recoveryPending ? "正在检查…":controller.imageDownloadIssue == nil ? "检查并补齐图片":"检查下载状态",systemImage:"arrow.triangle.2.circlepath") {controller.recoverImages()}
                                    .disabled(!controller.collecting || controller.recoveryPending || controller.imageStopPreserved)
                                }
                            }
                        }
                        if let issue=controller.imageDownloadIssue {
                            Label(issue,systemImage:"pause.circle").font(.caption).foregroundStyle(.secondary)
                        }
                        if let result=controller.imageRecoveryMessage {
                            Text(result).font(.caption).foregroundStyle(.secondary)
                        }
                        if controller.failedImages>0 {
                            Text("临时网络失败会自动重试；下载地址失效的图片，需要微信本地缓存更新后再补齐。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        Button("导入现有归档…") { controller.importArchive() }
                            .buttonStyle(EditorialActionButtonStyle(emphasis:.primary)).disabled(!controller.available)
                    }
                    if let message = controller.message {
                        Text(explanation(message)).font(.callout).foregroundStyle(.secondary)
                        if controller.needsDiskAccess {
                            Button("打开完全磁盘访问权限") { controller.grantDiskAccess() }
                            Text("请允许 ARL 读取微信数据。无需为单独的 Python 授权。").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Divider()
                    Text("图片会逐步补齐；视频号下载保持暂停。").font(.caption).foregroundStyle(.secondary)
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Label("NAS 备份", systemImage: "externaldrive.connected.to.line.below").font(.headline)
                        Spacer()
                        ConnectionIndicator(ready:controller.nasDate != nil && controller.nasError == nil,pending:controller.syncing,
                            title:"NAS 备份",inactive:controller.configuration?.nasDestination == nil,
                            text:controller.syncing ? "正在同步":controller.nasError != nil ? "同步未完成":controller.nasDate != nil ? "已同步":"尚未同步")
                    }
                    Text("文字、互动和媒体会备份到所选文件夹。校验完成后，再释放 Mac 上已备份媒体占用的空间。")
                        .foregroundStyle(.secondary)
                    LabeledContent("保存位置") {
                        Text(controller.destination).textSelection(.enabled).lineLimit(2).truncationMode(.middle)
                    }
                    HStack {
                        Button(controller.configuration?.nasDestination == nil ? "选择 NAS 文件夹…" : "更换位置…") { choosingNAS = true }
                            .disabled(controller.configuration == nil || controller.syncing || !controller.available || nas.archivePickerOwner == nil)
                        if controller.configuration?.nasDestination != nil {
                            Button("在 Finder 中打开") { controller.openNAS() }.disabled(!controller.canOpenNAS)
                            if controller.nasError != nil {Button("重试备份",systemImage:"arrow.clockwise") {controller.retryNASBackup()}.disabled(controller.syncing)}
                        }
                    }
                    if let date = controller.nasDate { Text("最近同步完成 \(date.formatted())").font(.caption).foregroundStyle(.secondary) }
                    if let error = controller.nasError { Label(error,systemImage:"exclamationmark.circle").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true) }
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            }
        }.sheet(isPresented: $choosingNAS) {
            if let owner = nas.archivePickerOwner {
                MomentsNASPicker(owner: owner) { controller.selectNAS($0) }
            }
        }.confirmationDialog("恢复图片下载？",isPresented:$confirmingImages,titleVisibility:.visible) {
            Button("恢复图片下载") {controller.reconfirmImages()}
            Button("取消",role:.cancel) {controller.cancelImageResume()}
        } message: {
            Text("磁盘标识变化使旧授权暂停。确认后继续原先允许的图片下载，视频号仍保持暂停。下载地址失效的图片会等待微信缓存更新。")
        }
    }
    private func metric(_ title:String,value:Int,unit:String)->some View {
        VStack(alignment:.leading,spacing:5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack(alignment:.firstTextBaseline,spacing:5) {
                Text(value,format:.number).font(.system(size:21,weight:.semibold)).monospacedDigit()
                Text(unit).font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.vertical,4).accessibilityElement(children:.combine)
    }
    private func explanation(_ code: String) -> String {
        switch code {
        case "full_disk_access_required": "ARL 尚未获得微信数据目录的读取权限。"
        case "download_stop_preserved": "图片队列已暂停，停止记录持续保留；这本身不代表已确认风控。"
        case "risk_stop_preserved": "采集已因停止记录暂停，请先检查微信和下载状态。"
        case "worker_stopped","worker_launch_failed": "后台任务正在自动恢复。"
        case "source_changed", "capture_busy": "正在等待本地数据写入稳定。"
        case "archive_configuration_missing": "这个文件夹中没有可用的归档配置。"
        default: "操作尚未完成（\(code)）。原有归档已保留。"
        }
    }
}
