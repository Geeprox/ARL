import SwiftUI
import AppKit

/// AppKit owns menu presentation; refreshes only update changed eligibility.
struct PerformanceRangeSelector: NSViewRepresentable {
    @Binding var selection: PerformanceTimeRange
    let historySpan: TimeInterval
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 105, height: 30), pullsDown: false)
        button.font = .systemFont(ofSize: 13, weight: .medium)
        button.isBordered = false
        button.contentTintColor = NSColor(srgbRed: 0.115, green: 0.125, blue: 0.13, alpha: 1)
        button.wantsLayer = true
        button.layer?.backgroundColor = NSColor(srgbRed: 0.992, green: 0.988, blue: 0.979, alpha: 1).cgColor
        button.layer?.borderColor = NSColor.black.withAlphaComponent(0.13).cgColor
        button.layer?.borderWidth = 0.7
        button.layer?.cornerRadius = 3
        button.menu?.autoenablesItems = false
        for range in PerformanceTimeRange.allCases {
            button.addItem(withTitle: range.title)
            button.lastItem?.tag = range.rawValue
        }
        button.target = context.coordinator
        button.action = #selector(Coordinator.changed(_:))
        button.setAccessibilityLabel("时间范围")
        button.toolTip = ("仅本次运行记录，尚无记录的时段不可选" + "\n" + "本次会话的实际历史；尚未积累的时长不可选")
        return button
    }
    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        for range in PerformanceTimeRange.allCases {
            let enabled = range.isEligible(span: historySpan, selection: selection)
            if let item = button.menu?.item(withTag: range.rawValue), item.isEnabled != enabled { item.isEnabled = enabled }
        }
        if button.selectedTag() != selection.rawValue { button.selectItem(withTag: selection.rawValue) }
        button.setAccessibilityValue(selection.title)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPopUpButton, context: Context) -> CGSize? { CGSize(width: 105, height: 30) }
    @MainActor final class Coordinator: NSObject {
        var parent: PerformanceRangeSelector
        init(_ parent: PerformanceRangeSelector) { self.parent = parent }
        @objc func changed(_ button: NSPopUpButton) {
            guard let range = PerformanceTimeRange(rawValue: button.selectedTag()) else { return }
            parent.selection = range
        }
    }
}
