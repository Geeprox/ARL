import SwiftUI

/// A presentation-only control. Options and availability come from the live
/// app-server catalog; the controller owns persistence and request submission.
@MainActor struct CodexExecutionSelector: View {
    let catalog: CodexExecutionCatalog?
    let selection: CodexExecutionSelection?
    var disabled = false
    let choose: (CodexExecutionSelection) -> Void
    private var model: CodexExecutionModel? { catalog?.models.first { $0.id == selection?.model } }
    private var available: Bool { catalog?.selection_enabled == true && !disabled }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Menu {
                    ForEach(catalog?.models ?? []) { option in
                        Button { choose(option.selecting(from: selection)) } label: {
                            Label(option.display_name, systemImage: option.id == selection?.model ? "checkmark" : "cpu")
                        }.help(option.description)
                    }
                } label: {
                    Label(model?.display_name ?? selection?.model ?? "载入可用模型", systemImage: "cpu")
                }.menuStyle(.borderlessButton).menuIndicator(.hidden)
                    .padding(.leading, 10).padding(.trailing, 24).frame(height: 32).frame(maxWidth: .infinity)
                    .background(EditorialStyle.panel, in: RoundedRectangle(cornerRadius: 6))
                    .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(EditorialStyle.rule, lineWidth: 0.5).allowsHitTesting(false) }
                    .overlay(alignment: .trailing) {
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary).padding(.trailing, 10).allowsHitTesting(false)
                    }
                    .disabled(!available).accessibilityLabel("Codex 模型").accessibilityValue(model?.display_name ?? "未载入")
                Button {
                    if var next = selection { next.service_tier = next.fast ? "default" : "fast"; choose(next) }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: selection?.fast == true ? "bolt.fill" : "bolt")
                        Text("加速").fontWeight(.medium)
                        Text(selection?.fast == true ? "开启" : model?.fast_available == true ? "关闭" : "不可用").font(.caption)
                    }.padding(.horizontal, 10).frame(height: 32)
                    .foregroundStyle(selection?.fast == true ? EditorialStyle.accent : .secondary)
                    .background(selection?.fast == true ? EditorialStyle.accent.opacity(0.09) : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 6))
                    .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(selection?.fast == true ? EditorialStyle.accent.opacity(0.5) : EditorialStyle.rule, lineWidth: 0.5) }
                }.buttonStyle(.plain).disabled(!available || model?.fast_available != true)
                    .accessibilityLabel("Codex 加速").accessibilityValue(selection?.fast == true ? "开启" : "关闭")
                    .accessibilityAddTraits(selection?.fast == true ? .isSelected : [])
                    .help(model?.fast_available == true ? "使用模型目录公布的 Fast 档位，可能更快消耗额度。" : "当前模型目录未公布 Fast 支持。")
            }
            if let model {
                HStack(spacing: 12) {
                    Text("思考强度").font(.caption).foregroundStyle(.secondary)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 4) { ForEach(model.efforts) { effort in effortButton(effort) } }
                        Menu {
                            ForEach(model.efforts) { effort in
                                Button { selectEffort(effort.id) } label: { Label(effort.title, systemImage: selection?.reasoning_effort == effort.id ? "checkmark" : "brain") }
                            }
                        } label: { Text(CodexEffortOption.title(selection?.reasoning_effort ?? model.default_effort)) }
                    }.disabled(!available)
                    Spacer(minLength: 0)
                }
                if let selection, !model.permits(selection) {
                    Label("保存的组合当前不可用，请重新选择。", systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(EditorialStyle.accent)
                }
            } else {
                Label(selection == nil ? "检查服务后载入可用模型与能力" : "保存的模型当前未列出，请重新选择", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if catalog?.source == "test_double" { Text("离线合成目录 · 未调用真实模型").font(.caption2).foregroundStyle(.secondary) }
        }.font(.system(size: 12)).foregroundStyle(EditorialStyle.graphite)
    }
    private func selectEffort(_ value: String) {
        if var next = selection { next.reasoning_effort = value; choose(next) }
    }
    private func effortButton(_ effort: CodexEffortOption) -> some View {
        let selected = effort.id == selection?.reasoning_effort
        return Button { selectEffort(effort.id) } label: {
            Text(effort.title).font(.system(size: 11, weight: selected ? .semibold : .medium))
                .padding(.horizontal, 10).frame(height: 28)
                .foregroundStyle(selected ? EditorialStyle.accent : .secondary)
                .background(selected ? EditorialStyle.accent.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 6))
                .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? EditorialStyle.accent.opacity(0.5) : .clear, lineWidth: 0.5) }
        }.buttonStyle(.plain).help(effort.description)
            .accessibilityLabel("思考强度：" + effort.title).accessibilityAddTraits(selected ? .isSelected : [])
    }
}
