import SwiftUI

struct EditorialSidebar: View {
    @Binding var selection: ControlSection?
    let connected: Bool
    let statusColor: Color
    private let visibleOrder: [ControlSection] = [.overview, .models, .credentials, .capabilities, .moments, .performance, .logs, .advanced]
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 5) {
                Text("ARL").font(.system(size: 23, weight: .bold))
                Text("Agent Runtime").font(.system(size: 11)).foregroundStyle(.secondary)
            }.padding(.horizontal, 10).padding(.top, 4)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    destinations([.overview, .models, .credentials, .capabilities, .moments])
                    VStack(alignment: .leading, spacing: 8) {
                        Text("诊断").foregroundStyle(.secondary).padding(.horizontal, 10)
                        destinations([.performance, .logs, .advanced])
                    }
                }.font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
            }.scrollIndicators(.hidden)
        }.padding(.horizontal, 12).padding(.top, 20).padding(.bottom, 16)
            .frame(minWidth: 175, idealWidth: 208, maxWidth: 230, maxHeight: .infinity)
            .background(EditorialStyle.sidebar)
            .onMoveCommand { direction in
                let current = visibleOrder.firstIndex(of: selection ?? .overview) ?? 0
                if direction == .down { selection = visibleOrder[min(visibleOrder.count - 1, current + 1)] }
                if direction == .up { selection = visibleOrder[max(0, current - 1)] }
            }
    }
    private func title(_ section: ControlSection) -> String {
        switch section {
        case .overview: "运行概览"
        case .credentials: "服务连接"
        case .models: "模型"
        case .capabilities: "应用接入"
        case .advanced: "运行诊断"
        default: section.displayTitle
        }
    }
    private func shortcut(_ section: ControlSection) -> KeyEquivalent {
        if section == .models { return "k" }
        let index = visibleOrder.firstIndex(of: section) ?? 0
        return KeyEquivalent(Character(String((index + 1) % 10)))
    }
    private func destinations(_ sections: [ControlSection]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(sections) { section in
                let selected = selection == section
                Button { selection = section } label: {
                    HStack(spacing: 10) {
                        Image(systemName: section == .credentials ? "link" : section == .models ? "terminal" : section.icon)
                            .font(.system(size: 16)).frame(width: 21).accessibilityHidden(true)
                        Text(title(section)).font(.system(size: 13, weight: selected ? .semibold : .regular))
                        Spacer(minLength: 0)
                    }.padding(.horizontal, 10).frame(minHeight: 42).contentShape(Rectangle())
                }.buttonStyle(SidebarButtonStyle(selected: selected))
                    .keyboardShortcut(shortcut(section), modifiers: section == .models ? [.command, .shift] : .command)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .help(title(section) + "\n" + section.displayExplanation)
            }
        }
    }
}

private struct SidebarButtonStyle: ButtonStyle {
    let selected: Bool
    @Environment(\.isFocused) private var focused
    @State private var hovered = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.foregroundStyle(EditorialStyle.graphite)
            .background(selected ? EditorialStyle.panel : configuration.isPressed || hovered ? Color.primary.opacity(0.045) : .clear,
                        in: RoundedRectangle(cornerRadius: EditorialStyle.controlRadius))
            .overlay { RoundedRectangle(cornerRadius: EditorialStyle.controlRadius).strokeBorder(focused ? EditorialStyle.accent : .clear, lineWidth: 2) }
            .onHover { hovered = $0 }
    }
}
