import SwiftUI

struct LogScrollTrigger: ViewModifier {
    struct Viewport: Equatable { let end: CGFloat; let height: CGFloat }
    let load: () -> Void
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.onScrollGeometryChange(for: Viewport.self) { geometry in
                Viewport(end: geometry.contentOffset.y + geometry.containerSize.height, height: geometry.contentSize.height)
            } action: { _, viewport in
                if viewport.height > 0 && viewport.end >= viewport.height - 120 { load() }
            }
        } else { content }
    }
}
