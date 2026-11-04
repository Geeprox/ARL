import SwiftUI

struct ModelsView: View {
    let snapshot: RuntimeSnapshot?
    let control: ControlPlaneState
    var codex: CodexNativeController? = nil
    var body: some View {
        if let provider = control.providerHealth.value?.first(where:{$0.id == "codex_app_server"}) {
            DetailCard(title:"模型服务") {
                HStack(spacing:12) {
                    AppIcon(id:provider.id,symbol:"cpu",size:32)
                    VStack(alignment:.leading,spacing:4) {
                        Text(provider.title).font(.headline)
                        Text(provider.inference_enabled ? "模型调用已启用":"模型调用已关闭").font(.caption).foregroundStyle(.secondary)
                    }; Spacer()
                    ConnectionIndicator(ready:provider.state == "ready" && !provider.isStale(at:Date()),title:"Codex",text:provider.isStale(at:Date()) ? "状态待更新":provider.stateTitle)
                }
                if !provider.catalog_models.isEmpty {
                    Divider()
                    VStack(alignment:.leading,spacing:7) {
                        Text("可用模型 · \(provider.catalog_models.count) 个").font(.caption).foregroundStyle(.secondary)
                        LazyVGrid(columns:[GridItem(.adaptive(minimum:180),alignment:.leading)],alignment:.leading,spacing:8) {
                            ForEach(provider.catalog_models,id:\.self) {model in
                                Text(model).font(.callout).textSelection(.enabled)
                                    .frame(maxWidth:.infinity,alignment:.leading)
                            }
                        }
                    }
                }
                if let time = provider.checked_at_ms {
                    Text("最近检查 \(Date(timeIntervalSince1970:Double(time)/1000).formatted(date:.omitted,time:.shortened))").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}
