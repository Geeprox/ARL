import SwiftUI
import AppKit
import ARLCredentialOnboarding

struct MomentsView: View {
    let controller: MomentsController
    @ObservedObject var nas: ARLNASSetupModel
    @State private var choosingNAS = false
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            GroupBox {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Label("本地朋友圈", systemImage: "photo.stack")
                            .font(.headline)
                        Spacer()
                        Text(controller.collecting ? (controller.running ? "后台运行" : "准备中") : "已暂停").foregroundStyle(.secondary)
                    }
                    Text("自动读取本机微信已保存的朋友圈，备份文字、互动和媒体。Mac 需要保持运行。")
                        .foregroundStyle(.secondary)
                    if controller.configuration != nil {
                        HStack(spacing: 28) {
                            LabeledContent("朋友圈", value: "\(controller.postCount) 条")
                            LabeledContent("图片待补齐", value: "\(controller.remainingImages) 张")
                            LabeledContent("下载失败", value: "\(controller.failedImages) 张")
                        }
                        if let date = controller.captureDate { Text("最近读取本机数据 \(date.formatted())").font(.caption).foregroundStyle(.secondary) }
                        if let latest = controller.latestPost { Text("归档最新帖子 \(latest)").font(.caption).foregroundStyle(.secondary) }
                        HStack {
                            Button("打开朋友圈") { NSWorkspace.shared.open(controller.viewerURL) }.buttonStyle(.borderedProminent)
                            Button(controller.collecting ? "暂停采集" : "启动采集") { Task { await controller.toggle() } }.disabled(controller.busy)
                        }
                    } else {
                        Button("导入现有归档…") { controller.importArchive() }.buttonStyle(.borderedProminent).disabled(!controller.available)
                    }
                    if let message = controller.message {
                        Text(explanation(message)).font(.callout).foregroundStyle(.secondary)
                        if controller.needsDiskAccess {
                            Button("打开完全磁盘访问权限") { controller.grantDiskAccess() }
                            Text("请允许 ARL 读取微信数据。无需为单独的 Python 授权。").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 16) {
                    Label("NAS 备份", systemImage: "externaldrive.connected.to.line.below").font(.headline)
                    Text("使用 ARL 已保存的 SMB 登录选择目录。既有 JSON、图片和视频会一起搬入 Friday，校验完成后释放 Mac 上的媒体空间。")
                        .foregroundStyle(.secondary)
                    LabeledContent("保存位置") {
                        Text(controller.destination).textSelection(.enabled).lineLimit(2).truncationMode(.middle)
                    }
                    HStack {
                        Button(controller.configuration?.nasDestination == nil ? "选择 NAS 文件夹…" : "更换位置…") { choosingNAS = true }
                            .disabled(controller.configuration == nil || controller.syncing || !controller.available || nas.archivePickerOwner == nil)
                        if controller.configuration?.nasDestination != nil { Button("在 Finder 中打开") { controller.openNAS() } }
                        Spacer()
                        if controller.syncing { ProgressView().controlSize(.small); Text("正在同步").foregroundStyle(.secondary) }
                    }
                    if let date = controller.nasDate { Text("最近同步完成 \(date.formatted())").font(.caption).foregroundStyle(.secondary) }
                    if let error = controller.nasError { Text(error).font(.callout).foregroundStyle(.secondary) }
                    Divider()
                    Text("通过所选 NAS 目录访问归档。").font(.caption).foregroundStyle(.secondary)
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("图片沿用现有低频队列。视频号保持暂停；风险停止记录会持续保留。").font(.caption).foregroundStyle(.secondary)
        }.sheet(isPresented: $choosingNAS) {
            if let owner = nas.archivePickerOwner {
                MomentsNASPicker(owner: owner) { controller.selectNAS($0) }
            }
        }
    }
    private func explanation(_ code: String) -> String {
        switch code {
        case "full_disk_access_required": "ARL 尚未获得微信数据目录的读取权限。"
        case "download_stop_preserved": "图片队列已暂停，停止记录持续保留；这本身不代表已确认风控。"
        case "risk_stop_preserved": "采集已因停止记录暂停，请先检查微信和下载状态。"
        case "worker_stopped": "后台任务已退出。请检查日志后重新启动采集；不会自动重试失败图片。"
        case "source_changed", "capture_busy": "正在等待本地数据写入稳定。"
        case "archive_configuration_missing": "这个文件夹中没有可用的归档配置。"
        default: "操作尚未完成（\(code)）。原有归档已保留。"
        }
    }
}
