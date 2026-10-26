import Foundation
import AppKit
import EventKit
import Darwin
import ARLRemindersCore
import ARLRemindersEventKit

struct RemindersFirstPolicy: Decodable, Sendable {
    let schema_version:Int;let enabled:Int;let control_requirement:String;let host_home:String
    let run_id:String;let max_saves:Int;let scope_seconds:Int;let smoke_delay_seconds:Int;let source_policy:String
    static func sealed(_ path:String)throws->(Self,String) {
        guard Bundle.main.object(forInfoDictionaryKey:"ARLFirstRemindersPolicyPath") as? String == path,
            let expected=Bundle.main.object(forInfoDictionaryKey:"ARLFirstRemindersPolicySHA256") as? String else{throw RemindersTransportFault("activation_not_sealed")}
        let bytes=try RemindersNativeIO.privateFile(path);guard RemindersNativeIO.hash(bytes)==expected else{throw RemindersTransportFault("activation_hash_changed")}
        let raw=try RemindersNativeIO.flatObject(bytes)
        guard Set(raw.keys)==["schema_version","enabled","control_requirement","host_home","run_id","max_saves","scope_seconds","smoke_delay_seconds","source_policy"],RemindersNativeIO.integer(raw["schema_version"])==1,RemindersNativeIO.integer(raw["enabled"])==1,RemindersNativeIO.integer(raw["max_saves"])==2,RemindersNativeIO.integer(raw["scope_seconds"])==300 else{throw RemindersTransportFault("activation_disabled_or_invalid")}
        let policy=try JSONDecoder().decode(Self.self,from:bytes)
        guard UUID(uuidString:policy.run_id)?.uuidString.lowercased()==policy.run_id,policy.host_home.hasPrefix("/"),policy.source_policy=="default_list_source_explicit_owner_confirmation",policy.control_requirement==RemindersStablePeerIdentity.controlRequirement else{throw RemindersTransportFault("activation_disabled_or_invalid")}
        #if REMINDERS_FIRST_SLICE_FIXTURE
        guard (0...30).contains(policy.smoke_delay_seconds) else{throw RemindersTransportFault("activation_disabled_or_invalid")}
        #else
        guard policy.smoke_delay_seconds==30 else{throw RemindersTransportFault("activation_disabled_or_invalid")}
        #endif
        try RemindersNativeIO.privateDirectory(policy.host_home)
        return (policy,expected)
    }
}
struct RemindersSourceBinding: Codable, Sendable {
    let source:RemindersSelectedSource;let identity:RemindersFirstIdentity;let policy_sha256:String;let expires_at_ms:Int64
}
struct RemindersFrozenSourceMetadata:Codable {
    let source:RemindersSelectedSource;let identity:RemindersFirstIdentity;let policy_sha256:String
}
struct RemindersNativeAdmissionRecord: Codable {
    let request_id:String;let action:String;let frame_sha256:String;var state:String;var outcome:String;var code:String
}
struct RemindersSmokeRecord: Codable, Sendable {
    let run_id:String;let policy_sha256:String;let source_sha256:String;var state:String;var list_id:String?;var reminder_id:String?
}
final class RemindersCancellation: @unchecked Sendable {
    private let lock=NSLock();private var stopped=false
    func cancel(){lock.lock();stopped=true;lock.unlock()}
    var requested:Bool{lock.lock();defer{lock.unlock()};return stopped}
}
protocol RemindersSourceAccess: AnyObject {
    func defaultSource()throws->RemindersSelectedSource
    func verify(_ source:RemindersSelectedSource)throws
    func productCatalog()throws->RemindersProductCatalog
}
extension RemindersSourceAccess {
    func productCatalog()throws->RemindersProductCatalog {
        let source=try defaultSource()
        return .init(sources:[.init(id:source.id,title:source.title,type:source.type)],
            lists:[.init(id:source.default_list_id,title:source.default_list_title,source_id:source.id,writable:true)])
    }
    func verifyTaskTarget(_ source:RemindersSelectedSource)throws {
        try verify(source)
        guard try defaultSource()==source else{throw RemindersTransportFault("target_changed")}
    }
}
final class RemindersEventKitSourceAccess: RemindersSourceAccess {
    func productCatalog()throws->RemindersProductCatalog {
        guard EventKitRepository.authorizationStatus()=="full_access" else{throw AdapterFault("needs_permission")}
        let store=EKEventStore()
        let lists=store.calendars(for:.reminder).filter{[0,1,2,3].contains($0.source.sourceType.rawValue)}
        let sources=store.sources.filter{[0,1,2,3].contains($0.sourceType.rawValue)}
        let result=RemindersProductCatalog(
            sources:sources.map{.init(id:$0.sourceIdentifier,title:$0.title,type:$0.sourceType.rawValue)},
            lists:lists.map{.init(id:$0.calendarIdentifier,title:$0.title,source_id:$0.source.sourceIdentifier,writable:$0.allowsContentModifications)})
        try result.validate();return result
    }
    func defaultSource()throws->RemindersSelectedSource {
        guard EventKitRepository.authorizationStatus()=="full_access" else{throw AdapterFault("needs_permission")}
        let store=EKEventStore();guard let list=store.defaultCalendarForNewReminders(),list.allowedEntityTypes.contains(.reminder),list.allowsContentModifications else{throw AdapterFault("list_not_found")}
        return .init(id:list.source.sourceIdentifier,title:list.source.title,type:list.source.sourceType.rawValue,default_list_id:list.calendarIdentifier,default_list_title:list.title)
    }
    func verify(_ source:RemindersSelectedSource)throws {
        guard EventKitRepository.authorizationStatus()=="full_access" else{throw AdapterFault("needs_permission")}
        let store=EKEventStore();guard let actual=store.source(withIdentifier:source.id),actual.title==source.title,actual.sourceType.rawValue==source.type else{throw AdapterFault("target_changed")}
    }
}
// Legacy acceptance stays sealed to its original run. New tasks carry only a
// title/ID; their target and one-attempt scope come from separate native review.
@MainActor final class RemindersFirstHost {
    let policy:RemindersFirstPolicy;let policyHash:String;let identity:NativePermissionIdentity
    private let sourceAccess:any RemindersSourceAccess
    private let repository:any ReminderRepository
    private let status: @Sendable ()->String
    private var active:(id:String,action:RemindersFirstAction,cancel:RemindersCancellation)?
    private var stopping=false
    private var sourceReadThisProcess=false
    private var sourceMetadata:RemindersSelectedSource?
    private var selectionWindow:NSWindow?
    private let encoder:JSONEncoder
    private var taskSessionID=UUID().uuidString.lowercased()
    init(policy:RemindersFirstPolicy,policyHash:String,identity:NativePermissionIdentity)throws {
        self.policy=policy;self.policyHash=policyHash;self.identity=identity;encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        #if REMINDERS_FIRST_SLICE_FIXTURE
        let fixture=try RemindersFirstFixtureBackend(home:policy.host_home)
        sourceAccess=fixture;repository=fixture.repository;status={fixture.authorization()}
        #else
        sourceAccess=RemindersEventKitSourceAccess();repository=EventKitRepository();status={EventKitRepository.authorizationStatus()}
        #endif
        let dir=policy.host_home+"/admissions"
        if access(dir,F_OK) != 0 {guard mkdir(dir,0o700)==0 else{throw RemindersTransportFault("unsafe_home")}}
        try RemindersNativeIO.privateDirectory(dir)
    }
    private var upgrade:RemindersUpgradeStore{.init(home:policy.host_home,identity:wireIdentity,policy:policyHash,runID:policy.run_id)}
    private func reviewedUpgrade()throws->RemindersUpgradeReceipt? {
        let value=try upgrade.receipt()
        guard !(try upgrade.needsReview()) else{throw RemindersTransportFault("upgrade_review_required")}
        return value
    }
    private func activeSourcePath()throws->String{try reviewedUpgrade() == nil ? policy.host_home+"/source.json" : upgrade.sourcePath}
    private func activeSmokePath()throws->String{try reviewedUpgrade() == nil ? policy.host_home+"/smoke.json" : upgrade.smokePath}
    private var taskStore:RemindersTaskStore{.init(home:policy.host_home,identity:wireIdentity,policy:policyHash,legacyRunID:policy.run_id,sessionID:taskSessionID)}
    private var disabledPath:String{policy.host_home+"/disabled"}
    private var wireIdentity:RemindersFirstIdentity{.init(helper_bundle_id:identity.helper_bundle_id,executable_sha256:identity.executable_sha256,designated_requirement_sha256:identity.designated_requirement_sha256)}
    private func ownCurrent()throws {guard try NativePermissionIdentity.current(expectedBundle:"local.arl.remindersbridge")==identity else{throw RemindersTransportFault("identity_changed")}}
    private func sourceBinding()throws->(RemindersSourceBinding,Data) {
        let raw=try RemindersNativeIO.privateFile(try activeSourcePath());let value=try JSONDecoder().decode(RemindersSourceBinding.self,from:raw)
        try RemindersUpgradeReview.validateBinding(value,identity:wireIdentity,policy:policyHash,nowMS:Int64(Date().timeIntervalSince1970*1000));return(value,raw)
    }
    private func smokeRecord()throws->RemindersSmokeRecord? {
        let smokePath=try activeSmokePath();guard access(smokePath,F_OK)==0 else{return nil};let r=try JSONDecoder().decode(RemindersSmokeRecord.self,from:RemindersNativeIO.privateFile(smokePath));guard r.run_id==policy.run_id,r.policy_sha256==policyHash else{throw RemindersTransportFault("needs_review")};return r
    }
    func snapshot()throws->RemindersFirstSnapshot {
        try ownCurrent();var source="unselected"
        var smoke="not_started"
        do {
            if try upgrade.needsReview(){source="upgrade_review";smoke="upgrade_review"}
            else if let review=try upgrade.receipt(),review.disposition != .sourceOnly {
                source="reviewed";smoke=review.disposition == .completed ? "historical_completed":"unknown_preserved"
            } else {
                let sourcePath=try activeSourcePath()
                if access(sourcePath,F_OK)==0{do{_=try sourceBinding();source="selected"}catch let e as RemindersTransportFault{source=e.code=="source_expired" ? "expired":"changed"}catch{source="needs_review"}}
                if let record=try smokeRecord(){smoke=record.state=="saved_local" ? "saved_local" : active?.action == .run_smoke ? "running":"needs_review"}
            }
        } catch {source="upgrade_blocked";smoke="needs_review"}
        let state=RemindersV3PermissionIntegration.classifyOwnerAuthorization(status()).state
        return .init(schema_version:1,identity:wireIdentity,observed_at_ms:Int64(Date().timeIntervalSince1970*1000),enabled:access(disabledPath,F_OK) != 0,permission_state:state,source_state:source,smoke_state:smoke,run_id:policy.run_id,max_saves:2,active_request_id:active?.id,active_action:active?.action.rawValue,prompts_requested:false,data_read:false)
    }
    private func reply(_ frame:RemindersFirstFrame,_ outcome:String,_ code:String="ok",page:RemindersTaskPage?=nil)->Data {
        let task=RemindersTaskContract.actions.contains(frame.action) ? frame.task_id.flatMap{try? taskStore.read($0)}:nil
        return (try? encoder.encode(RemindersFirstReply(schema_version:1,request_id:frame.request_id,action:frame.action,outcome:outcome,code:code,snapshot:try? snapshot(),task:task,task_page:page))) ?? Data()
    }
    private func canonical(_ frame:RemindersFirstFrame)throws->Data{try encoder.encode(frame)}
    func handle(_ bytes:Data,peer:RemindersNativeIO.Peer) async->Data {
        if let raw=try? RemindersNativeIO.flatObject(bytes,limit:RemindersProductFrame.requestLimit),RemindersNativeIO.integer(raw["schema_version"])==3 {
            return await handleProduct(bytes,peer:peer)
        }
        guard let frame=try? RemindersFirstFrame.decode(bytes) else{return Data("{\"schema_version\":1,\"outcome\":\"unavailable\",\"code\":\"invalid_arguments\"}".utf8)}
        do {
            guard peer.current(),!RemindersNativeIO.disconnected(peer.fd) else{throw RemindersTransportFault("identity_unverified")}
            // Shutdown confers no data/effect authority. An authenticated owner
            // may drain a stale idle image while every business action still
            // requires ownCurrent. In-flight work is never killed or cancelled.
            if frame.action == .shutdown {
                guard active == nil else { return reply(frame,"unavailable","request_busy") }
                stopping=true
                let response=reply(frame,"completed","shutdown_requested")
                DispatchQueue.main.asyncAfter(deadline:.now()+0.1) {
                    #if REMINDERS_FIRST_SLICE_FIXTURE
                    exit(0)
                    #else
                    NSApp.terminate(nil)
                    #endif
                }
                return response
            }
            guard !stopping else { return reply(frame,"unavailable","host_stopping") }
            try ownCurrent()
            if [.snapshot,.retest].contains(frame.action){return reply(frame,"refreshed")}
            if frame.action == .task_status{_=try taskStore.read(frame.task_id!);return reply(frame,"refreshed")}
            if frame.action == .task_list{return reply(frame,"refreshed",page:try taskStore.page(offset:frame.offset!))}
            if frame.action == .cancel {
                guard active?.id==frame.request_id else{return reply(frame,"unavailable","request_not_active")};active?.cancel.cancel()
                if let window=selectionWindow,let sheet=window.attachedSheet{window.endSheet(sheet,returnCode:.alertSecondButtonReturn)}
                return reply(frame,"user_cancelled","cancel_requested")
            }
            let taskAction=RemindersTaskContract.actions.contains(frame.action)
            let admissionDirectory=taskAction ? try taskStore.admissionDirectory():policy.host_home+"/admissions"
            let hash=RemindersNativeIO.hash(try canonical(frame));let path=admissionDirectory+"/"+frame.request_id+".json"
            if access(path,F_OK)==0{
                let old=try JSONDecoder().decode(RemindersNativeAdmissionRecord.self,from:RemindersNativeIO.privateFile(path))
                guard old.frame_sha256==hash,old.action==frame.action.rawValue else{throw RemindersTransportFault("idempotency_conflict")}
                return reply(frame,old.state=="completed" ? old.outcome:"needs_review",old.state=="completed" ? old.code:"request_outcome_unknown")
            }
            guard active==nil else{return reply(frame,"unavailable","request_busy")}
            let names=try FileManager.default.contentsOfDirectory(atPath:admissionDirectory);guard names.count<(taskAction ? 4096:512) else{throw RemindersTransportFault("admission_capacity")}
            var record=RemindersNativeAdmissionRecord(request_id:frame.request_id,action:frame.action.rawValue,frame_sha256:hash,state:"pending",outcome:"needs_review",code:"request_outcome_unknown")
            try RemindersNativeIO.writeNew(try encoder.encode(record),to:path)
            let cancellation=RemindersCancellation();active=(frame.request_id,frame.action,cancellation);defer{active=nil}
            let deadline=ProcessInfo.processInfo.systemUptime+180
            let stopped: @Sendable ()->Bool={cancellation.requested || ProcessInfo.processInfo.systemUptime>=deadline || !peer.current() || RemindersNativeIO.disconnected(peer.fd)}
            var outcome="completed";var code="ok"
            do {
                switch frame.action {
                case .request:
                    #if REMINDERS_FIRST_SLICE_FIXTURE
                    guard !stopped(),let fixture=sourceAccess as? RemindersFirstFixtureBackend else{throw RemindersTransportFault("cancelled")};fixture.authorize()
                    #else
                    let native=RemindersFirstFrame(action:.request,requestID:UUID(uuidString:frame.request_id)!,capability:RemindersFirstFrame.operationIDs.contains(frame.capability_id) ? frame.capability_id:"apple.reminders.create.v3")
                    let bytes=await RemindersV3PermissionIntegration.handlePermissionRequest(frame:try encoder.encode(native),kernelPeerAuditToken:peer.token,pinnedControlRequirement:policy.control_requirement,approvedHelperIdentity:identity,cancelled:stopped)
                    guard let result=RemindersV3PermissionIntegration.requestOutcome(bytes) else{throw RemindersTransportFault("invalid_response")}
                    outcome=result.outcome;code=result.code
                    #endif
                case .review_upgrade:
                    let review=try await upgrade.review(confirm:{await self.confirmUpgrade($0)},stopped:stopped)
                    outcome=review.disposition == .completed ? "historical_completed" : review.disposition == .unknown ? "unknown_preserved":"source_reviewed"
                case .select_source:
                    let reviewed=try reviewedUpgrade()
                    guard reviewed?.disposition != .completed else{throw RemindersTransportFault("save_budget_consumed")}
                    guard reviewed?.disposition != .unknown else{throw RemindersTransportFault("saved_outcome_unknown")}
                    guard status()=="full_access",(try smokeRecord())==nil else{throw RemindersTransportFault(status()=="full_access" ? "smoke_already_admitted":"needs_permission")}
                    guard !stopped() else{throw RemindersTransportFault("cancelled")}
                    if let source=reviewed?.source{sourceMetadata=source;sourceReadThisProcess=true}
                    if !sourceReadThisProcess{
                        let metadataPath=policy.host_home+"/source-metadata.json";let admittedPath=policy.host_home+"/source-metadata-admitted"
                        if access(metadataPath,F_OK)==0 {
                            let frozen=try JSONDecoder().decode(RemindersFrozenSourceMetadata.self,from:RemindersNativeIO.privateFile(metadataPath));guard RemindersUpgradeReview.storedSubjectMatches(frozen.identity,current:wireIdentity),frozen.policy_sha256==policyHash else{throw RemindersTransportFault("target_changed")};sourceMetadata=frozen.source
                        } else {
                            guard access(admittedPath,F_OK) != 0 else{throw RemindersTransportFault("needs_review")}
                            try RemindersNativeIO.writeNew(Data("one_default_metadata_read_no_automatic_replay\n".utf8),to:admittedPath)
                            let selected=try sourceAccess.defaultSource();let frozen=RemindersFrozenSourceMetadata(source:selected,identity:wireIdentity,policy_sha256:policyHash)
                            try RemindersNativeIO.writeNew(try encoder.encode(frozen),to:metadataPath);sourceMetadata=selected
                        }
                        sourceReadThisProcess=true
                    }
                    guard let metadata=sourceMetadata else{throw RemindersTransportFault("source_unavailable")}
                    guard [0,1,2,3].contains(metadata.type) else{throw RemindersTransportFault("unsupported_source")}
                    guard await confirmSource(metadata),!stopped() else{throw RemindersTransportFault("cancelled")}
                    try sourceAccess.verify(metadata);guard !stopped() else{throw RemindersTransportFault("cancelled")}
                    let binding=RemindersSourceBinding(source:metadata,identity:wireIdentity,policy_sha256:policyHash,expires_at_ms:Int64(Date().timeIntervalSince1970*1000)+600000)
                    try RemindersNativeIO.atomicWrite(try encoder.encode(binding),to:try activeSourcePath());if access(disabledPath,F_OK)==0{guard unlink(disabledPath)==0 else{throw RemindersTransportFault("unsafe_home")}}
                    outcome="source_selected"
                case .run_smoke:
                    let reviewed=try reviewedUpgrade()
                    if reviewed?.disposition == .completed{outcome="historical_completed";break}
                    guard reviewed?.disposition != .unknown else{throw RemindersTransportFault("saved_outcome_unknown")}
                    let smokePath=try activeSmokePath()
                    guard access(disabledPath,F_OK) != 0 else{throw RemindersTransportFault("user_disabled")}
                    if let old=try smokeRecord(){guard old.state=="saved_local" else{throw RemindersTransportFault("needs_review")};outcome="saved_local";break}
                    guard status()=="full_access" else{throw RemindersTransportFault("needs_permission")}
                    let (binding,bindingBytes)=try sourceBinding();try sourceAccess.verify(binding.source)
                    var smoke=RemindersSmokeRecord(run_id:policy.run_id,policy_sha256:policyHash,source_sha256:RemindersNativeIO.hash(bindingBytes),state:"pending",list_id:nil,reminder_id:nil)
                    try RemindersNativeIO.writeNew(try encoder.encode(smoke),to:smokePath)
                    let runner=try RemindersTwoSaveRunner(policy:policy,policyHash:policyHash,identity:identity,binding:binding,bindingBytes:bindingBytes,bindingPath:try activeSourcePath(),repository:repository,sourceAccess:sourceAccess,status:status,cancel:stopped)
                    let result=try await Task.detached{try runner.run()}.value
                    guard !stopped() else{throw RemindersTransportFault("needs_review")}
                    smoke.state="saved_local";smoke.list_id=result.0;smoke.reminder_id=result.1;try RemindersNativeIO.atomicWrite(try encoder.encode(smoke),to:smokePath);outcome="saved_local"
                case .disconnect:
                    taskSessionID=UUID().uuidString.lowercased() // Revoke every unconsumed new-task scope, without touching records.
                    // A stale or invalid upgrade never deletes the legacy binding.
                    let hasUpgrade=(try? upgrade.optional("upgrade-review-v1.json")) != nil
                    let preserveLegacy=hasUpgrade || ((try? upgrade.needsReview()) ?? true)
                    let sourcePath=preserveLegacy ? upgrade.sourcePath : policy.host_home+"/source.json"
                    if access(sourcePath,F_OK)==0{guard unlink(sourcePath)==0 else{throw RemindersTransportFault("unsafe_home")}}
                    if access(disabledPath,F_OK) != 0{try RemindersNativeIO.writeNew(Data("disabled_no_tcc_revocation\n".utf8),to:disabledPath)};outcome="disconnected"
                case .task_prepare:
                    _=try taskStore.prepare(id:frame.task_id!,title:frame.title!);code="task_ready"
                case .task_scope:
                    let candidate=try taskStore.mutable(frame.task_id!,expected:frame.expected_digest!)
                    guard status()=="full_access",!stopped() else{throw RemindersTransportFault(stopped() ? "cancelled":"needs_permission")}
                    let target=try sourceAccess.defaultSource();try RemindersTaskContract.target(target)
                    guard await confirmTaskScope(candidate,target:target,cancelled:stopped),!stopped() else{throw RemindersTransportFault("cancelled")}
                    try ownCurrent();try sourceAccess.verifyTaskTarget(target)
                    guard !stopped() else{throw RemindersTransportFault("cancelled")}
                    _=try taskStore.grant(id:candidate.task_id,expected:frame.expected_digest!,source:target,nowMS:Int64(Date().timeIntervalSince1970*1000),uptime:ProcessInfo.processInfo.systemUptime)
                    code="task_scope_selected"
                case .task_submit:
                    let runner=RemindersTaskRunner(store:taskStore,id:frame.task_id!,expected:frame.expected_digest!,identity:identity,repository:repository,sourceAccess:sourceAccess,status:status,cancel:stopped)
                    let result=try await Task.detached{try runner.run()}.value
                    outcome=result.state == .saved ? "saved_local":result.state == .cancelled ? "user_cancelled":"needs_review"
                    code=result.state == .saved ? "task_saved":"task_outcome_unknown"
                case .task_cancel:
                    _=try taskStore.cancel(id:frame.task_id!,expected:frame.expected_digest!);outcome="user_cancelled";code="task_cancelled"
                case .snapshot,.retest,.cancel,.shutdown,.task_status,.task_list:throw RemindersTransportFault("invalid_arguments")
                }
                if stopped() && frame.action != .task_submit{throw RemindersTransportFault("cancelled")}
            } catch {
                code=(error as? RemindersTransportFault)?.code ?? (error as? AdapterFault)?.code ?? "outcome_unknown"
                outcome=code=="cancelled" ? "user_cancelled" : ["needs_review","outcome_unknown"].contains(code) ? "needs_review":"unavailable"
            }
            record.state="completed";record.outcome=outcome;record.code=code;try RemindersNativeIO.atomicWrite(try encoder.encode(record),to:path)
            active=nil
            return reply(frame,outcome,code)
        } catch{return reply(frame,"unavailable",(error as? RemindersTransportFault)?.code ?? "outcome_unknown")}
    }
    private func handleProduct(_ bytes:Data,peer:RemindersNativeIO.Peer)async->Data {
        guard let frame=try? RemindersProductFrame.decode(bytes) else {
            return Data("{\"schema_version\":3,\"code\":\"invalid_product_frame\"}".utf8)
        }
        let sourceAccess=self.sourceAccess
        let handler=RemindersProductHandler(home:policy.host_home,identity:wireIdentity,policy:policyHash,
            repository:repository,catalog:{try sourceAccess.productCatalog()},permission:status)
        func failure(_ code:String)->Data {
            let reply=RemindersProductReply(schema_version:3,capability_id:"reminders.product.v1",request_id:frame.request_id,
                action:frame.action,identity:wireIdentity,policy_sha256:policyHash,outcome:"unavailable",code:code)
            return (try? encoder.encode(reply)) ?? Data()
        }
        do {
            guard peer.current(),!RemindersNativeIO.disconnected(peer.fd),!stopping else{throw RemindersTransportFault("identity_unverified")}
            try ownCurrent()
            if frame.action == .status || frame.action == .history || frame.action == .selection {
                return try encoder.encode(handler.handle(frame,check:{}))
            }
            guard active==nil else{throw RemindersTransportFault("request_busy")}
            let connectionAction=frame.action == .catalog || frame.action == .select
            guard connectionAction || access(disabledPath,F_OK) != 0 else{throw RemindersTransportFault("user_disabled")}
            let cancellation=RemindersCancellation();active=(frame.request_id,.task_submit,cancellation)
            defer{active=nil}
            let deadline=ProcessInfo.processInfo.systemUptime+120
            let expected=identity,disabled=disabledPath
            let runner=RemindersProductWorker(handler:handler,frame:frame,check:{
                guard !cancellation.requested,ProcessInfo.processInfo.systemUptime<deadline,peer.current(),
                    !RemindersNativeIO.disconnected(peer.fd),(connectionAction || access(disabled,F_OK) != 0),
                    try NativePermissionIdentity.current(expectedBundle:"local.arl.remindersbridge")==expected else {
                    throw AdapterFault("cancelled")
                }
            })
            let reply=await Task.detached{runner.run()}.value
            if frame.action == .select,reply.code=="target_selected",access(disabledPath,F_OK)==0 {
                try ownCurrent()
                guard peer.current(),!cancellation.requested,unlink(disabledPath)==0 else{throw RemindersTransportFault("connection_resume_failed")}
            }
            return try encoder.encode(reply)
        } catch {return failure((error as? RemindersTransportFault)?.code ?? (error as? AdapterFault)?.code ?? "outcome_unknown")}
    }
    private func confirmTaskScope(_ task:RemindersTaskRecord,target:RemindersSelectedSource,cancelled:@escaping @Sendable ()->Bool) async->Bool {
        #if REMINDERS_FIRST_SLICE_FIXTURE
        return true // Explicit isolated synthetic action; fixture never uses EventKit.
        #else
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:520,height:220),styleMask:[.titled],backing:.buffered,defer:false)
        window.title="ARL 提醒范围";window.center();window.makeKeyAndOrderFront(nil);selectionWindow=window
        defer{window.orderOut(nil);selectionWindow=nil};NSApp.activate(ignoringOtherApps:true)
        let alert=NSAlert();alert.messageText="仅允许本次提醒"
        alert.informativeText="内容：\(task.title)\n来源：\(RemindersTaskContract.display(target.title))\n列表：\(RemindersTaskContract.display(target.default_list_title))\n\n确认后五分钟内只可创建这条提醒一次，可能按已有设置同步。本次只确认范围，尚不保存；旧未知操作和测试预算保持原样。"
        alert.addButton(withTitle:"确认范围");alert.addButton(withTitle:"取消")
        let timer=Timer(timeInterval:0.1,repeats:true) { _ in
            MainActor.assumeIsolated {
                if cancelled(),let sheet=window.attachedSheet { window.endSheet(sheet,returnCode:.alertSecondButtonReturn) }
            }
        }
        RunLoop.main.add(timer,forMode:.common)
        defer { timer.invalidate() }
        return await withCheckedContinuation{continuation in alert.beginSheetModal(for:window){response in continuation.resume(returning:response == .alertFirstButtonReturn)}}
        #endif
    }
    private func confirmUpgrade(_ assessment:RemindersUpgradeAssessment) async->Bool {
        #if REMINDERS_FIRST_SLICE_FIXTURE
        return true // Tests call the same review store with explicit confirmation/cancellation.
        #else
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:520,height:180),styleMask:[.titled],backing:.buffered,defer:false)
        window.title="ARL 提醒事项升级复核";window.center();window.makeKeyAndOrderFront(nil);selectionWindow=window
        defer{window.orderOut(nil);selectionWindow=nil};NSApp.activate(ignoringOtherApps:true)
        let alert=NSAlert();alert.messageText="复核升级前的提醒事项记录"
        switch assessment.disposition {
        case .sourceOnly:
            guard let source=assessment.source else{return false}
            alert.informativeText="旧来源：\(source.title)\n旧默认列表：\(source.default_list_title)\n\n确认这是你自己的来源后，只保留本机旧记录的复核结果。之后仍须单独选择并核验此来源，再确认测试保存；本次复核不会读取 EventKit、保存提醒或修改权限。"
            alert.addButton(withTitle:"确认来源并复核")
        case .completed:
            alert.informativeText="旧记录报告两次本机保存已完成。复核将保留该历史结果和已用保存预算，不再运行测试保存；不会读取或核验当前提醒内容及云同步。"
            alert.addButton(withTitle:"保留已完成记录")
        case .unknown:
            alert.informativeText="旧记录无法确认保存结果。复核将保留原证据与未知状态，停止新的测试保存，避免重复创建。不会读取提醒内容、重置预算或修改权限；之后仍可重新检查或断开执行范围。"
            alert.addButton(withTitle:"保留未知结果")
        }
        alert.addButton(withTitle:"取消")
        return await withCheckedContinuation{continuation in alert.beginSheetModal(for:window){response in continuation.resume(returning:response == .alertFirstButtonReturn)}}
        #endif
    }
    private func confirmSource(_ source:RemindersSelectedSource) async->Bool {
        #if REMINDERS_FIRST_SLICE_FIXTURE
        return true // Synthetic metadata and explicit isolated test action only.
        #else
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:520,height:180),styleMask:[.titled],backing:.buffered,defer:false);window.title="ARL 提醒事项来源确认";window.center();window.makeKeyAndOrderFront(nil);selectionWindow=window;defer{window.orderOut(nil);selectionWindow=nil}
        NSApp.activate(ignoringOtherApps:true)
        let alert=NSAlert();alert.messageText="确认这是你自己的来源";alert.informativeText="来源：\(source.title)\n当前默认列表：\(source.default_list_title)\n来源类型：\(source.type)\n\n只有你确认后，才绑定此来源。测试将在这里创建一个专用列表和一个提醒，共两次保存。现有提醒内容不会读取；所选来源可能按已有设置同步。";alert.addButton(withTitle:"确认归我所有并选择");alert.addButton(withTitle:"取消")
        return await withCheckedContinuation{continuation in alert.beginSheetModal(for:window){response in continuation.resume(returning:response == .alertFirstButtonReturn)}}
        #endif
    }
}
// Entire ownership is transferred to the existing serial helper worker.
final class RemindersTaskRunner: @unchecked Sendable {
    let store:RemindersTaskStore;let id:String;let expected:String;let identity:NativePermissionIdentity
    let repository:any ReminderRepository;let sourceAccess:any RemindersSourceAccess
    let status:@Sendable()->String;let cancel:@Sendable()->Bool
    init(store:RemindersTaskStore,id:String,expected:String,identity:NativePermissionIdentity,repository:any ReminderRepository,sourceAccess:any RemindersSourceAccess,status:@escaping @Sendable()->String,cancel:@escaping @Sendable()->Bool){
        self.store=store;self.id=id;self.expected=expected;self.identity=identity;self.repository=repository;self.sourceAccess=sourceAccess;self.status=status;self.cancel=cancel
    }
    func run()throws->RemindersTaskRecord {
        func check(_ task:RemindersTaskRecord)throws {
            guard !cancel(),let scope=task.scope,scope.host_session_id==store.sessionID,scope.expires_uptime>ProcessInfo.processInfo.systemUptime,
                  scope.expires_at_ms>Int64(Date().timeIntervalSince1970*1000),scope.identity==store.identity,
                  try NativePermissionIdentity.current(expectedBundle:"local.arl.remindersbridge")==identity else{throw RemindersTransportFault("task_scope_required")}
            guard status()=="full_access" else{throw RemindersTransportFault("needs_permission")}
            try sourceAccess.verifyTaskTarget(scope.source)
        }
        return try store.submit(id:id,expected:expected,nowMS:Int64(Date().timeIntervalSince1970*1000),uptime:ProcessInfo.processInfo.systemUptime,validate:check,effect:{task in
            try Self.create(task,home:store.home,repository:repository,check:{try check(task)})
        })
    }
    // Shared production effect consumer; tests supply the synthetic repository,
    // while run() supplies the live identity/permission/target/expiry check above.
    static func create(_ task:RemindersTaskRecord,home:String,repository:any ReminderRepository,check:@escaping()throws->Void)throws->String {
        guard let scope=task.scope else{throw RemindersTransportFault("task_scope_required")}
        let facade=try RemindersV3PermissionIntegration(privateJournalDirectory:URL(fileURLWithPath:home+"/tasks-v1/operation-journal"),repository:repository)
        let bytes=try JSONSerialization.data(withJSONObject:["tool":"apple.reminders.create.v3","args":["operation_id":task.operation_id,"list_id":scope.source.default_list_id,"title":task.title]])
        let request=try Request.decode(bytes)
        let authority=HostAuthority(owner:"reminders-task:"+task.task_id,requestDigest:try ARLRemindersCore.digest(request),key:task.operation_id,
            expires:Date(timeIntervalSince1970:Double(scope.expires_at_ms)/1000),allowedTools:[request.tool],listIDs:[scope.source.default_list_id],sourceIDs:[scope.source.id],checkCancelled:check)
        let response=try JSONDecoder().decode(Response.self,from:facade.callReviewedOperation(requestJSON:bytes,authority:authority))
        guard response.operation_id==task.operation_id,response.persistence=="saved_local",let item=response.reminder,
              item.list_id==scope.source.default_list_id,item.title==task.title else{throw RemindersTransportFault("task_outcome_unknown")}
        return item.id
    }

}
// One serialized run; owner classes are never used concurrently. The only
// unchecked transfer moves the entire scoped runner to its background worker.
final class RemindersTwoSaveRunner: @unchecked Sendable {
    let policy:RemindersFirstPolicy;let policyHash:String;let identity:NativePermissionIdentity;let binding:RemindersSourceBinding;let bindingHash:String;let bindingPath:String
    let facade:RemindersV3PermissionIntegration;let sourceAccess:any RemindersSourceAccess;let status:@Sendable()->String;let cancel:@Sendable()->Bool
    init(policy:RemindersFirstPolicy,policyHash:String,identity:NativePermissionIdentity,binding:RemindersSourceBinding,bindingBytes:Data,bindingPath:String,repository:any ReminderRepository,sourceAccess:any RemindersSourceAccess,status:@escaping @Sendable()->String,cancel:@escaping @Sendable()->Bool)throws {
        self.policy=policy;self.policyHash=policyHash;self.identity=identity;self.binding=binding;bindingHash=RemindersNativeIO.hash(bindingBytes);self.bindingPath=bindingPath;self.sourceAccess=sourceAccess;self.status=status;self.cancel=cancel
        facade=try RemindersV3PermissionIntegration(privateJournalDirectory:URL(fileURLWithPath:policy.host_home+"/operation-journal"),repository:repository)
    }
    func run()throws->(String,String) {
        let expiry=Date().addingTimeInterval(Double(policy.scope_seconds));var allowedLists=Set<String>()
        func check()throws {guard !cancel(),expiry>Date(),binding.expires_at_ms>Int64(Date().timeIntervalSince1970*1000) else{throw AdapterFault("cancelled")};guard status()=="full_access" else{throw AdapterFault("needs_permission")};guard RemindersNativeIO.hash(try RemindersNativeIO.privateFile(bindingPath))==bindingHash,try NativePermissionIdentity.current(expectedBundle:"local.arl.remindersbridge")==identity else{throw AdapterFault("review_not_authorized")}}
        let delayUntil=ProcessInfo.processInfo.systemUptime+Double(policy.smoke_delay_seconds)
        while ProcessInfo.processInfo.systemUptime<delayUntil{try check();Thread.sleep(forTimeInterval:0.05)}
        try check();try sourceAccess.verify(binding.source)
        func operationID(_ step:String)throws->String {let h=Array(try ARLRemindersCore.digest(["run":policy.run_id,"step":step]).prefix(32));return String(h[0..<8])+"-"+String(h[8..<12])+"-"+String(h[12..<16])+"-"+String(h[16..<20])+"-"+String(h[20..<32])}
        func call(_ operation:String,_ args:[String:Any])throws->Response {
            guard ["list.create","list.lookup","create","get","query"].contains(operation) else{throw AdapterFault("unknown_tool")}
            let bytes=try JSONSerialization.data(withJSONObject:["tool":"apple.reminders.\(operation).v3","args":args]);let request=try Request.decode(bytes)
            let authority=HostAuthority(owner:"reminders-first:"+policy.run_id+":"+policyHash.prefix(16),requestDigest:try ARLRemindersCore.digest(request),key:request.args.operation_id ?? "first-slice-read",expires:expiry,allowedTools:[request.tool],listIDs:allowedLists,sourceIDs:[binding.source.id],checkCancelled:check)
            return try JSONDecoder().decode(Response.self,from:facade.callReviewedOperation(requestJSON:bytes,authority:authority))
        }
        let listArgs:[String:Any]=["operation_id":try operationID("list"),"source_id":binding.source.id,"title":"ARL adapter smoke "+policy.run_id]
        guard let list=try call("list.create",listArgs).list,list.source_id==binding.source.id else{throw AdapterFault("acceptance_readback_failed")};allowedLists.insert(list.id)
        guard try call("list.lookup",["selector":["id":list.id]]).list==list,try call("list.lookup",["selector":["title":list.title,"source_id":binding.source.id]]).list==list else{throw AdapterFault("acceptance_readback_failed")}
        let create:[String:Any]=["operation_id":try operationID("create"),"list_id":list.id,"title":"ARL synthetic smoke","patch":["due":["action":"set","value":["kind":"date","value":"2099-10-02"]]]]
        guard let item=try call("create",create).reminder,try call("create",create).reminder==item else{throw AdapterFault("acceptance_replay_failed")}
        guard let readback=try call("get",["list_id":list.id,"reminder_id":item.id]).reminder,let queried=try call("query",["list_id":list.id,"include_completed":true]).reminders,queried.count==1,queried[0].id==readback.id,!readback.completed,readback.title=="ARL synthetic smoke",readback.priority==0,readback.due?.kind=="date",readback.due?.value=="2099-10-02",readback.start==nil,readback.notes==nil,readback.url==nil,readback.recurrence.descriptors.isEmpty,readback.alerts.descriptors.isEmpty else{throw AdapterFault("acceptance_readback_failed")}
        try check();return(list.id,item.id)
    }
}

@MainActor func runRemindersFirstHost(policyPath:String)throws {
    let (policy,hash)=try RemindersFirstPolicy.sealed(policyPath);let identity=try NativePermissionIdentity.current(expectedBundle:"local.arl.remindersbridge")
    let lockPath=policy.host_home+"/host.lock";let lock=open(lockPath,O_CREAT|O_RDWR|O_NOFOLLOW,0o600);guard lock>=0 else{throw RemindersTransportFault("host_lock_unavailable")};var st=stat();guard fstat(lock,&st)==0,st.st_mode&S_IFMT==S_IFREG,st.st_uid==getuid(),st.st_mode&0o077==0,st.st_nlink==1,flock(lock,LOCK_EX|LOCK_NB)==0 else{close(lock);throw RemindersTransportFault("host_already_running")}
    let path=policy.host_home+"/control.sock";if access(path,F_OK)==0{var info=stat();guard lstat(path,&info)==0,info.st_mode&S_IFMT==S_IFSOCK,info.st_uid==getuid(),unlink(path)==0 else{close(lock);throw RemindersTransportFault("unsafe_socket")}}
    let fd=try RemindersNativeIO.socketAt(path,listen:true);let host=try RemindersFirstHost(policy:policy,policyHash:hash,identity:identity)
    #if !REMINDERS_FIRST_SLICE_FIXTURE
    NSApp.setActivationPolicy(.accessory)
    #endif
    DispatchQueue.global().async {
        let slots=DispatchSemaphore(value:8)
        while true {
            let client=accept(fd,nil,nil);if client<0{if errno==EINTR{continue};break}
            guard slots.wait(timeout:.now()) == .success else{close(client);continue}
            var noSignal:Int32=1;_=setsockopt(client,SOL_SOCKET,SO_NOSIGPIPE,&noSignal,socklen_t(MemoryLayout<Int32>.size));_=fcntl(client,F_SETFD,FD_CLOEXEC)
            DispatchQueue.global().async {
                do {let peer=try RemindersNativeIO.Peer(client,requirement:policy.control_requirement);guard let bytes=try RemindersNativeIO.line(client,limit:RemindersProductFrame.requestLimit) else{close(client);slots.signal();return}
                    Task { @MainActor in let reply=await host.handle(bytes,peer:peer);let product=(try? RemindersNativeIO.flatObject(bytes,limit:RemindersProductFrame.requestLimit)).map{RemindersNativeIO.integer($0["schema_version"])==3} ?? false;try? RemindersNativeIO.send(reply,client,limit:product ? 262144:16384);close(client);slots.signal() }
                } catch {try? RemindersNativeIO.send(Data("{\"schema_version\":1,\"outcome\":\"unavailable\",\"code\":\"identity_unverified\"}".utf8),client);close(client);slots.signal()}
            }
        }
    }
    #if REMINDERS_FIRST_SLICE_FIXTURE
    dispatchMain()
    #else
    NSApp.run();close(fd);unlink(path);close(lock)
    #endif
}
