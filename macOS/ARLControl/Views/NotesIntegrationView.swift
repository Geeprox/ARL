import SwiftUI

struct NotesIntegrationView: View {
    let controller: NotesPermissionController

    var body: some View {
        DetailCard(title: "备忘录") {
            HStack {
                Text("接入状态").font(.callout)
                Spacer()
                StatusBadge(title: controller.configuredState == "admitted" ? "检查权限" : "未开放").help(controller.configuredState == "admitted" ? "只检查已有权限" : "")
            }
            Text(serviceDescription).font(.callout).foregroundStyle(.secondary)
            if controller.configuredState == "admitted" {
                ForEach(NotesIntegrationRecord.records) { record in
                    HStack {
                        VStack(alignment: .leading) { Text(record.title).font(.callout); Text(record.displayExplanation).font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        StatusBadge(title: controller.permissionTitle(record.id))
                        if controller.canRequest(record.id) {
                            Button("申请权限") { Task { await controller.request() } }.help("申请所选操作的系统权限").disabled(controller.busy)
                        }
                    }.padding(.vertical, 5)
                }
                Button("检查权限") { Task { await controller.checkStatus() } }.disabled(!controller.canCheckStatus)
                Text(("点击申请权限会直接进入系统自动化授权流程；此操作不会读取或创建备忘录。"))
                    .font(.caption).foregroundStyle(.secondary)
                Button("检查配置") { controller.refreshConfiguration() }.disabled(controller.busy)
                if controller.busy { Button("取消请求") { controller.cancel() } }
            }
            Text(("系统自动化权限与读取、搜索、创建备忘录的操作范围分别确认。")).font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("权限范围") {
                VStack(alignment: .leading, spacing: 7) {
                    Text("追加内容和附件目前不可用。")
                    Text("系统设置 → 隐私与安全性 → 自动化")
                }.font(.caption).foregroundStyle(.secondary).padding(.top, 6)
            }.help("系统权限与执行范围分别确认").font(.caption)
            if let message = controller.message { Text(message).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private var serviceDescription: String {
        switch controller.configuredState {
        case "admitted": return ("内部服务已配置。请先检查权限；具体操作仍需单独确认。")
        case "verified_disabled": return "服务已停用，无法访问备忘录。"
        case "expired": return "接入请求已过期，需要重新核验服务设置。"
        case "identity_unverified": return "内部服务身份未通过核验，权限请求不可用。"
        case "source_held", "not_deployed": return ("备忘录服务尚未接入当前安装，无法请求权限或读取内容。")
        default: return "尚未检查备忘录权限。"
        }
    }
}
