import SwiftUI

@MainActor struct CodexTaskPanel: View {
    let controller: CodexNativeController
    @State private var input = ""
    var body: some View {
        DetailCard(title: "Codex 文字任务") {
            CodexExecutionSelector(catalog: controller.executionCatalog, selection: controller.executionSelection,
                disabled: controller.busy, choose: controller.selectExecution)
            if let selection = controller.executionSelection {
                Text("下次任务 · " + selection.summary).font(.caption).foregroundStyle(.secondary)
            } else if let status = controller.status, let model = status.model {
                Text("服务默认 · \(model) · \(status.reasoning_effort ?? "待检查") · \(status.service_tier ?? "待检查")").font(.caption).foregroundStyle(.secondary)
            }
            if let status = controller.status {
                MetadataRow(title: "服务", value: title(status))
                MetadataRow(title: "剩余调用", value: status.remaining_calls.map(String.init) ?? "待检查")
                MetadataRow(title: "真实推理", value: status.simulated == true ? "合成测试" : status.inference_verified == true ? "已有成功回执" : "尚未验证")
                if let code = status.reason ?? status.last_error_code { Text(code).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            }
            TextEditor(text: $input).frame(minHeight: 80, maxHeight: 160)
                .overlay(alignment: .topLeading) { if input.isEmpty { Text("填写这一次要处理的文字").foregroundStyle(.tertiary).padding(6).allowsHitTesting(false) } }
            HStack {
                Button("提交文字任务") { controller.submit(input) }.disabled(!controller.canSubmit || input.isEmpty || input.utf8.count > 8192)
                Button("检查服务") { Task { await controller.refreshStatus() } }.disabled(controller.statusReading)
                if controller.taskRecord != nil {
                    Button(controller.taskRecord?.jobID == nil ? "核对原请求" : "核对原任务") { controller.inspectOriginal() }.disabled(!controller.canInspect)
                    Button("取消原任务") { controller.requestCancel() }
                        .disabled(controller.taskRecord?.jobID == nil || controller.taskRecord?.permitsNewIntent == true)
                }
            }
            if let record = controller.taskRecord {
                MetadataRow(title: "原任务", value: record.jobID?.uuidString.lowercased() ?? record.operationID.uuidString.lowercased())
                MetadataRow(title: "状态", value: phase(record.phase))
                if let selection = record.selection { MetadataRow(title: "原任务设置", value: selection.summary) }
                if let preferences = record.reply?.result?["execution_preferences"] {
                    Text("服务确认 · \(preferences["reasoning_effort"]?.text ?? "待确认") · \(preferences["service_tier"]?.text ?? "待确认")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let text = record.reply?.text { Text(text).textSelection(.enabled) }
                if let progress = record.reply?.progress {
                    DisclosureGroup("执行回执") { Text(String(decoding: (try? JSONEncoder().encode(progress)) ?? Data(), as: UTF8.self)).font(.caption).textSelection(.enabled) }
                }
            }
            if let message = controller.message { Text(message).font(.caption).foregroundStyle(.secondary) }
            if let code = controller.errorCode { Text(code).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
        }.task { await controller.refreshStatus() }
    }
    private func title(_ status: CodexServiceStatus) -> String {
        switch status.state {
        case "ready": status.inference_verified == true ? "可调用" : "连接检查通过"
        case "preflight_pending": "正在检查连接"
        case "budget_exhausted": "本次范围的调用已用完"
        case "not_configured": "尚未接通"
        default: "连接暂不可用"
        }
    }
    private func phase(_ value: String) -> String {
        switch value {
        case "prepared": "保留原请求，等待回执"
        case "queued": "等待执行"
        case "running": "正在执行"
        case "succeeded": "已完成"
        case "cancelled": "已取消"
        case "needs_review": "结果待核"
        default: "执行失败，请查看回执"
        }
    }
}
