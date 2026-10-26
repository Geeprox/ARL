import SwiftUI
import AppKit

/// Shared geometry and semantic materials for the control plane.
enum EditorialStyle {
    private static func adaptive(_ light: NSColor, _ dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light })
    }
    static let canvas = adaptive(NSColor(srgbRed: 0.977, green: 0.972, blue: 0.960, alpha: 1), NSColor(srgbRed: 0.13, green: 0.135, blue: 0.14, alpha: 1))
    static let panel = adaptive(NSColor(srgbRed: 0.997, green: 0.994, blue: 0.986, alpha: 1), NSColor(srgbRed: 0.16, green: 0.165, blue: 0.17, alpha: 1))
    static let sidebar = adaptive(NSColor(srgbRed: 0.947, green: 0.943, blue: 0.934, alpha: 1), NSColor(srgbRed: 0.11, green: 0.115, blue: 0.12, alpha: 1))
    static let graphite = adaptive(NSColor(srgbRed: 0.115, green: 0.125, blue: 0.13, alpha: 1), .labelColor)
    static let accent = adaptive(NSColor(srgbRed: 0.70, green: 0.215, blue: 0.035, alpha: 1), NSColor(srgbRed: 1, green: 0.46, blue: 0.21, alpha: 1))
    static let rule = Color.primary.opacity(0.12)
    static let cardRadius: CGFloat = 10
    static let controlRadius: CGFloat = 6
    static let controlHeight: CGFloat = 32
    static let sectionSpacing: CGFloat = 20
}

struct EditorialHeading: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 28, weight: .bold)).foregroundStyle(EditorialStyle.graphite)
                .accessibilityAddTraits(.isHeader)
            if !subtitle.isEmpty { Text(subtitle).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct EditorialSurface: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(EditorialStyle.panel, in: RoundedRectangle(cornerRadius: EditorialStyle.cardRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: EditorialStyle.cardRadius, style: .continuous)
                    .strokeBorder(EditorialStyle.rule, lineWidth: 0.5).allowsHitTesting(false)
            }
    }
}
