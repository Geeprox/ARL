import Foundation
import CoreFoundation
import Darwin

/// launchd supervises the app; the app supervises its owned runtime children.
/// A foreground open requests a window from that same managed instance.
enum ManagedLaunch {
    static let label = "local.arl.runtime"
    static let windowNotification = "local.arl.control.present-window"
    static var home: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/ARL") }
    static var target: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/ARL.app") }
    static var agent: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/" + label + ".plist") }
    static var job: String { "gui/\(getuid())/" + label }
    static var request: URL { home.appendingPathComponent("present-window.json") }
    static func validAgent(_ data: Data, executable: String) -> Bool {
        guard let p = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String:Any],
              p["Label"] as? String == label,
              p["ProgramArguments"] as? [String] == [executable, "--background"],
              p["RunAtLoad"] as? Bool == true,
              let keep = p["KeepAlive"] as? [String:Bool], keep == ["SuccessfulExit":false],
              p["ThrottleInterval"] as? Int == 10 else { return false }
        return true
    }
    static func managedPID(_ text: String, executable: String) -> Int32? {
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.contains("program = " + executable),
              let line = lines.first(where: { $0.hasPrefix("pid = ") }),
              let pid = Int32(line.dropFirst(6)), pid > 1 else { return nil }
        return pid
    }
    static func validIntent(_ data: Data, now: Date) -> Bool {
        guard let p = (try? JSONSerialization.jsonObject(with: data)) as? [String:Any],
              Set(p.keys) == ["nonce","created_at"], let nonce = p["nonce"] as? String,
              UUID(uuidString: nonce) != nil, let n = p["created_at"] as? NSNumber,
              CFGetTypeID(n) != CFBooleanGetTypeID() else { return false }
        let age = now.timeIntervalSince1970 - n.doubleValue
        return age >= 0 && age <= 15
    }
    static func consumeWindowIntent() -> Bool {
        guard let data = try? RemindersNativeIO.privateFile(request.path, limit:1024) else { return false }
        let valid = validIntent(data, now:Date())
        // A window request contains no credentials or execution authority.
        try? FileManager.default.removeItem(at:request)
        return valid
    }
    static func command(_ arguments:[String]) -> (Int32,String) {
        let p = Process(), pipe = Pipe()
        p.executableURL = URL(fileURLWithPath:"/bin/launchctl"); p.arguments = arguments
        p.standardInput = FileHandle.nullDevice; p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return (-1,"") }
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while p.isRunning && ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval:0.02) }
        if p.isRunning { p.terminate(); return (-1,"") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (p.terminationStatus, data.count <= 32768 ? String(decoding:data,as:UTF8.self) : "")
    }
    static func installedAgentValid() -> Bool {
        guard Bundle.main.bundleURL.standardizedFileURL == target.standardizedFileURL,
              let raw = try? RemindersNativeIO.privateFile(agent.path, limit:16384),
              validAgent(raw,executable:target.appendingPathComponent("Contents/MacOS/ARL").path) else { return false }
        return true
    }
    /// Called before SwiftUI creates owners or sockets. Never starts a second runtime.
    static func handoffForeground() -> Bool {
        guard CommandLine.arguments.count == 1, installedAgentValid(),
              !FileManager.default.fileExists(atPath:home.appendingPathComponent("install-maintenance.json").path) else { return false }
        let temporary = home.appendingPathComponent(".present-window-" + UUID().uuidString)
        do {
            try RemindersNativeIO.privateDirectory(home.path)
            let data = try JSONSerialization.data(withJSONObject:["nonce":UUID().uuidString,"created_at":Date().timeIntervalSince1970])
            let fd = open(temporary.path,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0o600)
            guard fd >= 0 else { return false }
            let handle = FileHandle(fileDescriptor:fd,closeOnDealloc:true)
            try handle.write(contentsOf:data); try handle.close()
            guard rename(temporary.path,request.path) == 0 else { try? FileManager.default.removeItem(at:temporary); return false }
            if command(["print",job]).0 != 0 {
                guard command(["bootstrap","gui/\(getuid())",agent.path]).0 == 0 else { try? FileManager.default.removeItem(at:request); return false }
            }
            guard command(["kickstart",job]).0 == 0 else { try? FileManager.default.removeItem(at:request); return false }
            return true
        } catch { try? FileManager.default.removeItem(at:temporary); return false }
    }
    static func supervisingCurrentProcess() -> Bool {
        guard installedAgentValid(), let executable = Bundle.main.executableURL?.path else { return false }
        return managedPID(command(["print",job]).1,executable:executable) == getpid()
    }
}
