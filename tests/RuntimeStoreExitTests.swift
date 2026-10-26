import Foundation

@MainActor final class ExitSuspension {
    var continuation: CheckedContinuation<Void, Never>?
    var entered = false
    func hold() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
@main struct RuntimeStoreExitTests {
    static func checkReminderAdmissionMetadata() throws {
        let repository=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent()
        let directory=repository.appendingPathComponent("build/audit/apple-nas-20261016/checks.noindex/reminder-admissions-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let empty=try RemindersInstallAdmissions.read(directory)
        precondition(empty.count == 0 && empty.pending == 0)
        let id=UUID().uuidString.lowercased(),file=directory.appendingPathComponent(id+".json")
        func write(_ state:String) throws {
            let raw:[String:Any] = ["request_id":id,"action":"request","frame_sha256":String(repeating:"a",count:64),"state":state,"outcome":"completed","code":"ok"]
            try JSONSerialization.data(withJSONObject:raw).write(to:file)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
        }
        try write("completed")
        let original=try Data(contentsOf:file),complete=try RemindersInstallAdmissions.read(directory)
        precondition(complete.count == 1 && complete.pending == 0 && complete.sha256 != empty.sha256)
        let afterRead=try Data(contentsOf:file)
        precondition(afterRead == original, "metadata check mutated its evidence")
        try write("pending")
        let pending=try RemindersInstallAdmissions.read(directory)
        precondition(pending.pending == 1 && pending.sha256 != complete.sha256)
        try write("unknown")
        do { _=try RemindersInstallAdmissions.read(directory);preconditionFailure("unknown journal state admitted") } catch { }
        try FileManager.default.removeItem(at:file)
        try FileManager.default.createSymbolicLink(at:file,withDestinationURL:directory.appendingPathComponent("absent"))
        do { _=try RemindersInstallAdmissions.read(directory);preconditionFailure("symlink journal admitted") } catch { }
        print("PASS: actual reminder admission metadata read; exact digest; pending/unknown/symlink states; no record mutation")
    }
    @MainActor static func checkReminderFinalExitGate() throws {
        let pin=String(repeating:"a",count:64),changed=String(repeating:"b",count:64)
        var reads=0,observations=0
        let started=ProcessInfo.processInfo.systemUptime
        try RemindersInstallDrain.confirmExit(admissionsSHA:pin,readAdmissions:{
            reads+=1;return .init(sha256:pin,count:7,pending:0)
        },processesAbsent:{ observations+=1;return true })
        precondition(reads == 2 && observations >= 2 && ProcessInfo.processInfo.systemUptime-started >= 1)
        for pending in [0,1] {
            reads=0
            do {
                try RemindersInstallDrain.confirmExit(admissionsSHA:pin,readAdmissions:{
                    reads+=1
                    return .init(sha256:reads == 1 || pending == 1 ? pin : changed,count:7,pending:reads == 1 ? 0 : pending)
                },processesAbsent:{ true })
                preconditionFailure("changed final admissions accepted")
            } catch let error as ARLError { precondition(error.code == "install_reminders_work_changed") }
        }
        for revived in ["helper","owner"] {
            observations=0
            do {
                try RemindersInstallDrain.confirmExit(admissionsSHA:pin,readAdmissions:{ .init(sha256:pin,count:7,pending:0) },processesAbsent:{
                    observations+=1;return observations == 1
                })
                preconditionFailure("revived \(revived) accepted")
            } catch let error as ARLError { precondition(error.code == "install_reminders_restarted") }
        }
        do {
            try RemindersInstallDrain.confirmExit(admissionsSHA:pin,readAdmissions:{ .init(sha256:pin,count:7,pending:1) },processesAbsent:{ true })
            preconditionFailure("pending final admission accepted")
        } catch let error as ARLError { precondition(error.code == "install_reminders_work_changed") }
        print("PASS: shared final exit gate waits one second; rejects final digest/pending drift and helper/owner revival; no real process calls")
    }
    @MainActor static func main() async throws {
        try checkReminderFinalExitGate()
        try checkReminderAdmissionMetadata()
        let candidate = URL(fileURLWithPath: CommandLine.arguments[1])
        let raw = try Data(contentsOf: candidate)
        let target = InstallManagement.target
        _ = try InstallManagement.authorityRequirement(raw, target: target)
        for duplicate in [Data("{\"schema\":3,".utf8) + raw.dropFirst(),
                          Data("{\"\\u0073chema\":3,".utf8) + raw.dropFirst()] {
            do { _ = try InstallManagement.authorityRequirement(duplicate, target: target); preconditionFailure("duplicate authority accepted") }
            catch { }
        }
        print("PASS: real candidate authority booleans/array; literal/escaped duplicate rejection")
        let store = RuntimeStore(arguments: ["ARL", "--demo"])
        let owner = BundledRuntimeOwner.fixture()
        store.testSetOwner(owner); owner.activationTestHook = { }
        store.testSetPermissionBusy(true);store.lifecycleWaitSeconds = 0.01
        let permissionTimedOut = await store.stopBackground()
        precondition(!permissionTimedOut && !store.testExitRequested && store.permissionBusy,
                     "quit bypassed an in-flight permission/helper launch or cancelled it")
        store.testSetPermissionBusy(false)

        store.testHoldLifecycle(); store.lifecycleWaitSeconds = 0.01
        let timedOut = await store.stopBackground()
        precondition(!timedOut && !store.testExitRequested)
        store.testReleaseLifecycle()
        let recoveredAfterTimeout = await owner.recover(home: URL(fileURLWithPath: "/fixture"))
        precondition(recoveredAfterTimeout, "timeout left owner exit flag set")
        store.testHoldLifecycle(); store.lifecycleWaitSeconds = 40
        let quit = Task { @MainActor in await store.stopBackground() }
        while !store.testExitRequested { await Task.yield() }
        quit.cancel(); let cancelled = await quit.value
        precondition(!cancelled && !store.testExitRequested)
        store.testReleaseLifecycle()
        let recoveredAfterCancel = await owner.recover(home: URL(fileURLWithPath: "/fixture"))
        precondition(recoveredAfterCancel, "cancellation left owner exit flag set")
        // Cancellation while the owner's operation is still suspended must
        // clear the exit request without clearing its operation token/children.
        let gate = ExitSuspension(); owner.afterDrainTestHook = { await gate.hold() }
        let recovery = Task { @MainActor in await owner.recover(home: URL(fileURLWithPath: "/fixture")) }
        while !gate.entered { await Task.yield() }
        let overlappingQuit = Task { @MainActor in await store.stopBackground() }
        while !store.testExitRequested { await Task.yield() }
        overlappingQuit.cancel(); let overlappingResult = await overlappingQuit.value
        precondition(!overlappingResult && !store.testExitRequested)
        gate.release(); let completedRecovery = await recovery.value
        precondition(completedRecovery, "cancelled quit stranded in-flight recovery")
        owner.afterDrainTestHook = nil
        store.testSetPermissionBusy(true)
        let finalQuit = Task { @MainActor in await store.stopBackground() }
        while !store.testExitRequested { await Task.yield() }
        precondition(store.permissionBusy, "quit changed an accepted native task")
        store.performPermission("apple.calendar.create",action:"request")
        precondition(store.permissionMessage == "正在退出，操作尚未开始。")
        store.testSetPermissionBusy(false)
        let final = await finalQuit.value; precondition(final)
        print("PASS: accepted native task drains before owner; timeout preserves task; exit rejects new permission work")
        print("PASS: actual RuntimeStore timeout/cancel; in-flight owner cancellation; recovery; final drain")
        // A previously accepted click has queued a main-actor task, but the
        // transport/launch has not started when normal exit closes admission.
        let queued=RuntimeStore(arguments:["ARL","--demo"])
        var queuedRequests=0,queuedStops=0
        queued.remindersRequestTestHook = { action,id,launch in
            queuedRequests+=1
            return .init(schema_version:1,request_id:id.uuidString.lowercased(),action:action,outcome:"refreshed",code:"ok",snapshot:nil)
        }
        queued.remindersStopTestHook = { queuedStops+=1 }
        precondition(queued.canInspectReminders)
        queued.performRemindersFirst(.snapshot)
        precondition(queued.permissionBusy && queuedRequests == 0)
        let queuedExit=await queued.stopBackground()
        precondition(queuedExit && queuedRequests == 0 && queuedStops == 1 && !queued.permissionBusy)

        // An already-sent request may still be starting the helper. Exit waits
        // for that exact request; after helper shutdown, a late click cannot
        // reopen it while the main process is finishing its own drain.
        let sent=RuntimeStore(arguments:["ARL","--demo"])
        let requestGate=ExitSuspension(),stopGate=ExitSuspension()
        var sentRequests=0,sentStops=0,helperRunning=false
        sent.remindersRequestTestHook = { action,id,launch in
            precondition(launch)
            sentRequests+=1
            await requestGate.hold()
            helperRunning=true
            return .init(schema_version:1,request_id:id.uuidString.lowercased(),action:action,outcome:"refreshed",code:"ok",snapshot:nil)
        }
        sent.remindersStopTestHook = {
            sentStops+=1;helperRunning=false
            await stopGate.hold()
        }
        sent.performRemindersFirst(.snapshot)
        while !requestGate.entered { await Task.yield() }
        let sentExit=Task { @MainActor in await sent.stopBackground() }
        while !sent.testExitRequested { await Task.yield() }
        precondition(sentStops == 0 && sent.permissionBusy)
        requestGate.release()
        while !stopGate.entered { await Task.yield() }
        precondition(!helperRunning && !sent.canInspectReminders)
        sent.performRemindersFirst(.snapshot)
        precondition(sentRequests == 1 && !helperRunning)
        stopGate.release()
        let sentExited=await sentExit.value
        precondition(sentExited && sentRequests == 1 && sentStops == 1 && !helperRunning)
        print("PASS: queued reminder task never launches on exit; sent task finishes before shutdown; late snapshot cannot relaunch stopped helper")
    }
}
