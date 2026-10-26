import AppKit
import FinderSync
import Darwin

@objc(ARLFinderActions)
final class FinderActions: FIFinderSync {
    private let roots: Set<URL>

    override init() {
        // NSHomeDirectory inside a sandbox is the extension container. Resolve
        // only the current UID's account home, without reading directory contents.
        var entry = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: 65536)
        let home: String? = buffer.withUnsafeMutableBufferPointer { bytes in
            guard getpwuid_r(getuid(), &entry, bytes.baseAddress!, bytes.count, &result) == 0,
                  result != nil, let path = entry.pw_dir else { return nil }
            return String(validatingCString: path)
        }
        if let home, home.hasPrefix("/"), home != "/" {
            roots = [URL(fileURLWithPath: home, isDirectory: true), URL(fileURLWithPath: "/Volumes", isDirectory: true)]
        } else { roots = [] }
        super.init()
        FIFinderSyncController.default().directoryURLs = roots
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        // Finder's menu and target/action APIs are synchronous. Keep every menu
        // object on this callback thread; only the NSAlert edge below uses an actor.
        guard Thread.isMainThread else { return nil }
        let context: FinderActionSelection.Context
        switch menuKind {
        case .contextualMenuForItems: context = .items
        case .contextualMenuForContainer: context = .container
        default: return nil
        }
        guard let selection = currentSelection(context) else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        let parent = NSMenuItem(title: "访达动作", action: nil, keyEquivalent: "")
        let actions = NSMenu(title: "访达动作")
        actions.autoenablesItems = false
        let copy = NSMenuItem(title: "拷贝路径", action: #selector(copyPaths(_:)), keyEquivalent: "")
        copy.target = self; copy.representedObject = selection
        actions.addItem(copy)
        let terminal = NSMenuItem(title: "终端打开", action: #selector(openTerminal(_:)), keyEquivalent: "")
        terminal.target = self; terminal.representedObject = selection
        terminal.isEnabled = selection.terminalDirectory(isDirectory: Self.isDirectory) != nil
        actions.addItem(terminal)
        parent.submenu = actions; menu.addItem(parent)
        return menu
    }
    private func currentSelection(_ context: FinderActionSelection.Context) -> FinderActionSelection? {
        let controller = FIFinderSyncController.default()
        return FinderActionSelection(context: context, selected: controller.selectedItemURLs(),
            targeted: controller.targetedURL(), roots: roots)
    }
    private func confirmedSelection(_ sender: NSMenuItem) -> FinderActionSelection? {
        guard let captured = sender.representedObject as? FinderActionSelection,
              captured == currentSelection(captured.context) else { return nil }
        return captured
    }
    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
    @objc private func copyPaths(_ sender: NSMenuItem) {
        guard Thread.isMainThread else { return }
        guard let selection = confirmedSelection(sender) else { Self.showFailure("选择已变化，请重新右键。"); return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if !pasteboard.setString(selection.copiedPaths, forType: .string) { Self.showFailure("拷贝失败，请重新右键。") }
    }
    @objc private func openTerminal(_ sender: NSMenuItem) {
        guard Thread.isMainThread else { return }
        guard let selection = confirmedSelection(sender),
              let directory = selection.terminalDirectory(isDirectory: Self.isDirectory) else {
            Self.showFailure("请选择一个目录后重试。"); return
        }
        // Launch Services receives the exact file URL; no command is built.
        NSWorkspace.shared.open([directory],
            withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
            configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if error != nil { Task { @MainActor in FinderActions.showFailure("终端未打开，请稍后重试。") } }
            }
    }
    private static func showFailure(_ message: String) {
        guard Thread.isMainThread else { return }
        // The SDK isolates NSAlert to the UI actor. Capture the message string
        // only; Finder/NSMenu/NSMenuItem objects never enter this operation.
        MainActor.assumeIsolated {
            let alert = NSAlert()
            alert.messageText = "操作未成"; alert.informativeText = message
            alert.addButton(withTitle: "知道了")
            alert.runModal()
        }
    }
}
