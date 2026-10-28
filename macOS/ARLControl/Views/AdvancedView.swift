import SwiftUI

struct AdvancedView: View {
    let store: RuntimeStore
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            DisclosureGroup("后台详情") {
                MetadataRow(title: "版本", value: store.snapshot?.version ?? "—")
                MetadataRow(title: "协议", value: store.snapshot?.protocol ?? "—")
                MetadataRow(title: "连接", value: store.connected ? "本机" : "未连接")
                MetadataRow(title: "任务执行", value: store.control.runtime.value.map { $0.task_execution_enabled ? "已启用" : "已关闭" } ?? "未知")
                MetadataRow(title: "身份核验", value: store.snapshot.map { $0.policy.identity_verifier_configured ? "已配置" : "未配置" } ?? "未知")
            }
            ModelsView(snapshot: store.snapshot, control: store.control)
            if let snapshot = store.snapshot {
                DetailCard(title: "调用限额") {
                    ForEach(snapshot.budgets.filter { budget in AppRegistration.connected(store.control.registry.value ?? [], at: Date()).contains { $0.id == budget.app } }) { budget in
                        DisclosureGroup(store.control.registry.value?.first { $0.id == budget.app }?.name ?? "应用") { VStack(spacing: 9) { MetadataRow(title: "任务上限", value: String(budget.max_pending)); MetadataRow(title: "调用上限", value: budget.max_calls.map(String.init) ?? "不设本地次数上限"); MetadataRow(title: "回答上限", value: "回答上限为\(budget.max_output_tokens) token") }.padding(.vertical, 9) }
                    }
                }
            }
            // Real credentials have one purpose-bound native entry point in
            // ContentView. Keep the in-memory fixture exclusive to demo mode.
            if store.demo { CredentialsView(feature: store.control.credentials, demo: true) }
            FinderActionsSettingsView(preview: store.demo)
            DisclosureGroup("部署方案") { ServicePortalView(service: store.service, connectionAvailable: store.connected) }
        }
    }
}
