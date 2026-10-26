import Foundation
import AppKit

@MainActor protocol NotesReviewPresentation {
    func prepare(_ proposal: NotesCreateProposal, target: NotesTargetMetadata)
    func runModal() -> Bool
    func dismiss()
}

// Concrete native presentation; instantiated only on an admitted native review.
// It displays plaintext, never WebView/HTML/script. No Notes/TCC call is made.
@MainActor final class AppKitNotesReviewPresentation: NotesReviewPresentation {
    private var alert: NSAlert?
    func prepare(_ p: NotesCreateProposal, target: NotesTargetMetadata) {
        let panel = NSAlert()
        panel.messageText = "新建备忘录"
        panel.informativeText = "文件夹：" + target.name
        panel.addButton(withTitle: "创建")
        panel.addButton(withTitle: "取消")
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 440, height: 240))
        scroll.hasVerticalScroller = true
        let text = NSTextView(frame: scroll.bounds)
        text.isEditable = false; text.isSelectable = true
        text.font = .systemFont(ofSize: NSFont.systemFontSize)
        text.textColor = .labelColor; text.backgroundColor = .textBackgroundColor
        text.string = "标题：" + p.title + "\n\n" + p.text
        text.isVerticallyResizable = true; text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.containerSize = NSSize(width: 440, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = text; panel.accessoryView = scroll
        alert = panel
    }
    func runModal() -> Bool {
        guard let alert else { return false }
        return alert.runModal() == .alertFirstButtonReturn
    }
    func dismiss() {
        NSApp.abortModal()
        alert?.window.orderOut(nil)
    }
}

@MainActor final class NativeNotesReviewer: NotesReviewer {
    private let presentation: () -> NotesReviewPresentation
    private let interval: Double
    init(presentation: @escaping () -> NotesReviewPresentation = { AppKitNotesReviewPresentation() }, pollInterval: Double = 0.05) {
        self.presentation = presentation
        interval = max(0.005, min(0.25, pollInterval)) // trusted composition only
    }
    func confirm(_ p: NotesCreateProposal, target: NotesTargetMetadata, context: NotesReviewContext) -> Bool {
        guard !context.shouldDismiss else { return false }
        let panel = presentation()
        panel.prepare(p, target: target)
        guard !context.shouldDismiss else { return false }
        // NSAlert.runModal does not service default-mode-only timers. Register
        // explicitly in modal-panel mode plus common modes, on the main loop.
        let monitor = NotesModalMonitor(context: context, panel: panel)
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated {
                monitor.poll()
            }
        }
        RunLoop.main.add(timer, forMode: .modalPanel)
        RunLoop.main.add(timer, forMode: .common)
        defer { timer.invalidate() }
        let confirmed = panel.runModal()
        return confirmed && !monitor.dismissed && !context.shouldDismiss
    }
}

@MainActor private final class NotesModalMonitor {
    let context: NotesReviewContext
    let panel: NotesReviewPresentation
    private(set) var dismissed = false
    init(context: NotesReviewContext, panel: NotesReviewPresentation) { self.context = context; self.panel = panel }
    func poll() {
        if !dismissed && context.shouldDismiss { dismissed = true; panel.dismiss() }
    }
}
