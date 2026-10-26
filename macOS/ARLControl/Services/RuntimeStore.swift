import SwiftUI
import Observation
import ARLCredentialHostCore
import ARLCredentialOnboarding

@MainActor @Observable
final class RuntimeStore {
    static weak var active: RuntimeStore?
    let moments: MomentsController
    private(set) var snapshot: RuntimeSnapshot?
    private(set) var runtimeDescription: MetadataFeature<ARLJSON> = .unsupported
    private(set) var reading = false
    private(set) var errorCode: String?
    private(set) var lastUpdated: Date?
    private(set) var control = ControlPlaneState.unavailable
    private(set) var controlError: String?
    private(set) var modules: MetadataFeature<ModulesSnapshot> = .unsupported
    private(set) var mioCalendarPermission: MetadataFeature<MioCalendarPermissionStatus> = .unsupported
    private(set) var permissions: MetadataFeature<ApplePermissionSnapshot> = .unsupported
    private(set) var permissionBusy = false
    private(set) var permissionMessage: String?
    private var permissionGeneration = 0
    private(set) var remindersFirst:MetadataFeature<RemindersFirstSnapshot> = .unsupported
    private(set) var remindersConfigured=false
    private(set) var remindersServiceState:RemindersServiceState = .notInstalled
    private(set) var remindersMessage:String?
    private(set) var remindersRequestID:UUID?
    private(set) var remindersProduct:RemindersProductController?
    private(set) var remindersTask:RemindersTaskRecord?
    private(set) var remindersTaskCurrentID:String?
    private(set) var remindersTaskPage:RemindersTaskPage?
    private(set) var remindersTaskMessage:String?
    private(set) var remindersTaskNeedsScope=false
    private(set) var remindersTaskUnconfirmed=false
    private(set) var remindersTaskMissing=false
    private(set) var history = PerformanceHistory()
    private(set) var logPaging = LogPagingState()
    private var logTask: Task<Void, Never>?
    private var logLevel: String?
    private var logSessionReading = false
    private(set) var legacyLogs = false
    private(set) var logReadError: String?
    private(set) var lastLogSuccess: Date?
    private var lastSuccessfulLogPage: RedactedLogPage?
    private var legacyLogGeneration = 0
    private var legacyLogReadingGeneration: Int?
    let service: SettingsService
    private let calendarHome: URL
    let nasSettings: ARLNASSetupModel
    let messagesFeature: MessagesProductFeatureV2
    let appleEventsExecutor: AppleDirectExecutor
    let notesDirect: NotesDirectController
    let messagesDirect: MessagesDirectController
    let notesPermissions: NotesPermissionController
    @ObservationIgnored private var nasFileExecutor: NASFileExecutor?
    @ObservationIgnored private var appleOwnerExecutor: AppleOwnerExecutor?
    @ObservationIgnored private var appleReminderTask: Task<Void,Never>?
    @ObservationIgnored private var activeAppleCallID: UUID?
    @ObservationIgnored private var remindersRestoreTask: Task<Void,Never>?
    private(set) var remindersRestoring = false
    private(set) var remindersStatusFailure: String?
    private(set) var calendarBusiness:CalendarBusinessController?
    @ObservationIgnored private var calendarBusinessHandler:CalendarBusinessHandler?
    @ObservationIgnored private var appleProductExecutor:AppleProductOwnerExecutor?
    let calendarPermission: CalendarPermissionController
    let codex: CodexNativeController
    let credentialBootstrap: CredentialHostBootstrap
    @ObservationIgnored private var bundledRuntimeOwner: BundledRuntimeOwner?
    @ObservationIgnored private var credentialReadOwner: CredentialReadOwnerServer?
    private(set) var credentialOwnerStatus = OwnerReadLifecycle.Snapshot.disabled
    @ObservationIgnored private var lifecycleOperation: UUID?
    @ObservationIgnored private var exitRequested = false
    @ObservationIgnored private var exitOperation: UUID?
    #if ARL_LIFECYCLE_TEST
    var lifecycleWaitSeconds: TimeInterval = 40
    var remindersRequestTestHook: ((RemindersFirstAction, UUID, Bool) async throws -> RemindersFirstReply)?
    var remindersStopTestHook: (() async throws -> Void)?
    func testSetOwner(_ owner: BundledRuntimeOwner) { bundledRuntimeOwner = owner }
    func testHoldLifecycle() { lifecycleOperation = UUID() }
    func testReleaseLifecycle() { lifecycleOperation = nil }
    func testSetPermissionBusy(_ busy: Bool) { permissionBusy = busy }
    var testExitRequested: Bool { exitRequested }
    #endif
    private(set) var bundledRuntimeError: String?
    private(set) var bundledRuntimeRecovering = false
    private(set) var credentialOwnerRecovering = false
    private(set) var credentialOwnerMessage: String?
    let demo: Bool
    #if ARL_FUTURE_OCT3
    let sourceActionsHeld = true
    #else
    let sourceActionsHeld = false
    #endif
    var nativeActionsHeld: Bool { sourceActionsHeld || maintenanceActive }
    let maintenanceActive: Bool
    let isolated: Bool
    private let requiresIsolatedHome: Bool
    init(arguments: [String] = CommandLine.arguments, nasControllerPort: (any ARLNASManualControllerPort)? = nil, messagesAdmission: MessagesProductAdmission? = nil) {
        demo = arguments.contains("--demo")
        isolated = arguments.contains("--runtime-home") || Bundle.main.bundleIdentifier == "local.arl.control.dev"
        requiresIsolatedHome = Bundle.main.bundleIdentifier == "local.arl.control.dev" && !arguments.contains("--runtime-home") && !demo
        var home = SettingsService.defaultHome
        if let index = arguments.firstIndex(of: "--runtime-home"), arguments.indices.contains(index + 1) {
            home = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        }
        maintenanceActive = FileManager.default.fileExists(atPath: home.appendingPathComponent("install-maintenance.json").path)
        let actionsHeld = sourceActionsHeld || maintenanceActive
        // Source/demo isolation stops before authority-file access. An admitted
        // final host uses the owner's exact local-login ACL bootstrap; native
        // signing checks still precede every item/provider operation.
        credentialBootstrap = actionsHeld || demo ? .disabled() : .load()
        moments = MomentsController(home: home, enabled: !actionsHeld && !demo && !isolated && !requiresIsolatedHome)
        calendarHome = home
        service = SettingsService(home: home, demo: demo, nativeActionsHeld: actionsHeld)
        if !actionsHeld && !demo && !isolated && !requiresIsolatedHome,
           let id=UserDefaults.standard.string(forKey:"remindersCurrentTaskV1"),RemindersTaskContract.uuid(id){remindersTaskCurrentID=id}
        nasSettings = nasControllerPort.map { ARLNASSettingsComposition.makeModel(port: $0) }
            ?? ARLNASSettingsComposition.makeProductionModel(owner: credentialBootstrap.service.nas, home: home,
                enabled: credentialBootstrap.configured && !actionsHeld && !demo && !isolated && !requiresIsolatedHome)
        // Only a separately reviewed composition owner may supply exact admission pins.
        // No persisted config, launch argument or UI action creates admission here.
        messagesFeature = MessagesProductFeatureV2(home: home, demo: demo,
            isolated: isolated || requiresIsolatedHome, sourceHeld: actionsHeld,
            admission: messagesAdmission)
        appleEventsExecutor = AppleDirectExecutor()
        notesDirect = NotesDirectController(home: home,
            enabled: !actionsHeld && !demo && !isolated && !requiresIsolatedHome,
            executor: appleEventsExecutor)
        messagesDirect = MessagesDirectController(home: home,
            enabled: !actionsHeld && !demo && !isolated && !requiresIsolatedHome,
            executor: appleEventsExecutor)
        calendarPermission = CalendarPermissionController(enabled: !actionsHeld && !demo && !isolated && !requiresIsolatedHome)
        codex = CodexNativeController(home: home,
            enabled: !actionsHeld && !demo && !isolated && !requiresIsolatedHome)
        notesPermissions = NotesPermissionController(home: home, demo: demo, sourceHeld: actionsHeld)
        bundledRuntimeOwner = .start(home: home, enabled: !sourceActionsHeld && !demo && !isolated && !requiresIsolatedHome)
        configureAppleExecutor()
        configureAppleProductExecutor()
        configureNASFileExecutor()
        credentialReadOwner = .start(service: credentialBootstrap.service,
            enabled: credentialBootstrap.configured && !actionsHeld && !demo && !isolated && !requiresIsolatedHome,
            appleCall: appleOwnerCall, nasCall: nasOwnerCall)
        if !demo && !isolated && !requiresIsolatedHome { Self.active = self }
        moments.attachNAS(nasSettings.archivePickerOwner)
        restoreRemindersConnection()
    }
    func stopBackground() async -> Bool {
        guard exitOperation == nil else { return false }
        let exitToken = UUID(); exitOperation = exitToken
        notesDirect.suspendForExit(); messagesDirect.suspendForExit(); calendarPermission.suspendForExit(); calendarBusiness?.suspendForExit(); codex.suspendForExit()
        var completed = false
        defer {
            if exitOperation == exitToken {
                exitOperation = nil
                if !completed {
                    exitRequested = false; bundledRuntimeOwner?.cancelExit(); moments.cancelExit()
                    nasFileExecutor?.resumeAfterCancelledExit()
                    observeCredentialOwner()
                    notesDirect.resumeAfterCancelledExit(); messagesDirect.resumeAfterCancelledExit(); calendarPermission.resumeAfterCancelledExit(); calendarBusiness?.resumeAfterCancelledExit(); codex.resumeAfterCancelledExit()
                }
            }
        }
        exitRequested = true; bundledRuntimeOwner?.requestExit()
        nasFileExecutor?.suspendForExit()
        remindersRestoreTask?.cancel(); appleReminderTask?.cancel()
        #if ARL_LIFECYCLE_TEST
        let waitSeconds = lifecycleWaitSeconds
        #else
        let waitSeconds: TimeInterval = 40
        #endif
        let deadline = ProcessInfo.processInfo.systemUptime + waitSeconds
        while (lifecycleOperation != nil || permissionBusy || codex.busy || nasFileExecutor?.busy == true || remindersRestoring || notesDirect.busy || messagesDirect.busy || calendarPermission.busy || calendarBusiness?.busy == true || calendarBusinessHandler?.busy == true) && ProcessInfo.processInfo.systemUptime < deadline {
            do { try await Task.sleep(for: .milliseconds(20)) } catch { return false }
        }
        guard lifecycleOperation == nil, !permissionBusy, !codex.busy, nasFileExecutor?.busy != true, !remindersRestoring, !notesDirect.busy, !messagesDirect.busy, !calendarPermission.busy, calendarBusiness?.busy != true, calendarBusinessHandler?.busy != true, !Task.isCancelled else { return false }
        let token = UUID(); lifecycleOperation = token
        defer { if lifecycleOperation == token { lifecycleOperation = nil } }
        guard await moments.stop() else { return false }
        await credentialBootstrap.service.nas.stop()
        do { try await stopRemindersForAppExit() }
        catch {
            credentialOwnerMessage = (error as? RemindersTransportFault)?.code == "request_busy"
                ? "提醒操作尚未结束，请稍后退出。" : "提醒服务尚未退出，请检查连接。"
            return false
        }
        if let bundledRuntimeOwner, !(await bundledRuntimeOwner.stopAndDrain(forExit: true)) { return false }
        if let credentialReadOwner, !(await credentialReadOwner.stopAndDrain()) {
            credentialOwnerMessage = "后台仍在收尾，请稍后再退出。"
            return false
        }
        notesDirect.finishExit(); messagesDirect.finishExit()
        completed = true
        return true
    }
    private func stopRemindersForAppExit() async throws {
        #if ARL_LIFECYCLE_TEST
        if let remindersStopTestHook { try await remindersStopTestHook();return }
        #endif
        if !sourceActionsHeld && !demo && !isolated && !requiresIsolatedHome {
            try await RemindersNativeClient(home:calendarHome).stopForAppExit()
        }
    }
    func observeCredentialOwner() {
        bundledRuntimeError = bundledRuntimeOwner?.failure
        credentialOwnerStatus = credentialReadOwner?.snapshot ?? .disabled
    }
    func recoverBundledRuntime() {
        guard let owner = bundledRuntimeOwner, owner.failure != nil, !bundledRuntimeRecovering, !exitRequested, lifecycleOperation == nil else { return }
        let token = UUID(); lifecycleOperation = token
        bundledRuntimeRecovering = true
        Task {
            defer { if lifecycleOperation == token { lifecycleOperation = nil } }
            _ = await owner.recover(home: calendarHome)
            bundledRuntimeRecovering = false; observeCredentialOwner()
            await refresh()
        }
    }
    var canRecoverCredentialOwner: Bool {
        credentialReadOwner != nil && credentialOwnerStatus.canRequestRecovery && !credentialOwnerRecovering && !exitRequested && lifecycleOperation == nil
    }
    func recoverCredentialOwner() {
        observeCredentialOwner()
        guard canRecoverCredentialOwner, let previous = credentialReadOwner else { return }
        let token = UUID(); lifecycleOperation = token
        credentialOwnerRecovering = true; credentialOwnerMessage = nil
        Task {
            defer { credentialOwnerRecovering = false; if lifecycleOperation == token { lifecycleOperation = nil }; observeCredentialOwner() }
            guard await previous.stopAndDrain() else {
                credentialOwnerMessage = "旧连接尚未确认结束，请稍后再检查恢复。"; return
            }
            guard lifecycleOperation == token, !exitRequested else { return }
            // Reuse the existing SDK and its exact-generation process barrier.
            // Never recreate credentials, replay a journal, or retry a business call.
            switch await credentialBootstrap.service.ownerRecoveryReadiness() {
            case .busy:
                credentialOwnerMessage = "现有服务请求尚未结束，请稍后再检查恢复。"; return
            case .cleanupUnproven:
                credentialOwnerMessage = "底层任务清理尚未确认，连接继续保持暂停。"; return
            case .ready: break
            }
            guard !Task.isCancelled, lifecycleOperation == token, !exitRequested else { return }
            credentialReadOwner = .start(service: credentialBootstrap.service, enabled: true, appleCall: appleOwnerCall, nasCall: nasOwnerCall)
            credentialOwnerMessage = "已重新开始核验本机连接；原业务请求不会自动重试。"
        }
    }
    func refresh(resetLogs: Bool = false) async {
        calendarPermission.refresh()
        observeCredentialOwner()
        defer { observeCredentialOwner() }
        guard !requiresIsolatedHome else { snapshot = nil; control = .unavailable; modules = .unavailable("dev_runtime_home_required"); permissions = .unavailable("dev_runtime_home_required"); errorCode = "dev_runtime_home_required"; return }
        guard !reading else { return }
        if resetLogs { legacyLogGeneration &+= 1; logTask?.cancel(); if !legacyLogs { logPaging.reset() } }
        reading = true
        defer { reading = false }
        do {
            snapshot = try await service.read(); errorCode = nil; lastUpdated = Date()
            runtimeDescription = await service.readRuntimeDescription()
            do {
                let next = try await service.readControlPlane(); control = next; controlError = nil
                restoreCachedLogs()
                let sample = ResourceSampleState(load: control.metrics.value, connected: true, now: Date())
                if let load = sample.current { history.append(load) } else { history.interrupt() }
                if control.runtime.value != nil, await synchronizeLogSession() {
                    if logPaging.page == nil || logPaging.hasUnseenTail { requestLogPage() }
                    if logPaging.page == nil { await logTask?.value }
                }
            } catch {
                // Transient control-plane failures retain dated evidence;
                // explicit connection loss invalidates the live session.
                let code = (error as? ARLError)?.code ?? "invalid_response"
                controlError = code
                if Self.explicitLossCodes.contains(code) {
                    invalidateRuntime(code)
                    if code == "disconnected" { await refreshIndependentNativeStatus() }
                    return
                }
                if control.logs.value == nil && lastSuccessfulLogPage == nil {
                    logReadError = code
                    control.logs = .unavailable(code)
                }
            }
            modules = await service.readModules()
        }
        catch {
            let code = (error as? ARLError)?.code ?? "invalid_response"
            errorCode = code
            if Self.explicitLossCodes.contains(code) {
                invalidateRuntime(code)
                if code == "disconnected" { await refreshIndependentNativeStatus() }
                return
            }
            // A failed poll is not an observed disconnection. Keep the last
            // successful snapshot and its original timestamp until recovery.
        }
        let generation=permissionGeneration
        let nextPermissions=await service.readPermissions()
        if generation==permissionGeneration{permissions=nextPermissions}
        await refreshIndependentNativeStatus()
    }
    // These clients verify their own installed identity and configuration; neither
    // depends on Python metadata RPC. Only a transport disconnection reaches here
    // after explicit loss; unsafe homes, disabled service and identity failures do not.
    private func refreshIndependentNativeStatus() async {
        guard !nativeActionsHeld, !demo, !requiresIsolatedHome else { return }
        await codex.refreshStatus()
        remindersConfigured=await service.remindersConfigured()
        remindersServiceState=await service.remindersServiceState()
        let generation=permissionGeneration
        let nextReminders=await service.readRemindersFirst()
        let nextCalendar=await service.readMioCalendarPermission()
        if generation==permissionGeneration {
            if let value=nextReminders.value { remindersFirst = .available(value);remindersStatusFailure=nil }
            else if remindersFirst.value == nil { remindersFirst=nextReminders }
            else { remindersStatusFailure="status_unavailable" }
            mioCalendarPermission=nextCalendar
        }
    }
    private static let explicitLossCodes: Set<String> = ["disconnected", "unsafe_home", "app_identity_unverified", "user_disabled", "dev_runtime_home_required"]
    private func invalidateRuntime(_ code: String) {
        legacyLogGeneration &+= 1
        permissionGeneration &+= 1
        logTask?.cancel(); logTask = nil; logPaging.disconnect(); history.interrupt()
        legacyLogs = false
        errorCode = code; snapshot = nil; lastUpdated = nil
        control = .unavailable; controlError = nil
        lastSuccessfulLogPage = nil; lastLogSuccess = nil; logReadError = code
        modules = .unavailable(code); permissions = .unavailable(code); remindersFirst = .unavailable(code)
        mioCalendarPermission = .unavailable(code)
    }
    var canInspectReminders: Bool {
        guard !exitRequested, !nativeActionsHeld, !permissionBusy else { return false }
        #if ARL_LIFECYCLE_TEST
        if demo, remindersRequestTestHook != nil { return true }
        #endif
        return !demo && !requiresIsolatedHome && remindersServiceState.canConnect
            && !["unsafe_home", "app_identity_unverified", "user_disabled", "dev_runtime_home_required"].contains(errorCode ?? "")
    }
    func performRemindersFirst(_ action:RemindersFirstAction) {
        // Snapshot/retest only inspect permission and local lifecycle metadata.
        // All permission requests, source selection and effects still need the
        // original connected-runtime admission, plus native verification below.
        let statusOnly = action == .snapshot || action == .retest
        guard canInspectReminders, statusOnly || connected else{return}
        // A stale request click must refresh the current OS grant, not call
        // EventKit's request path again after this helper is already authorized.
        let effectiveAction:RemindersFirstAction = action == .request && remindersFirst.value?.permission_state == "authorized_full" ? .retest : action
        permissionBusy=true;permissionGeneration+=1;remindersMessage=nil
        let id=UUID();remindersRequestID=id
        Task {
            defer{permissionBusy=false;remindersRequestID=nil}
            // A click may have queued this task before exit closed admission.
            // Do not launch a helper after its owner has started draining.
            guard !exitRequested else { remindersMessage="正在退出，操作尚未开始。";return }
            do {let reply=try await sendRemindersFirst(effectiveAction,requestID:id,launch:effectiveAction == .snapshot)
                if let value=reply.snapshot{remindersFirst = .available(value)}
                remindersMessage=RemindersFirstCopy.message(outcome:reply.outcome,code:reply.code)
            }catch{remindersMessage="流程未完成：\((error as? RemindersTransportFault)?.code ?? "unavailable")；请核查原请求，勿自动重复保存。";remindersFirst=await service.readRemindersFirst()}
            permissions=await service.readPermissions()
        }
    }
    private func sendRemindersFirst(_ action: RemindersFirstAction, requestID: UUID, launch: Bool) async throws -> RemindersFirstReply {
        #if ARL_LIFECYCLE_TEST
        if demo, let remindersRequestTestHook { return try await remindersRequestTestHook(action,requestID,launch) }
        #endif
        return try await service.performRemindersFirst(action,requestID:requestID,launch:launch)
    }
    func performRemindersTask(_ action:RemindersFirstAction,taskID:String?=nil,title:String?=nil,expected:String?=nil,offset:Int?=nil) {
        let readonly=action == .task_status || action == .task_list
        guard RemindersTaskContract.actions.contains(action),canInspectReminders,readonly || connected,NSApp.isActive else{return}
        let id=UUID()
        let frame=RemindersFirstFrame(task:action,requestID:id,taskID:taskID,title:title,expected:expected,offset:offset)
        guard (try? RemindersFirstFrame.decode(JSONEncoder().encode(frame))) != nil else{return}
        if action == .task_prepare,let taskID {remindersTaskCurrentID=taskID;UserDefaults.standard.set(taskID,forKey:"remindersCurrentTaskV1")}
        if !readonly {
            guard appleReminderTask == nil,let executor=appleOwnerExecutor else { return }
            appleReminderTask=Task { [weak self] in
                guard let self else { return }
                defer { appleReminderTask=nil }
                guard !exitRequested,!Task.isCancelled else { return }
                do {
                    let bytes=try await executor.executeLocal(frame,callID:UUID())
                    let result=try JSONDecoder().decode(AppleOwnerResult.self,from:bytes)
                    if result.state == "outcome_unknown" {
                        remindersTaskUnconfirmed=true;remindersTaskMessage="结果未确认，请查看同一条任务记录。"
                    } else if result.state == "not_dispatched" {
                        remindersTaskUnconfirmed=false;remindersTaskMessage="本次尚未提交保存，请查看原任务状态。"
                    } else if result.state == "owner_busy" { remindersTaskMessage="当前有操作进行中，请查看原任务结果。" }
                } catch { remindersTaskUnconfirmed=true;remindersTaskMessage="本次结果未确认，请查看同一条任务记录。" }
            }
            return
        }
        permissionBusy=true;permissionGeneration+=1;remindersRequestID=id;remindersTaskMessage=nil
        Task {
            defer{permissionBusy=false;remindersRequestID=nil}
            guard !exitRequested else{remindersTaskMessage="正在退出，操作尚未开始。";return}
            do {
                let reply=try await service.performRemindersTask(frame)
                applyRemindersTaskReply(reply)
            } catch {
                remindersTaskUnconfirmed=true
                remindersTaskMessage="结果未确认，请查看同一操作记录。"
            }
        }
    }
    private func applyRemindersTaskReply(_ reply: RemindersFirstReply) {
        let action=reply.action
        if let snapshot=reply.snapshot{remindersFirst = .available(snapshot)}
        if let page=reply.task_page{remindersTaskPage=page}
        if let task=reply.task{
            remindersTask=task;remindersTaskCurrentID=task.task_id;remindersTaskUnconfirmed=false;remindersTaskMissing=false
            UserDefaults.standard.set(task.task_id,forKey:"remindersCurrentTaskV1")
            if action == .task_scope{remindersTaskNeedsScope=false}
        }
        if reply.code == "task_scope_required"{remindersTaskNeedsScope=true}
        if reply.code == "task_not_found"{remindersTaskMissing=true;remindersTask=nil}
        remindersTaskMessage=RemindersTaskCopy.message(outcome:reply.outcome,code:reply.code)
    }
    private var nasOwnerCall: CredentialReadOwnerServer.NASCall {
        { [weak self] request in
            guard let self,let id=UUID(uuidString:request.callID) else { throw OwnerReadFault.held }
            return try await self.performNASFileCall(tool:request.tool,argumentsJSON:request.argumentsJSON,callID:id)
        }
    }
    private func configureNASFileExecutor() {
        let model=nasSettings
        let journal=NASBusinessJournal(directory:calendarHome.appendingPathComponent("nas-business-v1.noindex"))
        var port=NASFileExecutor.Port(allowed:{ [weak self] in
            guard let self else{return false}
            return !exitRequested && !nativeActionsHeld && !demo && !isolated && !requiresIsolatedHome
        },connectSavedScope:{try await model.connectSavedReadScope()},consume:{tool,args in
            try await model.consumeFileRead(tool:tool,argumentsJSON:args)
        },record:{tool,id,args,result in
            do {
                if NASDownloadCapability.names.contains(tool) {
                    _=try NASCapability.request(tool:tool,argumentsJSON:args)
                    try journal.recordTransfer(tool:tool,callID:id,argumentsJSON:args,responseJSON:result)
                } else {try journal.record(tool:tool,callID:id,argumentsJSON:args,responseJSON:result)}
            }
            catch {throw OwnerReadFault.businessLogUnavailable}
        })
        port.validateContext={source,generation,epoch in
            try await model.validateReadContext(sourceRef:source,generation:generation,epoch:epoch)
        }
        nasFileExecutor=NASFileExecutor(port:port)
    }
    /// Local UI and authenticated Mio enter the exact same business boundary.
    func performNASFileCall(tool:String,argumentsJSON:Data,callID:UUID=UUID()) async throws -> Data {
        guard let executor=nasFileExecutor else{throw OwnerReadFault.held}
        return try await executor.execute(tool:tool,argumentsJSON:argumentsJSON,callID:callID)
    }
    private var appleOwnerCall: CredentialReadOwnerServer.AppleCall {
        { [weak self] request in
            guard let self else { throw OwnerReadFault.held }
            return try await self.executeAppleRequest(request)
        }
    }
    private func executeAppleRequest(_ request: OwnerReadRequest) async throws -> Data {
        if AppleProductCapability.names.contains(request.tool) {
            guard let executor=appleProductExecutor,let id=UUID(uuidString:request.callID) else{throw OwnerReadFault.held}
            return try await executor.execute(tool:request.tool,argumentsJSON:request.argumentsJSON,callID:id)
        }
        guard let executor=appleOwnerExecutor,let id=UUID(uuidString:request.callID) else { throw OwnerReadFault.held }
        return try await executor.execute(tool:request.tool,argumentsJSON:request.argumentsJSON,callID:id)
    }
    private func configureAppleExecutor() {
        let settings=service
        let journal=AppleBusinessJournal(directory:calendarHome.appendingPathComponent("apple-business-v1.noindex"))
        appleOwnerExecutor=AppleOwnerExecutor(port:.init(begin:{ [weak self] id in
            guard let self,!exitRequested,!nativeActionsHeld,!demo,!isolated,!requiresIsolatedHome,!permissionBusy else { return false }
            permissionBusy=true;permissionGeneration += 1;activeAppleCallID=id;remindersRequestID=id;remindersTaskMessage=nil
            return true
        },end:{ [weak self] id in
            guard let self,activeAppleCallID==id else { return }
            permissionBusy=false;activeAppleCallID=nil;remindersRequestID=nil
        },ensureService:{ [weak self] in
            let reply=try await settings.restoreRemindersConnection()
            if let snapshot=reply.snapshot { self?.remindersFirst = .available(snapshot) }
            guard reply.snapshot?.permission_state == "authorized_full" else { throw RemindersTransportFault("needs_permission") }
        },send:{ [weak self] frame in
            self?.remindersRequestID=UUID(uuidString:frame.request_id)
            return try await settings.performRemindersTask(frame)
        },observe:{ [weak self] reply in self?.applyRemindersTaskReply(reply) },record:{ tool,id,args,reply in
            try journal.record(tool:tool,callID:id,argumentsJSON:args,responseJSON:reply)
        }))
        remindersProduct=RemindersProductController(port:.init(begin:{[weak self] id in
            guard let self,!exitRequested,!nativeActionsHeld,!demo,!isolated,!requiresIsolatedHome,!permissionBusy else{return false}
            permissionBusy=true;permissionGeneration+=1;activeAppleCallID=id;remindersRequestID=id
            return true
        },end:{[weak self] id in
            guard let self,activeAppleCallID==id else{return}
            permissionBusy=false;activeAppleCallID=nil;remindersRequestID=nil
        },ensureService:{[weak self] in
            let reply=try await settings.restoreRemindersConnection()
            if let snapshot=reply.snapshot {self?.remindersFirst = .available(snapshot)}
            guard reply.snapshot?.permission_state=="authorized_full" else{throw RemindersTransportFault("needs_permission")}
        },send:{frame in try await settings.performRemindersProduct(frame)},record:{tool,id,args,reply in
            try journal.recordProduct(tool:tool,callID:id,argumentsJSON:args,responseJSON:reply)
        }))
    }
    private func verifyAppleProductAdmission()throws {
        guard !exitRequested,!nativeActionsHeld,!demo,!isolated,!requiresIsolatedHome else{throw OwnerReadFault.held}
        _=try OwnerReadAuthority.load(role:.owner)
        try Task.checkCancellation()
    }
    private func configureAppleProductExecutor() {
        guard let remindersProduct else{return}
        let store=CalendarBusinessTaskStore(home:calendarHome)
        let journal=AppleBusinessJournal(directory:calendarHome.appendingPathComponent("apple-business-v1.noindex"))
        let backend=CalendarEventKitBackend()
        let handler=CalendarBusinessHandler(backend:backend,port:.init(verify:{[weak self] in
            guard let self else{throw OwnerReadFault.held};try self.verifyAppleProductAdmission()
        },lookup:{try store.lookup($0)},approve:{claim in
            let current=try claim.request.target.map{try backend.get($0)}
            let details=try CalendarBusinessConfirmation.details(claim,current:current)
            return await AppleProductOwnerExecutor.confirm(claim.request.action == .delete ? "删除本次日程":"保存日程",details)
        },claim:{try store.claim($0)},finish:{try store.finish($0)},record:{request,reply in
            try journal.recordProduct(tool:request.action.tool,callID:UUID(uuidString:request.task_id)!,argumentsJSON:request.argumentsJSON(),responseJSON:try reply.map{try CalendarBusinessContract.encode($0)})
        }))
        calendarBusinessHandler=handler
        calendarBusiness=CalendarBusinessController(permission:calendarPermission,handler:handler)
        appleProductExecutor=AppleProductOwnerExecutor(home:calendarHome,events:appleEventsExecutor,reminders:remindersProduct,calendar:handler,port:.init(begin:{[weak self] id in
            guard let self,!exitRequested,!nativeActionsHeld,!demo,!isolated,!requiresIsolatedHome,!permissionBusy,!notesDirect.busy,!messagesDirect.busy else{return false}
            permissionBusy=true;permissionGeneration+=1;activeAppleCallID=id
            return true
        },end:{[weak self] id in
            guard let self,activeAppleCallID==id else{return};permissionBusy=false;activeAppleCallID=nil
        },verify:{[weak self] in
            guard let self else{throw OwnerReadFault.held};try self.verifyAppleProductAdmission()
        },notesFolder:{[weak self] in self?.notesDirect.scope?.folder},messagesAccount:{[weak self] in self?.messagesDirect.selectedAccount}))
    }
    func createReminder(title: String, taskID: String) {
        guard !exitRequested,!nativeActionsHeld,!demo,!isolated,!requiresIsolatedHome,!permissionBusy,appleReminderTask == nil,NSApp.isActive,
              RemindersTaskContract.uuid(taskID),(try? RemindersTaskContract.title(title)) != nil,
              let executor=appleOwnerExecutor else { return }
        remindersTaskCurrentID=taskID;UserDefaults.standard.set(taskID,forKey:"remindersCurrentTaskV1")
        let args:Data
        do { args=try OwnerReadWire.encode(["task_id":taskID,"title":title],limit:OwnerReadWire.requestLimit) }
        catch { remindersTaskMessage="请核对提醒内容。";return }
        appleReminderTask=Task { [weak self] in
            guard let self else { return }
            defer { appleReminderTask=nil }
            guard !exitRequested,!Task.isCancelled else { return }
            do {
                let bytes=try await executor.execute(tool:AppleCapability.reminderCreate,argumentsJSON:args,callID:UUID())
                let result=try JSONDecoder().decode(AppleOwnerResult.self,from:bytes)
                if result.state == "outcome_unknown" {
                    remindersTaskUnconfirmed=true;remindersTaskMessage="结果未确认，请查看同一条任务记录。"
                } else if result.state == "not_dispatched" {
                    remindersTaskUnconfirmed=false
                    remindersTaskMessage=result.code == "needs_permission" ? "请先允许访问提醒事项，本次尚未创建。"
                        : result.code == "cancelled" ? "本次已取消，尚未提交保存。" : "本次尚未提交创建，请检查提醒服务。"
                } else if result.state == "owner_busy" { remindersTaskMessage="当前有操作进行中，请查看原任务结果。" }
            } catch { remindersTaskUnconfirmed=true;remindersTaskMessage="本次结果未确认，请查看同一条任务记录。" }
        }
    }
    func restoreRemindersConnection() {
        guard !exitRequested,!nativeActionsHeld,!demo,!isolated,!requiresIsolatedHome,!remindersRestoring else { return }
        remindersRestoring=true
        remindersRestoreTask=Task { [weak self] in
            guard let self else { return }
            defer { remindersRestoring=false;remindersRestoreTask=nil }
            do {
                let reply=try await service.restoreRemindersConnection()
                guard !Task.isCancelled,!exitRequested else { return }
                if let value=reply.snapshot { remindersFirst = .available(value);remindersStatusFailure=nil }
                remindersConfigured=await service.remindersConfigured();remindersServiceState=await service.remindersServiceState()
            } catch {
                guard !Task.isCancelled,!exitRequested else { return }
                remindersStatusFailure=(error as? RemindersTransportFault)?.code ?? "status_unavailable"
            }
        }
    }
    func prepareRemindersPage() async {
        if remindersFirst.value?.fresh != true { restoreRemindersConnection() }
        await remindersRestoreTask?.value
        if let id=remindersTaskCurrentID,!permissionBusy,!exitRequested { performRemindersTask(.task_status,taskID:id) }
    }
    func startAnotherReminder() {
        guard canInspectReminders,NSApp.isActive,remindersTask?.state.terminal==true || remindersTaskMissing else{return}
        remindersTask=nil;remindersTaskCurrentID=nil;remindersTaskMessage=nil;remindersTaskNeedsScope=false;remindersTaskUnconfirmed=false;remindersTaskMissing=false
        UserDefaults.standard.removeObject(forKey:"remindersCurrentTaskV1")
    }
    func cancelRemindersFirst() {
        guard !demo,let id=remindersRequestID ?? remindersFirst.value?.active_request_id.flatMap(UUID.init(uuidString:)) else{return}
        appleReminderTask?.cancel()
        Task {do{let reply=try await service.performRemindersFirst(.cancel,requestID:id);remindersMessage="已请求取消；原生流程结束前仍保持占用。";if let value=reply.snapshot{remindersFirst = .available(value)}}catch{remindersMessage="取消状态未确认，请核查原请求。"}}
    }
    func performPermission(_ capability: String, action: String) {
        guard !exitRequested else { permissionMessage="正在退出，操作尚未开始。";return }
        guard !nativeActionsHeld else{permissionMessage="此未来源码候选尚未开放原生操作。";return}
        guard !PermissionRouteRegistry.isDedicated(capability) else{permissionMessage="请在对应应用的接入设置中操作。";return}
        guard connected, !permissionBusy, !demo, !requiresIsolatedHome, permissions.value != nil,permissions.value?.manual_request?.in_flight != true else { return }
        permissionBusy=true;permissionMessage=nil;permissionGeneration += 1
        let requestID=UUID()
        Task {
            defer { permissionBusy=false }
            guard !exitRequested else { permissionMessage="正在退出，操作尚未开始。";return }
            do {
                let (next,outcome)=try await service.performPermission(capability,action:action,requestID:requestID)
                permissions = .available(next)
                permissionMessage = outcome == "refreshed" ? "已重新检查权限与操作状态" : outcome == "in_progress" ? "原生请求进行中" : outcome == "opened_settings" ? "已发送系统设置打开请求" : "请求未完成：\(outcome)"
            } catch {
                let code=(error as? ARLError)?.code ?? "invalid_response"
                permissionMessage = code == "app_identity_unverified" ? "控制界面身份尚未获运行时核验，不能发起手动操作。" : code == "rpc_deadline_exceeded" ? "请求响应超时；将核查原请求状态，请勿重复提交。" : "请求不可用：\(code)"
                permissions = await service.readPermissions()
            }
        }
    }
    func resetLogs(level: String?) {
        legacyLogGeneration &+= 1
        logTask?.cancel(); if !legacyLogs { logPaging.reset() }; logLevel = level
        logReadError = nil
        requestLogPage()
    }
    func loadMoreLogs() async { requestLogPage(); await logTask?.value }
    func requestLogPage(retry: Bool = false) {
        guard connected && control.runtime.value != nil else { return }
        if legacyLogs {
            logTask = Task { await refreshLegacyLogs() }
            return
        }
        if logPaging.needsSessionConfirmation {
            guard retry, !logSessionReading else { return }
            logTask = Task {
                if await synchronizeLogSession() { requestLogPage(retry: true) }
            }
            return
        }
        guard let request = logPaging.begin(online: true, retry: retry), let sessionID = request.sessionID else { return }
        let filter = logLevel
        logTask = Task {
            do {
                var params: [String: ARLJSON] = ["mode": .string("page"), "session_id": .string(sessionID), "limit": .number(100)]
                if let cursor = request.cursor { params["cursor"] = .string(cursor) }
                if let filter { params["level"] = .string(filter) }
                let decoded: (sessionID: String, latestSequence: Int, scannedThroughSequence: Int, page: RedactedLogPage)
                if demo {
                    let fixture = try await service.readLogs(cursor: request.cursor, level: filter)
                    let head = fixture.entries.last?.sequence ?? 0
                    let page = RedactedLogPage(entries: fixture.entries, hasMore: false, nextCursor: "demo-log-end",
                        truncated: fixture.truncated, sourceDescription: fixture.sourceDescription)
                    decoded = (sessionID, head, head, page)
                } else {
                    let reply = try await ARLClient(home: service.home, app: "settings").rpc("settings.logs.v3", params: params, timeout: 3)
                    decoded = try LogSessionReply.page(JSONEncoder().encode(reply))
                }
                guard !Task.isCancelled else { return }
                if logPaging.complete(decoded.page, sessionID: decoded.sessionID, latestSequence: decoded.latestSequence,
                                      scannedThroughSequence: decoded.scannedThroughSequence, for: request), let loaded = logPaging.page {
                    control.logs = .available(loaded)
                    lastSuccessfulLogPage = loaded; lastLogSuccess = Date(); logReadError = nil
                }
            } catch {
                guard !Task.isCancelled, logPaging.inFlight == request else { return }
                let code = (error as? ARLError)?.code ?? "invalid_response"
                if code == "log_session_changed" { logPaging.disconnect(code: code) }
                else { logPaging.fail(code, for: request) }
                logReadError = code
            }
        }
    }
    private func restoreCachedLogs() {
        if let page = lastSuccessfulLogPage { control.logs = .available(page) }
    }
    private func refreshLegacyLogs() async {
        let generation = legacyLogGeneration
        guard legacyLogReadingGeneration != generation else { return }
        legacyLogReadingGeneration = generation
        defer { if legacyLogReadingGeneration == generation { legacyLogReadingGeneration = nil } }
        let filter = logLevel
        do {
            var rows: [RedactedLogEntry] = []
            var cursor: String?
            var truncated = false
            var more = false
            var seen = Set<String>()
            repeat {
                guard !Task.isCancelled, generation == legacyLogGeneration else { return }
                let part = try await service.readLogs(cursor: cursor, level: filter)
                guard !Task.isCancelled, generation == legacyLogGeneration else { return }
                rows.append(contentsOf: part.entries)
                truncated = truncated || part.truncated
                more = part.hasMore
                guard let next = part.nextCursor, seen.insert(next).inserted else { throw ARLError(code: "invalid_cursor") }
                cursor = next
            } while more && rows.count < 500
            guard !Task.isCancelled, generation == legacyLogGeneration else { return }
            let page = RedactedLogPage(entries: rows, hasMore: more, nextCursor: cursor,
                truncated: truncated || more, sourceDescription: "当前进程 · 最近 15 分钟 · 服务端脱敏")
            lastSuccessfulLogPage = page; lastLogSuccess = Date()
            control.logs = .available(page); logReadError = nil
        } catch {
            guard !Task.isCancelled, generation == legacyLogGeneration else { return }
            logReadError = (error as? ARLError)?.code ?? "invalid_response"
            restoreCachedLogs()
        }
    }
    private func synchronizeLogSession() async -> Bool {
        if legacyLogs { await refreshLegacyLogs(); return false }
        if demo {
            let fixture = try? await service.readLogs()
            logPaging.observeSession(String(repeating: "0", count: 32), latestSequence: fixture?.entries.last?.sequence ?? 0) // Explicit fixture identity; no RPC.
            return true
        }
        guard !logSessionReading else { return false }
        logSessionReading = true
        defer { logSessionReading = false }
        let generation = logPaging.generation
        do {
            let reply = try await ARLClient(home: service.home, app: "settings").rpc("settings.logs.v3", params: ["mode": .string("checkpoint")], timeout: 3)
            let checkpoint = try LogSessionReply.checkpoint(JSONEncoder().encode(reply))
            guard generation == logPaging.generation else { return false }
            if logPaging.observeSession(checkpoint.sessionID, latestSequence: checkpoint.latestSequence) {
                // Confirmed restart: old rows belong to another stream. Keep
                // the existing available-log view while fetching its first page.
                restoreCachedLogs()
            }
            return true
        } catch {
            guard generation == logPaging.generation else { return false }
            let code = (error as? ARLError)?.code ?? "invalid_response"
            if code == "unknown_method" {
                legacyLogs = true
                await refreshLegacyLogs()
                return false
            }
            logPaging.disconnect(code: code)
            logReadError = code
            if logPaging.page == nil { control.logs = .unavailable(code) }
            return false
        }
    }
    var connected: Bool { snapshot != nil && errorCode == nil && controlError == nil }
    var title: String {
        if errorCode == "user_disabled" { return "已停用" }
        if (errorCode != nil || controlError != nil) && snapshot != nil { return "状态待更新" }
        if let snapshot { return snapshot.health.live ? (snapshot.health.ready ? "运行时已就绪" : "正在准备") : "正在停止" }
        return reading ? "正在发现运行时" : "未连接"
    }
    var detail: String {
        if demo { return "演示数据，未连接真实运行时。" }
        if controlError != nil { return "控制状态未核验；显示上次结果，请刷新后再操作。" }
        switch errorCode {
        case "dev_runtime_home_required": return "开发预览需要明确指定隔离运行时，或使用演示数据。"
        case "user_disabled": return "运行时已由用户停用，需要在运行时端明确恢复。"
        case "unsafe_home": return "运行时目录未通过本机安全检查。"
        case "app_identity_unverified": return "当前服务不允许设置读取，需核对 host 只读策略。"
        case "rpc_deadline_exceeded": return "读取运行时状态超时，将在下次刷新时重试。"
        case "invalid_response": return "运行时响应未通过协议校验。"
        case "unsupported_protocol": return "运行时协议版本与此界面不兼容。"
        case .some: return "未发现可读取的本机运行时。服务启动后会自动更新。"
        case .none:
            if control.runtime.value?.task_execution_enabled == false { return "只读元数据服务就绪；任务执行保持关闭。" }
            return snapshot?.health.ready == true ? "后台任务不依赖此窗口保持打开。" : "等待运行时完成恢复与就绪检查。"
        }
    }
    var color: Color { if demo { return .secondary }; if errorCode != nil || controlError != nil { return .orange }; if let s = snapshot, s.health.live && s.health.ready { return .green }; if snapshot != nil { return .orange }; return .secondary }
    var symbol: String { connected && snapshot?.health.ready == true ? "checkmark.circle" : errorCode == "user_disabled" ? "pause.circle" : "circle.dashed" }
    var previewLabel: String? { nativeActionsHeld ? "源码候选 · 原生接入待复核":demo ? "演示预览 · 虚拟数据" : isolated ? "开发预览" : nil }
}
