import SwiftUI

struct ConsolidatedMessagesView: View {
    let feature: ConsolidatedMessagesFeature
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DetailCard(title: "信息 · 接入设置") {
                Text(feature.description).font(.callout).foregroundStyle(.secondary)
                HStack {
                    StatusBadge(title: feature.synthetic ? "合成测试" : feature.activationAllowed ? "等待独立核验" : "未激活")
                    Spacer()
                    Button("核验接入状态") { Task { await feature.refresh() } }.disabled(feature.demo)
                }
                Text("接收所需路径访问与发送 Automation 独立；系统权限不会授予发送预算。账户确认只是用户报告，Apple 服务端状态未检查。").font(.caption).foregroundStyle(.secondary)
            }.padding(22)
            // Actual owner panel/store/client; no replacement success callback.
            MessagesOnboardingView(store: feature.feature.store, embedded: true)
                .disabled(!feature.activationAllowed || feature.demo)
        }
        .task { await feature.refresh() }
    }
}
