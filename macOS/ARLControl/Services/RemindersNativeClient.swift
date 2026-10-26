import Foundation
import AppKit
import Security
import Darwin

struct RemindersNativeDeployment: Decodable, Sendable {
    let schema_version:Int;let helper_bundle_path:String;let host_home:String;let control_requirement:String
    let helper_requirement:String;let helper_executable_sha256:String;let helper_designated_requirement_sha256:String
    let closure_sha256:String;let policy_sha256:String
    var policyPath:String{host_home+"/activation.json"}
    func activationEnabled() throws -> Bool {
        let raw=try RemindersNativeIO.privateFile(policyPath)
        guard RemindersNativeIO.hash(raw)==policy_sha256 else{throw RemindersTransportFault("activation_hash_changed")}
        let value=try RemindersNativeIO.flatObject(raw)
        guard Set(value.keys)==["schema_version","enabled","control_requirement","host_home","run_id","max_saves","scope_seconds","smoke_delay_seconds","source_policy"],
              RemindersNativeIO.integer(value["schema_version"])==1,
              let enabled=RemindersNativeIO.integer(value["enabled"]),[0,1].contains(enabled),
              RemindersNativeIO.integer(value["max_saves"])==2,RemindersNativeIO.integer(value["scope_seconds"])==300,
              let delay=RemindersNativeIO.integer(value["smoke_delay_seconds"]),(0...30).contains(delay),
              value["control_requirement"] as? String==control_requirement,value["host_home"] as? String==host_home,
              value["source_policy"] as? String=="default_list_source_explicit_owner_confirmation",
              let run=value["run_id"] as? String,UUID(uuidString:run)?.uuidString.lowercased()==run else{throw RemindersTransportFault("invalid_deployment")}
        guard Bundle(path:helper_bundle_path)?.object(forInfoDictionaryKey:"ARLSyntheticFixture") as? Bool==true || delay==30 else{throw RemindersTransportFault("invalid_deployment")}
        return enabled==1
    }
    static func load(home:URL)throws->Self {
        let path=home.appendingPathComponent("reminders-v3/control.json").path
        let raw=try RemindersNativeIO.privateFile(path);let object=try RemindersNativeIO.flatObject(raw)
        guard Set(object.keys)==["schema_version","helper_bundle_path","host_home","control_requirement","helper_requirement","helper_executable_sha256","helper_designated_requirement_sha256","closure_sha256","policy_sha256"],RemindersNativeIO.integer(object["schema_version"])==1 else{throw RemindersTransportFault("invalid_deployment")}
        let value=try JSONDecoder().decode(Self.self,from:raw)
        guard value.helper_bundle_path.hasPrefix("/"),value.helper_bundle_path.hasSuffix("/ARLRemindersBridge.app"),value.host_home.hasPrefix("/"),value.control_requirement==RemindersStablePeerIdentity.controlRequirement,value.helper_requirement==RemindersStablePeerIdentity.helperRequirement,[value.helper_executable_sha256,value.helper_designated_requirement_sha256,value.closure_sha256,value.policy_sha256].allSatisfy({$0.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil}) else{throw RemindersTransportFault("invalid_deployment")}
        try RemindersNativeIO.privateDirectory(value.host_home);return value
    }
    /// An ordinary signed-app upgrade may refresh executable hashes for the same
    /// stable subject. This never changes activation, source grants or history.
    static func loadVerified(home:URL)throws->Self {
        let current=try load(home:home)
        do {try current.verify(home:home);return current}
        catch let fault as RemindersTransportFault where fault.code == "identity_changed" {
            let app=URL(fileURLWithPath:NSHomeDirectory()).appendingPathComponent("Applications/ARL.app")
            let expectedHelper=app.appendingPathComponent("Contents/Library/LoginItems/ARLRemindersBridge.app").path
            guard Bundle.main.bundleURL.standardizedFileURL == app.standardizedFileURL,
                  current.helper_bundle_path == expectedHelper,
                  current.host_home == home.appendingPathComponent("reminders-v3").path
            else {throw fault}
            let controlPath=home.appendingPathComponent("reminders-v3/control.json").path
            let closurePath=home.appendingPathComponent("reminders-v3/closure.json").path
            let controlRaw=try RemindersNativeIO.privateFile(controlPath)
            let closureRaw=try RemindersNativeIO.privateFile(closurePath)
            let actual=RemindersNativeIO.hash(try Data(contentsOf:URL(fileURLWithPath:expectedHelper+"/Contents/MacOS/ARLRemindersBridge")))
            guard actual != current.helper_executable_sha256 else {throw fault}
            // Full verification still checks both signatures, stable DR, sealed
            // policy, exact closure and every non-executable resource.
            try current.verify(home:home,replacementExecutableSHA:actual)
            let replacement=try codeBindingReplacement(controlRaw:controlRaw,closureRaw:closureRaw,actualExecutableSHA:actual)
            guard try RemindersNativeIO.privateFile(controlPath)==controlRaw,
                  try RemindersNativeIO.privateFile(closurePath)==closureRaw else{throw RemindersTransportFault("identity_changed")}
            try RemindersNativeIO.atomicWrite(replacement.closure,to:closurePath)
            do {try RemindersNativeIO.atomicWrite(replacement.control,to:controlPath)}
            catch {
                if (try? RemindersNativeIO.privateFile(closurePath)) == replacement.closure {
                    try? RemindersNativeIO.atomicWrite(closureRaw,to:closurePath)
                }
                throw error
            }
            let updated=try load(home:home);try updated.verify(home:home);return updated
        }
    }
    static func codeBindingReplacement(controlRaw:Data,closureRaw:Data,actualExecutableSHA:String)throws->(control:Data,closure:Data) {
        var control=try RemindersNativeIO.flatObject(controlRaw)
        let old=try JSONDecoder().decode(Self.self,from:controlRaw)
        guard RemindersNativeIO.hash(closureRaw)==old.closure_sha256,
              var closure=try JSONSerialization.jsonObject(with:closureRaw) as? [String:String],
              closure["Contents/MacOS/ARLRemindersBridge"]==old.helper_executable_sha256,
              actualExecutableSHA.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil
        else{throw RemindersTransportFault("identity_changed")}
        closure["Contents/MacOS/ARLRemindersBridge"]=actualExecutableSHA
        let bytes=try JSONSerialization.data(withJSONObject:closure,options:[.sortedKeys])
        control["helper_executable_sha256"]=actualExecutableSHA
        control["closure_sha256"]=RemindersNativeIO.hash(bytes)
        return (try JSONSerialization.data(withJSONObject:control,options:[.sortedKeys]),bytes)
    }
    // The marker is read only after strict signature verification. Unknown or
    // ill-typed layouts never fall back to the legacy dynamic-library closure.
    static func expectedClosure(linkage:Any?)throws->Set<String> {
        let common:Set<String>=["Contents/Info.plist","Contents/MacOS/ARLRemindersBridge","Contents/_CodeSignature/CodeResources"]
        if linkage == nil {return common.union(["Contents/Frameworks/libARLRemindersCore.dylib","Contents/Frameworks/libARLRemindersEventKit.dylib"])}
        guard let value=linkage as? String,value=="static" else{throw RemindersTransportFault("identity_changed_closure")}
        return common
    }
    func verify(home:URL, replacementExecutableSHA:String? = nil)throws {
        var own:SecCode?;var ownRequirement:SecRequirement?
        guard SecCodeCopySelf([],&own)==errSecSuccess,let own,SecRequirementCreateWithString(control_requirement as CFString,[],&ownRequirement)==errSecSuccess,let ownRequirement,SecCodeCheckValidity(own,SecCSFlags(rawValue:kSecCSStrictValidate),ownRequirement)==errSecSuccess else{throw RemindersTransportFault("control_identity_changed")}
        guard let bundle=Bundle(path:helper_bundle_path),bundle.bundleIdentifier=="local.arl.remindersbridge",bundle.object(forInfoDictionaryKey:"CFBundleExecutable") as? String == "ARLRemindersBridge",bundle.object(forInfoDictionaryKey:"ARLFirstRemindersPolicyPath") as? String == policyPath,bundle.object(forInfoDictionaryKey:"ARLFirstRemindersPolicySHA256") as? String == policy_sha256 else{throw RemindersTransportFault("identity_changed")}
        var code:SecStaticCode?;var requirement:SecRequirement?;var dr:SecRequirement?;var drData:CFData?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath:helper_bundle_path) as CFURL,[],&code)==errSecSuccess,let code,SecRequirementCreateWithString(helper_requirement as CFString,[],&requirement)==errSecSuccess,let requirement,SecStaticCodeCheckValidity(code,SecCSFlags(rawValue:kSecCSStrictValidate),requirement)==errSecSuccess else{throw RemindersTransportFault("identity_changed_signature")}
        guard SecCodeCopyDesignatedRequirement(code,[],&dr)==errSecSuccess,let dr,SecRequirementCopyData(dr,[],&drData)==errSecSuccess,let drData,RemindersNativeIO.hash(drData as Data)==helper_designated_requirement_sha256 else{throw RemindersTransportFault("identity_changed_designated_requirement")}
        let closureRaw=try RemindersNativeIO.privateFile(home.appendingPathComponent("reminders-v3/closure.json").path)
        guard RemindersNativeIO.hash(closureRaw)==closure_sha256,let closure=try JSONSerialization.jsonObject(with:closureRaw) as? [String:String] else{throw RemindersTransportFault("identity_changed")}
        let expected=try Self.expectedClosure(linkage:bundle.object(forInfoDictionaryKey:"ARLRemindersLinkage"))
        guard Set(closure.keys)==expected else{throw RemindersTransportFault("identity_changed_closure")}
        for (relative,hash) in closure {
            let path=helper_bundle_path+"/"+relative;var st=stat();guard lstat(path,&st)==0,st.st_mode&S_IFMT==S_IFREG,st.st_uid==getuid(),st.st_mode&0o022==0 else{throw RemindersTransportFault("identity_changed")}
            let expectedHash = relative == "Contents/MacOS/ARLRemindersBridge" ? (replacementExecutableSHA ?? hash) : hash
            guard RemindersNativeIO.hash(try Data(contentsOf:URL(fileURLWithPath:path)))==expectedHash else{throw RemindersTransportFault("identity_changed")}
        }
        guard closure["Contents/MacOS/ARLRemindersBridge"]==helper_executable_sha256 else{throw RemindersTransportFault("identity_changed")}
        guard RemindersNativeIO.hash(try RemindersNativeIO.privateFile(policyPath))==policy_sha256 else{throw RemindersTransportFault("activation_hash_changed")}
        let policy=try RemindersNativeIO.flatObject(RemindersNativeIO.privateFile(policyPath));guard policy["control_requirement"] as? String==control_requirement,policy["host_home"] as? String==host_home else{throw RemindersTransportFault("invalid_deployment")}
    }
}

// All callers execute this code inside the real signed Control process. Python
// never stands in for its audit token. Reading/polling never launches an app.
struct RemindersNativeClient: Sendable {
    let home:URL
    var configured:Bool{FileManager.default.fileExists(atPath:home.appendingPathComponent("reminders-v3/control.json").path)}
    func configurationState() -> RemindersServiceState {
        guard configured else{return .notInstalled}
        do {
            let deployment=try RemindersNativeDeployment.loadVerified(home:home)
            guard try deployment.activationEnabled() else{return .verifiedDisabled}
            return Bundle(path:deployment.helper_bundle_path)?.object(forInfoDictionaryKey:"ARLSyntheticFixture") as? Bool==true ? .synthetic:.verifiedEnabled
        } catch {return .identityUnverified}
    }
    func call(_ frame:RemindersFirstFrame,launch:Bool=false) async throws->RemindersFirstReply {
        let deployment=try RemindersNativeDeployment.loadVerified(home:home)
        // Disabled policy is rejected before socket access or LaunchServices.
        // A status refresh cannot silently activate an internal service.
        guard try deployment.activationEnabled() else{throw RemindersTransportFault("activation_disabled")}
        if launch {
            guard frame.action == .snapshot else{throw RemindersTransportFault("invalid_arguments")}
            do{return try await Self.cancellableExchange(frame,deployment:deployment,home:home)}
            catch let error as RemindersTransportFault where error.code=="transport_unavailable"{ }
            try Task.checkCancellation()
            try await Self.launch(deployment)
            try Task.checkCancellation()
            for _ in 0..<40{
                do{return try await Self.cancellableExchange(frame,deployment:deployment,home:home)}
                catch let error as RemindersTransportFault where error.code=="transport_unavailable"{try await Task.sleep(for:.milliseconds(100))}
            }
            throw RemindersTransportFault("helper_start_timeout")
        }
        return try await Self.cancellableExchange(frame,deployment:deployment,home:home)
    }
    /// Full product calls use the same verified peer and packaged helper.
    /// This entry never launches the helper or requests permission.
    func callProduct(_ frame:RemindersProductFrame)async throws->RemindersProductReply {
        let deployment=try RemindersNativeDeployment.loadVerified(home:home)
        guard try deployment.activationEnabled() else{throw RemindersTransportFault("activation_disabled")}
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        let request=try encoder.encode(frame)
        _=try RemindersProductFrame.decode(request)
        let stop=RemindersExchangeCancellation()
        return try await withTaskCancellationHandler(operation:{
            let reply=try await Task.detached {
                let fd=try RemindersNativeIO.socketAt(deployment.host_home+"/control.sock",listen:false)
                defer{stop.release(fd);close(fd)}
                try stop.attach(fd)
                let peer=try RemindersNativeIO.Peer(fd,requirement:deployment.helper_requirement)
                guard peer.current() else{throw RemindersTransportFault("identity_changed_peer")}
                try RemindersNativeIO.send(request,fd,limit:RemindersProductFrame.requestLimit)
                guard let bytes=try RemindersNativeIO.line(fd,limit:RemindersProductFrame.responseLimit,seconds:frame.action == .submit ? 130:15),
                      peer.signatureCurrent() else{throw RemindersTransportFault("identity_changed_peer")}
                try deployment.verify(home:home)
                return try Self.admitProductReply(bytes,for:frame,deployment:deployment)
            }.value
            try Task.checkCancellation();return reply
        },onCancel:{stop.cancel()})
    }
    static func admitProductReply(_ bytes:Data,for frame:RemindersProductFrame,deployment:RemindersNativeDeployment)throws->RemindersProductReply {
        guard bytes.count<=262144 else{throw RemindersTransportFault("invalid_response")}
        let reply=try JSONDecoder().decode(RemindersProductReply.self,from:bytes)
        guard reply.schema_version==3,reply.capability_id=="reminders.product.v1",reply.request_id==frame.request_id,reply.action==frame.action,
              reply.identity.helper_bundle_id=="local.arl.remindersbridge",
              reply.identity.executable_sha256==deployment.helper_executable_sha256,
              reply.identity.designated_requirement_sha256==deployment.helper_designated_requirement_sha256,
              reply.policy_sha256==deployment.policy_sha256,!reply.automatic_replay,
              ["refreshed","completed","saved_local","needs_review","unavailable"].contains(reply.outcome),
              reply.code.range(of:"^[a-z0-9_]{1,96}$",options:.regularExpression) != nil else{throw RemindersTransportFault("invalid_response")}
        try reply.catalog?.validate()
        if frame.action == .history {
            guard reply.task==nil,reply.result_json==nil,reply.catalog==nil,reply.target==nil,
                  reply.outcome != "refreshed" || reply.history != nil else{throw RemindersTransportFault("invalid_response")}
        } else {guard reply.history==nil,reply.next_offset==nil else{throw RemindersTransportFault("invalid_response")}}
        if let history=reply.history {
            guard frame.action == .history,history.count<=20,Set(history.map(\.task_id)).count==history.count,
                  history.allSatisfy({RemindersTaskContract.uuid($0.task_id) && ["pending","saved_local","rejected","unknown"].contains($0.state)}),
                  reply.next_offset == nil || reply.next_offset==(frame.offset ?? 0)+history.count && reply.next_offset!>(frame.offset ?? 0) && reply.next_offset!<=4096 else{throw RemindersTransportFault("invalid_response")}
        }
        if let target=reply.target {
            guard target.helper_requirement_sha256==deployment.helper_designated_requirement_sha256,target.policy_sha256==deployment.policy_sha256,
                  target.list == nil || target.list?.source_id==target.source.id else{throw RemindersTransportFault("invalid_response")}
        }
        if let task=reply.task {
            guard task.task_id==frame.task_id,RemindersTaskContract.uuid(task.task_id),task.operation_id==RemindersProductContract.operationID(task.task_id),
                  RemindersTaskContract.hash(task.request_sha256),["pending","saved_local","rejected","unknown"].contains(task.state),
                  task.target.policy_sha256==deployment.policy_sha256,task.target.helper_requirement_sha256==deployment.helper_designated_requirement_sha256,
                  task.request_json.utf8.count<=16384 else{throw RemindersTransportFault("invalid_response")}
        }
        if let raw=reply.result_json {
            guard raw.utf8.count<=60000,let result=reply.result,result.schema_version==3,result.status=="ok" else{throw RemindersTransportFault("invalid_response")}
            if reply.outcome=="saved_local" {
                guard result.persistence=="saved_local",result.cloud_sync=="not_checked",result.operation_id==reply.task?.operation_id else{throw RemindersTransportFault("invalid_response")}
            }
        }
        guard reply.outcome != "saved_local" || reply.task?.state=="saved_local" && reply.result != nil else{throw RemindersTransportFault("invalid_response")}
        return reply
    }

    /// Normal ARL exit also drains its one packaged reminder owner. Never
    /// launches a service, changes a grant, force-quits, or cancels active work.
    @MainActor func stopForAppExit() async throws {
        let expected=Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LoginItems/ARLRemindersBridge.app").standardizedFileURL
        let running=NSRunningApplication.runningApplications(withBundleIdentifier:"local.arl.remindersbridge").filter { !$0.isTerminated }
        guard running.count <= 1, running.allSatisfy({ $0.bundleURL?.standardizedFileURL == expected }) else {
            throw RemindersTransportFault("identity_changed_helper_path")
        }
        guard let process=running.first else { return }
        let reply=try await call(RemindersFirstFrame(action:.shutdown,requestID:UUID()))
        guard reply.outcome == "completed", reply.code == "shutdown_requested" else {
            throw RemindersTransportFault(reply.code == "request_busy" ? "request_busy" : "helper_drain_unsupported")
        }
        let deadline=ProcessInfo.processInfo.systemUptime+5
        while !process.isTerminated && ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for:.milliseconds(25))
        }
        guard process.isTerminated else { throw RemindersTransportFault("helper_drain_unproven") }
    }
    @MainActor private static func launch(_ deployment:RemindersNativeDeployment) async throws {
        let configuration=NSWorkspace.OpenConfiguration();configuration.arguments=["--serve-approved",deployment.policyPath];configuration.activates=false;configuration.createsNewApplicationInstance=true
        _=try await NSWorkspace.shared.openApplication(at:URL(fileURLWithPath:deployment.helper_bundle_path),configuration:configuration)
    }
    private static func cancellableExchange(_ frame:RemindersFirstFrame,deployment:RemindersNativeDeployment,home:URL) async throws -> RemindersFirstReply {
        let stop=RemindersExchangeCancellation()
        return try await withTaskCancellationHandler(operation:{
            let result=try await Task.detached {
                try stop.check()
                return try exchange(frame,deployment:deployment,home:home,stop:stop)
            }.value
            try Task.checkCancellation()
            return result
        },onCancel:{ stop.cancel() })
    }
    private static func exchange(_ frame:RemindersFirstFrame,deployment:RemindersNativeDeployment,home:URL,stop:RemindersExchangeCancellation)throws->RemindersFirstReply {
        let fd=try RemindersNativeIO.socketAt(deployment.host_home+"/control.sock",listen:false)
        defer { stop.release(fd);close(fd) }
        try stop.attach(fd)
        let peer=try RemindersNativeIO.Peer(fd,requirement:deployment.helper_requirement)
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        guard peer.current() else { throw RemindersTransportFault("identity_changed_peer") }
        try RemindersNativeIO.send(try encoder.encode(frame),fd)
        guard let bytes=try RemindersNativeIO.line(fd,seconds:[.snapshot,.retest,.cancel,.disconnect,.shutdown,.task_status,.task_list].contains(frame.action) ? 5:190) else { throw RemindersTransportFault("identity_changed_peer") }
        // The authenticated socket cannot change its peer. Shutdown may exit
        // after its final reply; data/effect calls still revalidate live code.
        guard frame.action == .shutdown || peer.signatureCurrent() else { throw RemindersTransportFault("identity_changed_peer") }
        try deployment.verify(home:home)
        return try admitReply(bytes,for:frame,deployment:deployment)
    }
    // The socket path and focused DTO tests share exactly this admission gate.
    // Peer and deployment checks remain in exchange, before reply admission.
    static func admitReply(_ bytes:Data,for frame:RemindersFirstFrame,deployment:RemindersNativeDeployment)throws->RemindersFirstReply {
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        let reply=try JSONDecoder().decode(RemindersFirstReply.self,from:bytes)
        guard reply.schema_version==1,reply.request_id==frame.request_id,reply.action==frame.action,["refreshed","completed","denied","restricted","user_cancelled","source_selected","saved_local","disconnected","unavailable","needs_review","source_reviewed","historical_completed","unknown_preserved"].contains(reply.outcome) else{throw RemindersTransportFault("invalid_response")}
        if RemindersTaskContract.actions.contains(frame.action) {
            if let task=reply.task {
                guard task.schema_version==1,task.task_id==frame.task_id,task.operation_id==RemindersTaskContract.operationID(task.task_id),
                      task.identity.helper_bundle_id=="local.arl.remindersbridge",task.identity.designated_requirement_sha256==deployment.helper_designated_requirement_sha256,
                      RemindersTaskContract.hash(task.identity.executable_sha256),task.policy_sha256==deployment.policy_sha256,
                      frame.action != .task_prepare || task.title==frame.title else{throw RemindersTransportFault("invalid_response")}
                try RemindersTaskContract.title(task.title)
                if let scope=task.scope {try RemindersTaskContract.target(scope.source)}
            }
            if frame.action == .task_list {
                guard reply.task==nil else{throw RemindersTransportFault("invalid_response")}
                if let page=reply.task_page {
                    guard page.offset==frame.offset,page.entries.count<=5,
                          page.next_offset==nil || page.next_offset==page.offset+page.entries.count,
                          page.next_offset==nil || (page.next_offset!<=256 && page.next_offset!>page.offset),
                          Set(page.entries.map(\.task_id)).count==page.entries.count else{throw RemindersTransportFault("invalid_response")}
                    for row in page.entries{guard RemindersTaskContract.uuid(row.task_id) else{throw RemindersTransportFault("invalid_response")};try RemindersTaskContract.title(row.title)}
                } else if reply.outcome == "refreshed" {throw RemindersTransportFault("invalid_response")}
            } else {
                guard reply.task_page==nil,reply.task != nil || !["completed","refreshed","saved_local"].contains(reply.outcome) else{throw RemindersTransportFault("invalid_response")}
            }
        } else {guard reply.task==nil,reply.task_page==nil else{throw RemindersTransportFault("invalid_response")}}
        if let snapshot=reply.snapshot {
            let validated=try RemindersFirstSnapshot.decode(encoder.encode(snapshot))
            guard validated.identity.executable_sha256==deployment.helper_executable_sha256,validated.identity.designated_requirement_sha256==deployment.helper_designated_requirement_sha256 else{throw RemindersTransportFault("identity_changed_evidence")}
        }
        return reply
    }
}

/// Cancellation owns shutdown, never close: the exchange keeps descriptor
/// lifetime so an old callback cannot close or shutdown a reused descriptor.
final class RemindersExchangeCancellation: @unchecked Sendable {
    private let lock=NSLock()
    private var stopped=false
    private var descriptor:Int32?
    func check() throws {
        lock.lock();defer{lock.unlock()}
        if stopped { throw CancellationError() }
    }
    func attach(_ fd:Int32) throws {
        lock.lock();defer{lock.unlock()}
        guard !stopped else { throw CancellationError() }
        descriptor=fd
    }
    func release(_ fd:Int32) {
        lock.lock();defer{lock.unlock()}
        if descriptor==fd { descriptor=nil }
    }
    func cancel() {
        lock.lock();defer{lock.unlock()};stopped=true
        if let descriptor { _=shutdown(descriptor,SHUT_RDWR) }
    }
}
