import SwiftUI

struct ModelsView: View {
    let snapshot: RuntimeSnapshot?
    let control: ControlPlaneState
    var codex: CodexNativeController? = nil
    var body: some View {
        if let snapshot {
            VStack(alignment: .leading, spacing: 18) {
                if let codex { CodexTaskPanel(controller: codex) }
                DetailCard(title: "模型服务") {
                    if let providers = control.providerHealth.value {
                        if !providers.contains(where: { $0.id == "codex_app_server" }) { Text("Codex 尚未接通").foregroundStyle(.secondary) }
                        TimelineView(.periodic(from: .now, by: 5)) { timeline in
                            VStack(spacing: 0) {
                                ForEach(providers.filter { $0.id == "codex_app_server" }) { provider in
                                    DisclosureGroup {
                                        VStack(alignment: .leading, spacing: 10) {
                                            MetadataRow(title: "模型调用", value: provider.inference_enabled ? "已启用" : "未启用")
                                            MetadataRow(title: "模型加载", value: provider.model_load_state == "not_applicable" ? "不适用" : "未知")
                                            MetadataRow(title: "模型目录", value: provider.catalog_models.isEmpty ? "没有" : provider.catalog_models.joined(separator: "、"))
                                            if let time = provider.checked_at_ms { MetadataRow(title: "上次检查", value: Date(timeIntervalSince1970: Double(time) / 1000).formatted(date: .omitted, time: .standard)) }
                                        }.padding(.leading, 50).padding(.vertical, 10)
                                    } label: {
                                        HStack(spacing: 14) {
                                            AppIcon(id: provider.id, symbol: "cpu", size: 38)
                                            VStack(alignment: .leading, spacing: 5) { Text(provider.title).font(.callout.weight(.semibold)); Text(provider.inference_enabled ? "已启用" : "未启用").font(.caption).foregroundStyle(.secondary) }
                                            Spacer(minLength: 12)
                                            StatusBadge(title: provider.isStale(at: timeline.date) ? "状态过期" : provider.stateTitle, color: provider.isStale(at: timeline.date) ? .secondary : provider.state == "ready" ? .green : provider.state == "discovered" ? EditorialStyle.graphite : .secondary)
                                        }.padding(.vertical, 7)
                                    }
                                    if provider.id != providers.last?.id { Divider() }
                                }
                            }
                        }
                    } else {
                        ForEach(snapshot.providers.filter { $0.name == "codex_app_server" }) { provider in HStack { AppIcon(id: provider.id, symbol: "cpu"); Text(provider.title).font(.callout.weight(.medium)); Spacer(); StatusBadge(title: provider.availability == "ready" ? "已发现" : provider.availability == "disabled" ? "已关闭" : "未就绪") } }
                    }
                }
            }
        } else { EmptyRuntimeView() }
    }
}
