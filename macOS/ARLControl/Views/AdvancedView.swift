import SwiftUI

struct AdvancedView: View {
    let store: RuntimeStore
    @State private var developerSettings = false
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            ModelsView(snapshot:store.snapshot,control:store.control)
            if let snapshot = store.snapshot {
                let connected = AppRegistration.connected(store.control.registry.value ?? [],at:Date())
                let budgets = snapshot.budgets.filter {budget in connected.contains{$0.id == budget.app}}
                if !budgets.isEmpty {
                    DetailCard(title:"应用调用限额") {
                        ForEach(budgets) {budget in
                            VStack(alignment:.leading,spacing:8) {
                                Text(connected.first{$0.id == budget.app}?.name ?? budget.app).font(.callout.weight(.medium))
                                MetadataRow(title:"同时等待的任务",value:String(budget.max_pending))
                                MetadataRow(title:"本地调用次数",value:budget.max_calls.map(String.init) ?? "不限")
                            }
                        }
                    }
                }
            }
            FinderActionsSettingsView(preview:store.demo)
            DetailCard(title:"版本与接入") {
                MetadataRow(title:"ARL 版本",value:store.snapshot?.version ?? "暂不可读")
                HStack {
                    Text("应用发现、注册和部署信息").font(.caption).foregroundStyle(.secondary)
                    Spacer();Button("开发者接入…") {developerSettings=true}
                }
            }
            if store.demo {CredentialsView(feature:store.control.credentials,demo:true)}
        }.sheet(isPresented:$developerSettings) {
            VStack(alignment:.leading,spacing:18) {
                HStack {Text("开发者接入").font(.title2.weight(.semibold));Spacer();Button("完成") {developerSettings=false}}
                ScrollView {ServicePortalView(service:store.service,connectionAvailable:store.connected)}
            }.padding(24).frame(minWidth:620,minHeight:460)
        }
    }
}
