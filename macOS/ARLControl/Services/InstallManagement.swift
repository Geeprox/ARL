import Foundation
import AppKit
import Security
import Darwin
import ARLCredentialHostCore

/// Local signed-app management entry, selected before SwiftUI/credential owner
/// construction. Fixed bundle ID and current-user paths; no UI automation.
enum InstallManagement {
    static let target = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/ARL.app")
    static func record(_ pid: pid_t) throws -> [String: Any] {
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size)) == size,
              info.pbi_uid == getuid() else { throw ARLError(code:"install_process_unverified") }
        var bytes = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &bytes, UInt32(bytes.count)) > 0 else { throw ARLError(code:"install_process_unverified") }
        return ["pid":Int(pid),"birth":[info.pbi_start_tvsec,info.pbi_start_tvusec],"executable":String(cString:bytes)]
    }
    static func oldRequirement() throws -> String {
        let path = target.deletingPathExtension().appendingPathExtension("authority.json").path
        let data = try RemindersNativeIO.privateFile(path)
        return try authorityRequirement(data, target: target)
    }
    static func authorityRequirement(_ data: Data, target: URL) throws -> String {
        // Typed authority accepts the actual booleans/arrays. Parse the same
        // bytes with the existing strict JSON reader first, including escaped
        // duplicate keys, before Decodable can collapse them.
        _ = try MessagesJSON.decode(data, limit: 16384)
        let authority = try CredentialHostAuthority.decode(data)
        guard [1, 2, 3].contains(authority.schema),
              authority.bundlePath == target.path,
              authority.identifier == "local.arl.control",
              let rule = authority.designatedRequirement, !rule.isEmpty else {
            throw ARLError(code:"install_authority_invalid")
        }
        return rule
    }
    static func validateDynamicAndStatic(_ code: SecCode, requirement: SecRequirement?) -> Bool {
        // Nested/strict resource flags belong to the static API. Applying them
        // to dynamic validation returns errSecCSInvalidFlags on the real host.
        var staticCode: SecStaticCode?
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
            && SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess
            && staticCode.map { SecStaticCodeCheckValidity($0,
                SecCSFlags(rawValue:kSecCSStrictValidate | kSecCSCheckNestedCode | kSecCSCheckAllArchitectures),
                requirement) == errSecSuccess } == true
    }
    static func verify(_ app: NSRunningApplication, requirement: String) throws {
        guard app.bundleIdentifier == "local.arl.control", app.bundleURL?.standardizedFileURL == target.standardizedFileURL else { throw ARLError(code:"install_app_path_mismatch") }
        var rule: SecRequirement?, guest: SecCode?
        guard SecRequirementCreateWithString(requirement as CFString, [], &rule) == errSecSuccess, let rule,
              SecCodeCopyGuestWithAttributes(nil,[kSecGuestAttributePid:app.processIdentifier] as CFDictionary,[],&guest) == errSecSuccess, let guest,
              validateDynamicAndStatic(guest, requirement: rule) else { throw ARLError(code:"install_app_identity_unverified") }
    }
    @MainActor static func run(_ args: [String]) -> Int32 {
        do {
            if args == ["--internal-codex-plan"] {
                try output(CodexScopeOwner.configurationCandidate()); return 0
            }
            if args.first == "--internal-code-check" {
                var code: SecCode?, requirement: SecRequirement?
                guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
                      SecRequirementCreateWithString(try oldRequirement() as CFString, [], &requirement) == errSecSuccess,
                      let requirement, validateDynamicAndStatic(code, requirement: requirement) else {
                    throw ARLError(code:"install_self_identity_unverified")
                }
                try output(["verified":true,"build":Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? ""])
                return 0
            }
            if args == ["--internal-reminders-state"] {
                try output(RemindersInstallDrain.state());return 0
            }
            if args.first == "--internal-reminders-quit" {
                guard args.count == 5,let pid=Int32(args[1]),let seconds=UInt64(args[2]),let micros=UInt64(args[3]) else {
                    throw ARLError(code:"install_process_unverified")
                }
                try output(RemindersInstallDrain.quit(pid:pid,birth:[seconds,micros],admissionsSHA:args[4]));return 0
            }
            if args.first == "--internal-app-state" {
                let rule = try oldRequirement()
                var rows: [[String:Any]] = []
                for app in NSRunningApplication.runningApplications(withBundleIdentifier:"local.arl.control") where app.processIdentifier != getpid() {
                    try verify(app,requirement:rule)
                    var row = try record(app.processIdentifier)
                    let bundle = app.bundleURL.flatMap(Bundle.init(url:))
                    let build = (bundle?.object(forInfoDictionaryKey:"CFBundleVersion") as? String).flatMap(Int.init) ?? 0
                    row["drain_supported"] = build >= 55 && bundle?.object(forInfoDictionaryKey:"ARLCoreRuntimeManifestSHA256") is String
                    rows.append(row)
                }
                try output(["schema_version":1,"instances":rows.sorted { ($0["pid"] as? Int ?? 0) < ($1["pid"] as? Int ?? 0) }]);return 0
            }
            if args.first == "--internal-app-quit" {
                guard args.count == 4, let pid = Int32(args[1]), pid > 1,
                      let seconds = UInt64(args[2]), let micros = UInt64(args[3]),
                      let app = NSRunningApplication(processIdentifier:pid) else { throw ARLError(code:"install_process_unverified") }
                try verify(app,requirement:oldRequirement())
                let observed = try record(pid)
                guard (observed["birth"] as? [UInt64]) == [seconds,micros], app.terminate() else { throw ARLError(code:"install_app_drain_unproven") }
                let deadline = ProcessInfo.processInfo.systemUptime + 42
                while !app.isTerminated && ProcessInfo.processInfo.systemUptime < deadline {
                    RunLoop.current.run(until:Date().addingTimeInterval(0.05))
                }
                guard app.isTerminated else { throw ARLError(code:"install_app_drain_unproven") }
                try output(["terminated":true]);return 0
            }
            guard args.first == "--manage", let resources = Bundle.main.resourceURL else { return 2 }
            let python = resources.appendingPathComponent("NASRuntime/python/bin/python3.12")
            let entry = resources.appendingPathComponent("CoreRuntime/entry.py")
            let child = Process();child.executableURL=python
            child.arguments=["-I","-B",entry.path,"--parent-pid",String(getpid()),"--manage"] + Array(args.dropFirst())
            child.environment=["PATH":"/usr/bin:/bin:/usr/sbin:/sbin","HOME":NSHomeDirectory(),"LANG":"C","PYTHONDONTWRITEBYTECODE":"1"]
            child.standardInput=FileHandle.nullDevice;child.standardOutput=FileHandle.standardOutput;child.standardError=FileHandle.standardError
            try child.run();child.waitUntilExit();return child.terminationStatus
        } catch {
            try? output(["status":"blocked","error":(error as? ARLError)?.code ?? "install_management_failed"])
            return 2
        }
    }
    static func output(_ object:[String:Any]) throws {
        let raw=try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys])
        FileHandle.standardOutput.write(raw);FileHandle.standardOutput.write(Data([10]))
    }
}
