import SwiftUI
import AppKit

@MainActor struct CodexPackagesSettingsView: View {
    @State private var settings: CodexPackageSettingsStore
    @State private var explicit: CodexExecutionSelection?
    @State private var copied = false
    init(home: URL, enabled: Bool) { _settings = State(initialValue:CodexPackageSettingsStore(home:home,enabled:enabled)) }
    var body: some View {
        DetailCard(title:"模型套餐") {
            Text("每档可独立选择模型、思考强度和加速。应用按套餐发起的新任务使用此配置，已有任务保持原参数。")
                .font(.caption).foregroundStyle(.secondary)
            if !settings.enabled {
                Text("请在正式连接中配置模型套餐。").foregroundStyle(.secondary)
            } else if let catalog = settings.catalog, let saved = settings.saved {
                HStack(spacing:12) {
                    Text("套餐").frame(width:80,alignment:.leading)
                    Text("模型").frame(maxWidth:.infinity,alignment:.leading)
                    Text("思考强度").frame(width:100,alignment:.leading)
                    Text("加速").frame(width:66,alignment:.leading)
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
                            Toggle("加速",isOn:Binding(get:{ settings.draft[id]?.tier == "fast" },set:{ settings.draft[id]?.service_tier = $0 ? "fast" : "default" }))
                                .toggleStyle(.checkbox).frame(width:66,alignment:.leading)
                                .disabled(row.tier != "fast" && catalog.models.first(where:{ $0.model == row.model })?.fast_available != true)
                                .accessibilityLabel("\(id) 套餐加速")
                        }
                    }
                }
                HStack {
                    Button("保存套餐") { settings.save() }.disabled(!settings.valid || !settings.changed)
                    Button("重新读取") { settings.reload() }.help("读取当前已保存配置，放弃未保存修改。")
                    Spacer()
                    if settings.changed { Text("未保存").font(.caption).foregroundStyle(.secondary) }
                    Text("版本 \(saved.revision)").font(.caption).foregroundStyle(.secondary)
                }
                if !catalog.isFresh() { Text("模型目录已过期，等待 Codex 自动更新。").font(.caption).foregroundStyle(.orange) }
                else if !settings.valid { Text("请检查各档模型、思考强度和加速是否仍受当前目录支持。").font(.caption).foregroundStyle(.orange) }
                DisclosureGroup("应用接入选项") {
                    CodexExecutionSelector(catalog:catalog.execution, selection:explicit ?? catalog.current, disabled:false, choose:{ explicit = $0; copied = false })
                    HStack {
                        Button("复制模型与强度选项") {
                            let selected = explicit ?? catalog.current
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString("arl/option/" + selected.model + "/" + selected.reasoning_effort + (selected.fast ? "/fast" : ""),forType:.string)
                            copied = true
                        }
                        if copied { Text("已复制").font(.caption).foregroundStyle(.secondary) }
                    }
                    Text("套餐调用名：arl/package/medium；medium 可换为 low、high、very_high 或 highest。")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if let stamp = catalog.refreshed_at_ms {
                    Text("来源：本机 Codex · 目录更新于 \(Date(timeIntervalSince1970:Double(stamp)/1000).formatted(date:.omitted,time:.standard))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("等待 Codex 提供模型目录。").foregroundStyle(.secondary)
                Button("重新读取") { settings.reload() }
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
