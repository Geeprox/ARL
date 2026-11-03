import SwiftUI
import AppKit

@MainActor struct CodexPackagesSettingsView: View {
    @State private var settings: CodexPackageSettingsStore
    let controller: CodexNativeController?
    init(home: URL, enabled: Bool, controller: CodexNativeController? = nil) { self.controller=controller; _settings = State(initialValue:CodexPackageSettingsStore(home:home,enabled:enabled)) }
    var body: some View {
        DetailCard(title:"模型套餐") {
            HStack {
                Text("应用按场景使用套餐，新任务采用保存后的配置。").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let controller {
                    ConnectionIndicator(ready:controller.status?.state == "ready" && controller.errorCode == nil,
                        pending:controller.status?.state == "preflight_pending",title:"Codex",
                        text:controller.status?.state == "ready" && controller.errorCode == nil ? "Codex 已连接":controller.errorCode == nil ? "Codex 连接中":"Codex 连接异常")
                }
            }
            if !settings.enabled {
                Text("请在正式连接中配置模型套餐。").foregroundStyle(.secondary)
            } else if let catalog = settings.catalog, settings.saved != nil {
                HStack(spacing:12) {
                    Text("套餐").frame(width:80,alignment:.leading)
                    Text("模型").frame(maxWidth:.infinity,alignment:.leading)
                    Text("思考强度").frame(width:100,alignment:.leading)
                    Image(systemName:"bolt").frame(width:40).accessibilityLabel("加速")
                }.font(.caption).foregroundStyle(.secondary)
                ForEach(CodexPackageSettingsStore.ids,id:\.self) { id in
                    if let row = settings.draft[id] {
                        HStack(spacing:12) {
                            TextField("套餐名称",text:Binding(get:{ settings.draft[id]?.display_name ?? "" },set:{ settings.draft[id]?.display_name = $0 }))
                                .frame(width:80).accessibilityLabel("\(id) 套餐名称")
                            EditorialMenu {
                                ForEach(catalog.models) { option in
                                    Button { settings.selectModel(option.model,for:id) } label: {
                                        Label(option.display_name,systemImage:option.model == row.model ? "checkmark" : "cpu")
                                    }
                                }
                            } label: {
                                Text(catalog.models.first(where:{ $0.model == row.model })?.display_name ?? "不可用：\(row.model)")
                                    .lineLimit(1).truncationMode(.middle)
                            }.frame(maxWidth:.infinity).accessibilityLabel("\(id) 套餐模型")
                            EditorialMenu {
                                ForEach(catalog.models.first(where:{ $0.model == row.model })?.efforts ?? []) { effort in
                                    Button { settings.draft[id]?.reasoning_effort = effort.id } label: {
                                        Label(effort.title,systemImage:effort.id == row.reasoning_effort ? "checkmark" : "brain")
                                    }
                                }
                            } label: { Text(CodexEffortOption.title(row.reasoning_effort)) }
                                .frame(width:100).accessibilityLabel("\(id) 套餐思考强度")
                            Button {
                                settings.draft[id]?.service_tier = row.tier == "fast" ? "default" : "fast"
                            } label: {
                                Image(systemName:row.tier == "fast" ? "bolt.fill" : "bolt")
                                    .frame(width:16,height:32)
                            }.buttonStyle(EditorialActionButtonStyle(emphasis:row.tier == "fast" ? .primary:.quiet))
                                .disabled(row.tier != "fast" && catalog.models.first(where:{ $0.model == row.model })?.fast_available != true)
                                .accessibilityLabel("\(row.display_name)套餐加速").accessibilityValue(row.tier == "fast" ? "开启":"关闭")
                                .help("Fast 加速，可能更快消耗额度")
                        }
                    }
                }
                HStack {
                    Stepper("同时执行 \(settings.maxParallel) 项模型任务",value:Binding(get:{settings.maxParallel},set:{settings.setParallel($0)}),in:1...8)
                        .fixedSize()
                    Spacer()
                    if settings.changed { Button("保存套餐") { settings.save() }.disabled(!settings.valid) }
                }.padding(.top,8)
                if !catalog.isFresh() { Text("正在更新模型目录…").font(.caption).foregroundStyle(.secondary) }
                else if !settings.valid { Text("部分套餐的模型选项已变化，请重新选择。").font(.caption).foregroundStyle(.orange) }
            } else {
                Text("等待 Codex 提供模型目录。").foregroundStyle(.secondary)
            }
            if let message = settings.message { Text(message).font(.caption).foregroundStyle(.secondary) }
        }.task {
            guard settings.enabled else { return }
            settings.reload()
            while !Task.isCancelled {
                do { try await Task.sleep(for:.seconds(5)) } catch { return }
                settings.reload(preservingDraft:true)
            }
        }
    }
}
