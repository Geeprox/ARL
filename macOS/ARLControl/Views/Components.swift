import SwiftUI

struct DetailCard<Content: View>: View {
    let title: String
    var height: CGFloat? = nil
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: height == nil ? 16 : 12) {
            if !title.isEmpty {
                Text(title).font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(EditorialStyle.graphite).accessibilityAddTraits(.isHeader)
            }
            content()
        }.padding(height == nil ? 20 : 16).frame(maxWidth: .infinity, alignment: .leading).frame(height: height, alignment: .top)
            .modifier(EditorialSurface())
            .buttonStyle(EditorialActionButtonStyle())
            .textFieldStyle(EditorialFieldStyle())
            .groupBoxStyle(EditorialGroupBoxStyle())
            .tint(EditorialStyle.accent)
    }
}

struct MetadataRow: View {
    let title: String
    let value: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 24) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
        }.font(.callout).padding(.vertical, 2)
    }
}

struct StatusBadge: View {
    let title: String
    var color: Color = .secondary
    var cornerRadius: CGFloat = 6
    var height: CGFloat? = nil
    private var contour: RoundedRectangle { RoundedRectangle(cornerRadius: cornerRadius, style: .continuous) }
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 5, height: 5).accessibilityHidden(true)
            Text(title).fixedSize(horizontal: false, vertical: true)
        }.font(.caption.weight(.medium)).foregroundStyle(EditorialStyle.graphite)
            .padding(.horizontal, 9).padding(.vertical, 5).frame(height: height)
            .background(color.opacity(0.075), in: contour)
            .overlay { contour.strokeBorder(color.opacity(0.16), lineWidth: 0.5) }
            .accessibilityElement(children: .combine)
    }
}

struct StatValue: View {
    let title: String
    let value: String
    var color: Color = .primary
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 26, weight: .semibold))
                .monospacedDigit().foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.75)
        }.frame(maxWidth: .infinity, alignment: .leading).accessibilityElement(children: .combine)
    }
}

/// Uses native Button activation, roles and keyboard focus; only its surface is custom.
struct EditorialActionButtonStyle: ButtonStyle {
    enum Emphasis { case primary, secondary, quiet }
    var emphasis: Emphasis = .secondary
    func makeBody(configuration: Configuration) -> some View {
        EditorialButtonSurface(configuration: configuration, emphasis: emphasis)
    }
}

private struct EditorialButtonSurface: View {
    let configuration: ButtonStyleConfiguration
    let emphasis: EditorialActionButtonStyle.Emphasis
    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isFocused) private var focused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false
    private var ink: Color {
        if configuration.role == .destructive { return .red }
        return emphasis == .primary ? (colorScheme == .dark ? .black : .white) : EditorialStyle.graphite
    }
    private var fill: Color {
        if emphasis == .primary { return EditorialStyle.accent.opacity(configuration.isPressed ? 0.85 : hovered ? 0.93 : 1) }
        return Color.primary.opacity(configuration.isPressed ? 0.09 : hovered ? 0.055 : emphasis == .quiet ? 0 : 0.025)
    }
    var body: some View {
        configuration.label.font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 12).frame(minWidth: 32, minHeight: EditorialStyle.controlHeight)
            .foregroundStyle(ink).background(fill, in: RoundedRectangle(cornerRadius: EditorialStyle.controlRadius))
            .overlay {
                RoundedRectangle(cornerRadius: EditorialStyle.controlRadius)
                    .strokeBorder(focused ? EditorialStyle.accent : emphasis == .quiet ? .clear : EditorialStyle.rule,
                                  lineWidth: focused ? 2 : 0.5).allowsHitTesting(false)
            }
            .contentShape(RoundedRectangle(cornerRadius: EditorialStyle.controlRadius))
            .opacity(enabled ? 1 : 0.45)
            .offset(y: configuration.isPressed && !reduceMotion ? 0.5 : 0)
            .onHover { hovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovered)
    }
}

@MainActor struct EditorialFieldStyle: @preconcurrency TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        EditorialFieldSurface { configuration.textFieldStyle(.plain) }
    }
}

private struct EditorialFieldSurface<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @FocusState private var focused: Bool
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        content().font(.callout).padding(.horizontal, 10).padding(.vertical, 7)
            .frame(minHeight: EditorialStyle.controlHeight)
            .focused($focused)
            .background(EditorialStyle.canvas.opacity(0.6), in: RoundedRectangle(cornerRadius: EditorialStyle.controlRadius))
            .overlay {
                RoundedRectangle(cornerRadius: EditorialStyle.controlRadius)
                    .strokeBorder(focused ? EditorialStyle.accent : EditorialStyle.rule, lineWidth: focused ? 2 : 0.5)
                    .allowsHitTesting(false)
            }.opacity(enabled ? 1 : 0.5)
    }
}

struct EditorialGroupBoxStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            configuration.label.font(.system(size: 14, weight: .semibold)).accessibilityAddTraits(.isHeader)
            configuration.content.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading).modifier(EditorialSurface())
    }
}

struct EditorialTab: Identifiable {
    let title: String
    let symbol: String
    var id: String { title }
}

/// A bounded category switcher. Native buttons preserve Tab/Space activation.
struct EditorialTabs: View {
    let options: [EditorialTab]
    @Binding var selection: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        HStack(spacing: 4) {
            ForEach(options) { option in
                Button { selection = option.title } label: {
                    Label(option.title, systemImage: option.symbol)
                        .font(.system(size: 13, weight: selection == option.title ? .semibold : .medium))
                        .frame(minWidth: 72, minHeight: 34).padding(.horizontal, 10)
                        .foregroundStyle(selection == option.title ? EditorialStyle.graphite : .secondary)
                        .background(selection == option.title ? EditorialStyle.panel : .clear,
                                    in: RoundedRectangle(cornerRadius: EditorialStyle.controlRadius))
                        .overlay {
                            if selection == option.title {
                                RoundedRectangle(cornerRadius: EditorialStyle.controlRadius).strokeBorder(EditorialStyle.rule, lineWidth: 0.5)
                            }
                        }.contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityAddTraits(selection == option.title ? .isSelected : [])
            }
        }.padding(4).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
            .fixedSize(horizontal: true, vertical: true)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: selection)
            .onMoveCommand { direction in
                guard let index = options.firstIndex(where: { $0.title == selection }) else { return }
                if direction == .left { selection = options[max(0, index - 1)].title }
                if direction == .right { selection = options[min(options.count - 1, index + 1)].title }
            }.accessibilityElement(children: .contain).accessibilityLabel("连接类型")
    }
}

struct EditorialNotice: View {
    let title: String
    let detail: String
    var symbol = "info.circle"
    var color: Color = .secondary
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(color).padding(.top, 2).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.callout.weight(.medium)).foregroundStyle(EditorialStyle.graphite)
                if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 0)
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.055), in: RoundedRectangle(cornerRadius: EditorialStyle.controlRadius))
            .accessibilityElement(children: .combine)
    }
}

struct EmptyRuntimeView: View {
    var body: some View {
        ContentUnavailableView("后台未连接", systemImage: "network")
    }
}

/// One destination per row, including its current permission/connection evidence.
struct EditorialDestinationRow: View {
    let title: String
    let detail: String
    let symbol: String
    let status: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 19, weight: .regular))
                    .foregroundStyle(EditorialStyle.graphite).frame(width: 32).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.callout.weight(.medium)).foregroundStyle(EditorialStyle.graphite)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Text(status).font(.caption).foregroundStyle(.secondary)
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary).accessibilityHidden(true)
            }.padding(.horizontal, 8).frame(minHeight: 62).contentShape(Rectangle())
        }.buttonStyle(EditorialDestinationButtonStyle()).accessibilityElement(children: .combine)
    }
}

private struct EditorialDestinationButtonStyle: ButtonStyle {
    @Environment(\.isFocused) private var focused
    @State private var hovered = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Color.primary.opacity(configuration.isPressed ? 0.07 : hovered ? 0.035 : 0),
                        in: RoundedRectangle(cornerRadius: EditorialStyle.controlRadius))
            .overlay {
                RoundedRectangle(cornerRadius: EditorialStyle.controlRadius)
                    .strokeBorder(focused ? EditorialStyle.accent : .clear, lineWidth: 2).allowsHitTesting(false)
            }.onHover { hovered = $0 }
    }
}

/// Native menu behavior with bounded, consistent control chrome.
struct EditorialMenuSurface: ViewModifier {
    func body(content: Content) -> some View {
        content.menuStyle(.borderlessButton).menuIndicator(.hidden)
            .frame(maxWidth: .infinity, alignment: .leading).tint(EditorialStyle.graphite)
            .padding(.leading, 10).padding(.trailing, 25).frame(height: EditorialStyle.controlHeight)
            .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: EditorialStyle.controlRadius))
            .overlay { RoundedRectangle(cornerRadius: EditorialStyle.controlRadius).strokeBorder(EditorialStyle.rule, lineWidth: 0.5).allowsHitTesting(false) }
            .overlay(alignment: .trailing) {
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary).padding(.trailing, 10).allowsHitTesting(false)
            }
    }
}
