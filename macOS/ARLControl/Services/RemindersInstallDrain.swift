import AppKit
import Foundation
import Security
import Darwin

struct RemindersInstallProcess: Codable, Equatable, Sendable {
    let pid: Int32
    let birth: [UInt64]
    let executable: String
}
struct RemindersInstallAdmissions: Sendable {
    let sha256: String
    let count: Int
    let pending: Int
    /// Fixed metadata only. Never opens source selection, business journals or EventKit.
    static func read(_ directory: URL) throws -> Self {
        try RemindersNativeIO.privateDirectory(directory.path)
        let names=try FileManager.default.contentsOfDirectory(atPath:directory.path).sorted()
        guard names.count <= 512 else { throw ARLError(code:"install_reminders_admissions_invalid") }
        var fingerprint=Data(),pending=0
        for name in names {
            guard name.hasSuffix(".json"),let id=UUID(uuidString:String(name.dropLast(5))),
                  id.uuidString.lowercased()+".json" == name else { throw ARLError(code:"install_reminders_admissions_invalid") }
            let bytes=try RemindersNativeIO.privateFile(directory.appendingPathComponent(name).path,limit:16384)
            let value=try RemindersNativeIO.flatObject(bytes)
            guard Set(value.keys)==["request_id","action","frame_sha256","state","outcome","code"],
                  value["request_id"] as? String == id.uuidString.lowercased(),
                  let action=value["action"] as? String,RemindersFirstAction(rawValue:action) != nil,
                  let hash=value["frame_sha256"] as? String,hash.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil,
                  let state=value["state"] as? String,["pending","completed"].contains(state),
                  value["outcome"] is String,value["code"] is String else { throw ARLError(code:"install_reminders_admissions_invalid") }
            if state == "pending" { pending+=1 }
            fingerprint.append(Data((name+":"+RemindersNativeIO.hash(bytes)+"\n").utf8))
        }
        return .init(sha256:RemindersNativeIO.hash(fingerprint),count:names.count,pending:pending)
    }
}

/// Narrow installation bootstrap for an old helper that has no shutdown RPC.
/// Normal termination only, after all main ARL instances are gone. No launching,
/// force termination, business calls, grants or journal changes are permitted.
@MainActor enum RemindersInstallDrain {
    static let identifier="local.arl.remindersbridge"
    static let home=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/ARL")
    static let helper=InstallManagement.target.appendingPathComponent("Contents/Library/LoginItems/ARLRemindersBridge.app")
    static func instances() -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier:identifier).filter { !$0.isTerminated }
    }
    static func mainCount() -> Int {
        NSRunningApplication.runningApplications(withBundleIdentifier:"local.arl.control").filter { !$0.isTerminated && $0.processIdentifier != getpid() }.count
    }
    static func deployment() throws -> RemindersNativeDeployment {
        // Deliberately avoid loadVerified: management cannot repair bindings.
        let value=try RemindersNativeDeployment.load(home:home)
        guard value.helper_bundle_path == helper.path,
              value.host_home == home.appendingPathComponent("reminders-v3").path else { throw ARLError(code:"install_reminders_path_changed") }
        try value.verify(home:home)
        return value
    }
    static func imageIsOwned(_ executable:String) throws -> Bool {
        let suffix="Contents/Library/LoginItems/ARLRemindersBridge.app/Contents/MacOS/ARLRemindersBridge"
        if executable == InstallManagement.target.appendingPathComponent(suffix).path { return true }
        // A replaced-but-live executable keeps the inode's retained snapshot
        // path. Admit only an exact terminal transaction image, never a loose
        // matching filename or an arbitrary second application.
        for store in ["unified-migrations","unified-migrations.noindex"] {
            let root=home.appendingPathComponent("runtime/"+store).path+"/"
            guard executable.hasPrefix(root) else { continue }
            let parts=String(executable.dropFirst(root.count)).split(separator:"/").map(String.init)
            guard parts.count == 10,let id=UUID(uuidString:parts[0]),id.uuidString.lowercased()==parts[0],
                  ["before","after"].contains(parts[1]),parts[2]=="app",
                  parts.dropFirst(3).joined(separator:"/")==suffix else { return false }
            let folder=URL(fileURLWithPath:root).appendingPathComponent(parts[0])
            try RemindersNativeIO.privateDirectory(folder.path)
            let plan=try MessagesJSON.decode(RemindersNativeIO.privateFile(folder.appendingPathComponent("plan.json").path,limit:8*1024*1024),limit:8*1024*1024).value
            let journal=try MessagesJSON.decode(RemindersNativeIO.privateFile(folder.appendingPathComponent("journal.json").path)).value
            guard plan["id"] as? String == parts[0],journal["id"] as? String == parts[0],
                  (parts[1]=="before" && journal["phase"] as? String == "committed" && journal["result"] as? String == "applied") ||
                  (parts[1]=="after" && journal["phase"] as? String == "rolled_back" && journal["result"] as? String == "restored"),
                  let changes=plan["changes"] as? [String:Any],let app=changes["app"] as? [String:Any],
                  let image=app[parts[1]] as? [String:Any],let files=image["files"] as? [String:Any],
                  let row=files[suffix] as? [String:Any],let pin=row["sha256"] as? String,
                  let mode=row["mode"] as? Int else { return false }
            var st=stat()
            guard lstat(executable,&st)==0,st.st_mode&S_IFMT==S_IFREG,st.st_uid==getuid(),st.st_nlink==1,
                  st.st_mode&0o022==0,Int(st.st_mode&0o777)==mode else { return false }
            // privateFile above checks the entire metadata ancestry for links;
            // inspect every image path component too before hashing.
            var path=""
            for part in executable.split(separator:"/") {
                path+="/"+part;var item=stat()
                guard lstat(path,&item)==0,item.st_mode&S_IFMT != S_IFLNK else { return false }
            }
            return RemindersNativeIO.hash(try Data(contentsOf:URL(fileURLWithPath:executable))) == pin
        }
        return false
    }
    static func verified(_ app:NSRunningApplication,_ deployment:RemindersNativeDeployment) throws -> RemindersInstallProcess {
        guard app.bundleIdentifier == identifier,!app.isTerminated,
              app.bundleURL?.standardizedFileURL == helper.standardizedFileURL,
              app.bundleURL?.resolvingSymlinksInPath() == helper else { throw ARLError(code:"install_reminders_path_changed") }
        var rule:SecRequirement?,guest:SecCode?,runningCode:SecStaticCode?,disk:SecStaticCode?,liveInfo:CFDictionary?,diskInfo:CFDictionary?
        guard SecRequirementCreateWithString(deployment.helper_requirement as CFString,[],&rule)==errSecSuccess,let rule,
              SecCodeCopyGuestWithAttributes(nil,[kSecGuestAttributePid:app.processIdentifier] as CFDictionary,[],&guest)==errSecSuccess,let guest,
              InstallManagement.validateDynamicAndStatic(guest,requirement:rule),
              SecStaticCodeCreateWithPath(helper as CFURL,[],&disk)==errSecSuccess,let disk,
              SecCodeCopyStaticCode(guest,[],&runningCode)==errSecSuccess,let runningCode,
              SecCodeCopySigningInformation(runningCode,SecCSFlags(rawValue:kSecCSSigningInformation),&liveInfo)==errSecSuccess,
              SecCodeCopySigningInformation(disk,SecCSFlags(rawValue:kSecCSSigningInformation),&diskInfo)==errSecSuccess,
              let live=(liveInfo as? [String:Any])?[kSecCodeInfoUnique as String] as? Data,
              let sealed=(diskInfo as? [String:Any])?[kSecCodeInfoUnique as String] as? Data,live==sealed else {
            throw ARLError(code:"install_reminders_identity_changed")
        }
        let raw=try InstallManagement.record(app.processIdentifier)
        guard let birth=raw["birth"] as? [UInt64],let executable=raw["executable"] as? String,
              try imageIsOwned(executable) else { throw ARLError(code:"install_reminders_identity_changed") }
        return .init(pid:app.processIdentifier,birth:birth,executable:executable)
    }
    static func state() throws -> [String:Any] {
        let apps=instances()
        guard apps.count <= 1 else { throw ARLError(code:"install_reminders_multiple_instances") }
        guard let app=apps.first else { return ["schema_version":1,"instance":NSNull(),"admissions_sha256":NSNull(),"admissions_count":0,"pending":0] }
        let value=try deployment(),record=try verified(app,value)
        let admissions=try RemindersInstallAdmissions.read(URL(fileURLWithPath:value.host_home).appendingPathComponent("admissions"))
        return ["schema_version":1,"instance":["pid":Int(record.pid),"birth":record.birth,"executable":record.executable],
                "admissions_sha256":admissions.sha256,"admissions_count":admissions.count,"pending":admissions.pending]
    }
    static func confirmExit(admissionsSHA:String,
                            readAdmissions: @MainActor () throws -> RemindersInstallAdmissions = {
                                try RemindersInstallAdmissions.read(home.appendingPathComponent("reminders-v3/admissions"))
                            },
                            processesAbsent: @MainActor () -> Bool = { instances().isEmpty && mainCount() == 0 }) throws {
        let before=try readAdmissions()
        guard before.pending == 0,before.sha256 == admissionsSHA else { throw ARLError(code:"install_reminders_work_changed") }
        let settled=ProcessInfo.processInfo.systemUptime+1
        while ProcessInfo.processInfo.systemUptime < settled {
            guard processesAbsent() else { throw ARLError(code:"install_reminders_restarted") }
            RunLoop.current.run(until:Date().addingTimeInterval(0.05))
        }
        let after=try readAdmissions()
        guard processesAbsent() else { throw ARLError(code:"install_reminders_restarted") }
        guard after.pending == 0,after.sha256 == admissionsSHA else { throw ARLError(code:"install_reminders_work_changed") }
    }
    static func quit(pid:Int32,birth:[UInt64],admissionsSHA:String) throws -> [String:Any] {
        guard pid > 1,birth.count == 2,admissionsSHA.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil,
              mainCount() == 0 else { throw ARLError(code:"install_reminders_owner_still_running") }
        let apps=instances()
        guard apps.count <= 1 else { throw ARLError(code:"install_reminders_multiple_instances") }
        if apps.isEmpty {
            guard kill(pid,0) == -1,errno == ESRCH else { throw ARLError(code:"install_reminders_generation_changed") }
            try confirmExit(admissionsSHA:admissionsSHA)
            return ["terminated":true,"already_absent":true]
        }
        let app=apps[0],value=try deployment(),record=try verified(app,value)
        guard record.pid == pid,record.birth == birth else { throw ARLError(code:"install_reminders_generation_changed") }
        let directory=URL(fileURLWithPath:value.host_home).appendingPathComponent("admissions")
        let before=try RemindersInstallAdmissions.read(directory)
        guard before.pending == 0,before.sha256 == admissionsSHA else { throw ARLError(code:"install_reminders_work_changed") }
        // Close the final observation/action gap with the same process object,
        // generation, signature and admission inventory. No force-quit fallback.
        guard mainCount() == 0,try verified(app,value) == record,
              try RemindersInstallAdmissions.read(directory).sha256 == before.sha256,
              app.terminate() else { throw ARLError(code:"install_reminders_quit_refused") }
        let deadline=ProcessInfo.processInfo.systemUptime+10
        while !app.isTerminated && ProcessInfo.processInfo.systemUptime < deadline {
            RunLoop.current.run(until:Date().addingTimeInterval(0.05))
        }
        guard app.isTerminated else { throw ARLError(code:"install_reminders_exit_unproven") }
        try confirmExit(admissionsSHA:admissionsSHA)
        return ["terminated":true,"already_absent":false]
    }
}
