import AppKit
import FinderSync
import Darwin
import OSLog

@objc(ARLFinderActions)
final class FinderActions: FIFinderSync {
    private let logger = Logger(subsystem:"local.arl.control.finderactions",category:"menu")
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
        logger.notice("extension_started roots=\(self.roots.count,privacy:.public)")
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        // Finder's menu and target/action APIs are synchronous. Keep every menu
        // object on this callback thread; only the NSAlert edge below uses an actor.
        logger.notice("menu_requested kind=\(menuKind.rawValue,privacy:.public) main=\(Thread.isMainThread,privacy:.public)")
        let context: FinderActionSelection.Context
        switch menuKind {
        case .contextualMenuForItems: context = .items
        case .contextualMenuForContainer: context = .container
        default: return nil
        }
        guard let selection = currentSelection(context) else { logger.notice("selection_unavailable"); return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        let parent = NSMenuItem(title: "访达动作", action: nil, keyEquivalent: "")
        if let resource = Bundle.main.url(forResource: "ARL", withExtension: "icns"),
           let icon = NSImage(contentsOf: resource) {
            icon.size = NSSize(width: 16, height: 16)
            icon.isTemplate = false
            parent.image = icon
        }
        let actions = NSMenu(title: "访达动作")
        actions.autoenablesItems = false
        let copy = NSMenuItem(title: "拷贝路径", action: context == .items ? #selector(copySelectedPaths(_:)) : #selector(copyContainerPath(_:)), keyEquivalent: "")
        copy.target = self
        actions.addItem(copy)
        let terminal = NSMenuItem(title: "在终端打开", action: context == .items ? #selector(openSelectedDirectory(_:)) : #selector(openContainerDirectory(_:)), keyEquivalent: "")
        terminal.target = self
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
    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
    // Finder proxies the NSMenuItem across the extension boundary. A Swift
    // representedObject is not an action context. Read Finder's authoritative
    // URLs synchronously in its action callback; selectors preserve menu kind.
    @objc private func copySelectedPaths(_ sender:NSMenuItem) {copyPaths(context:.items)}
    @objc private func copyContainerPath(_ sender:NSMenuItem) {copyPaths(context:.container)}
    @objc private func openSelectedDirectory(_ sender:NSMenuItem) {openTerminal(context:.items)}
    @objc private func openContainerDirectory(_ sender:NSMenuItem) {openTerminal(context:.container)}
    private func copyPaths(context:FinderActionSelection.Context) {
        logger.notice("copy_requested main=\(Thread.isMainThread,privacy:.public)")
        guard let selection = currentSelection(context) else { Self.showFailure("无法读取当前选择，请重新右键。"); return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if !pasteboard.setString(selection.copiedPaths, forType: .string) { Self.showFailure("拷贝失败，请重新右键。") }
    }
    private func openTerminal(context:FinderActionSelection.Context) {
        logger.notice("terminal_requested main=\(Thread.isMainThread,privacy:.public)")
        guard let selection = currentSelection(context),
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
        // The SDK isolates NSAlert to the UI actor. Capture the message string
        // only; Finder/NSMenu/NSMenuItem objects never enter this operation.
        Task { @MainActor in
            let alert = NSAlert()
            alert.messageText = "操作未成"; alert.informativeText = message
            alert.addButton(withTitle: "知道了")
            alert.runModal()
        }
    }
}
