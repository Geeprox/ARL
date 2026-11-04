import SwiftUI
import AppKit

final class ControlDelegate: NSObject, NSApplicationDelegate {
    @MainActor private func presentControlWindow() {
        guard let window = NSApp.windows.first(where: { $0.title == "ARL" }) else { return }
        NSApp.setActivationPolicy(.regular); NSApp.unhide(nil); window.deminiaturize(nil)
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard let window = sender.windows.first(where: { $0.title == "ARL" && $0.canBecomeMain }) else {
            return true
        }
        window.deminiaturize(nil)
        sender.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        sender.activate(ignoringOtherApps: true)
        return false
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store = RuntimeStore.active else { return .terminateNow }
        Task { @MainActor in sender.reply(toApplicationShouldTerminate: await store.stopBackground()) }
        return .terminateLater
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Handle requests from a foreground launcher after a normal user quit.
        // The managed background process owns the window and all runtime children.
        Task { @MainActor in
            while !Task.isCancelled {
                if Bundle.main.bundleURL.standardizedFileURL == ManagedLaunch.target.standardizedFileURL,
                   NSApp.windows.contains(where:{$0.title == "ARL"}),
                   ManagedLaunch.consumeWindowIntent() { presentControlWindow() }
                do { try await Task.sleep(for:.milliseconds(250)) } catch { return }
            }
        }
        #if ARL_CONSOLIDATED_TEST
        if CommandLine.arguments.contains("--consolidated-native-smoke") {
            NSApp.setActivationPolicy(.accessory)
            Task { @MainActor in
                do { try await ConsolidatedNativeSmoke.run(); NSApp.terminate(nil) }
                catch { FileHandle.standardError.write(Data("consolidated_synthetic_check_failed:\((error as? NotesControlFault)?.code ?? (error as? RemindersTransportFault)?.code ?? (error as? MessagesTransportFault)?.code ?? "unclassified")\n".utf8)); exit(2) }
            }
            return
        }
        #endif
        if CommandLine.arguments.contains("--background") {
            NSApp.setActivationPolicy(.accessory)
            NSApp.hide(nil)
        } else {
            NSApp.setActivationPolicy(.regular)
            // Publish the packaged artwork to the live Dock tile as well as
            // LaunchServices; an existing tile can retain its generic image.
            if let url = Bundle.main.url(forResource: "ARL", withExtension: "icns"),
               let icon = NSImage(contentsOf: url), icon.isValid {
                NSApp.applicationIconImage = icon
                NSApp.dockTile.display()
            }
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
@main enum ARLEntry {
    @MainActor static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        if ["--manage","--internal-app-state","--internal-app-quit","--internal-code-check","--internal-codex-plan","--internal-reminders-state","--internal-reminders-quit","--internal-nas-acceptance"].contains(args.first ?? "") {
            exit(InstallManagement.run(args))
        }
        if ManagedLaunch.handoffForeground() { exit(0) }
        ARLControlApp.main()
    }
}
struct ARLControlApp: App {
    @NSApplicationDelegateAdaptor(ControlDelegate.self) private var delegate
    @State private var store = RuntimeStore()
    var body: some Scene {
        WindowGroup("ARL", id: "control") {
            ContentView(store: store).preferredColorScheme(.light)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1080, height: 780)
        .commands {
            CommandGroup(after: .newItem) {
                Button("刷新状态") { Task { await store.refresh(resetLogs: true) } }.keyboardShortcut("r")
            }
        }
        Settings { PreferencesView().preferredColorScheme(.light) }
        MenuBarExtra("ARL", systemImage: store.symbol) { StatusMenu(store: store) }
    }
}
