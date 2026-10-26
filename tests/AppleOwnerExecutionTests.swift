import Foundation
import Darwin
import ARLRemindersCore

@MainActor @main enum AppleOwnerExecutionTests {
    enum Failure: Error { case assertion(String), journal }
    static var checks=0
    static func expect(_ value:Bool,_ name:String)throws {guard value else{throw Failure.assertion(name)};checks+=1}
    static func reject(_ name:String,_ body:()throws->Void)throws {do{try body()}catch{checks+=1;return};throw Failure.assertion(name)}
    static func uuid()->String{UUID().uuidString.lowercased()}
    static func bytes(_ value:[String:Any])throws->Data{try OwnerReadWire.encode(value,limit:OwnerReadWire.responseLimit)}
    static func args(_ id:String,_ title:String?="Synthetic owner task")throws->Data {
        var value:[String:Any]=["task_id":id];if let title{value["title"]=title};return try bytes(value)
    }
    static func result(_ value:Data)throws->AppleOwnerResult{try JSONDecoder().decode(AppleOwnerResult.self,from:value)}
    @MainActor final class Fixture {
        let store:RemindersTaskStore
        let repository=FixtureRepository()
        let target=RemindersSelectedSource(id:"fixture-source",title:"Synthetic local",type:0,default_list_id:"fixture-list",default_list_title:"Synthetic list")
        var calls:[RemindersFirstAction]=[]
        var records:[(Data,Data?)]=[]
        var ensures=0,beginCount=0,endCount=0
        var busy=false,decline=false,cancelAfterScope=false,badReply=false,failInput=false,failOutput=false,failEnsure=false
        init(_ root:URL)throws {
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
            store=RemindersTaskStore(home:root.path,identity:.init(helper_bundle_id:"local.arl.remindersbridge",executable_sha256:String(repeating:"a",count:64),designated_requirement_sha256:String(repeating:"b",count:64)),policy:RemindersUpgradeReview.targetPolicy,legacyRunID:"00000000-0000-4000-8000-000000000001",sessionID:UUID().uuidString.lowercased())
        }
        var executor:AppleOwnerExecutor {
            AppleOwnerExecutor(port:.init(begin:{_ in self.beginCount+=1;return !self.busy},end:{_ in self.endCount+=1},ensureService:{self.ensures+=1;if self.failEnsure{throw RemindersTransportFault("needs_permission")}},send:{try self.send($0)},observe:{_ in},record:{_,_,input,output in
                if output==nil && self.failInput || output != nil && self.failOutput{throw Failure.journal};self.records.append((input,output))
            }))
        }
        func scoped(_ id:String,title:String="Synthetic owner task")throws->RemindersTaskRecord {
            let d=try store.prepare(id:id,title:title)
            return try store.grant(id:id,expected:d.digest,source:target,nowMS:Int64(Date().timeIntervalSince1970*1000),uptime:ProcessInfo.processInfo.systemUptime)
        }
        func send(_ frame:RemindersFirstFrame)throws->RemindersFirstReply {
            calls.append(frame.action)
            let task:RemindersTaskRecord?
            var code="ok",outcome="refreshed"
            switch frame.action {
            case .task_status:
                do{task=try store.read(frame.task_id!)}catch let e as RemindersTransportFault where e.code=="task_not_found"{task=nil;code=e.code;outcome="unavailable"}
            case .task_prepare:task=try store.prepare(id:frame.task_id!,title:frame.title!)
            case .task_scope:
                if decline {task=try store.read(frame.task_id!);outcome="user_cancelled";code="cancelled"}
                else {task=try store.grant(id:frame.task_id!,expected:frame.expected_digest!,source:target,nowMS:Int64(Date().timeIntervalSince1970*1000),uptime:ProcessInfo.processInfo.systemUptime);code="task_scope_selected"}
                if cancelAfterScope{withUnsafeCurrentTask{$0?.cancel()}}
            case .task_submit:
                task=try store.submit(id:frame.task_id!,expected:frame.expected_digest!,nowMS:Int64(Date().timeIntervalSince1970*1000),uptime:ProcessInfo.processInfo.systemUptime,validate:{_ in},effect:{try RemindersTaskRunner.create($0,home:self.store.home,repository:self.repository,check:{})})
                code="task_saved";outcome="saved_local"
            case .task_cancel:task=try store.cancel(id:frame.task_id!,expected:frame.expected_digest!);code="task_cancelled";outcome="user_cancelled"
            default:throw Failure.assertion("unexpected native action")
            }
            return .init(schema_version:1,request_id:badReply ? UUID().uuidString.lowercased():frame.request_id,action:frame.action,outcome:outcome,code:code,snapshot:nil,task:task)
        }
    }
    static func main()async throws {
        guard CommandLine.arguments.count==2 else{throw Failure.assertion("new fixture directory required")}
        let root=URL(fileURLWithPath:CommandLine.arguments[1]);guard !FileManager.default.fileExists(atPath:root.path) else{throw Failure.assertion("existing fixture forbidden")}
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        var n=0
        func fixture()throws->Fixture{n+=1;return try Fixture(root.appendingPathComponent("case-\(n)"))}
        let id=uuid(),input=try args(id)
        let f=try fixture(),saved=try result(await f.executor.execute(tool:AppleCapability.reminderCreate,argumentsJSON:input,callID:UUID()))
        try expect(saved.state=="saved_local" && saved.task_id==id && f.repository.saveAttempts==1,"shared executor reaches actual production task adapter once")
        try expect(f.calls == [.task_status,.task_prepare,.task_scope,.task_submit] && f.ensures==1,"status then existing prepare scope submit only")
        try expect(f.beginCount==1 && f.endCount==1 && f.records.count==2 && f.records[0].0==input && f.records[1].1 != nil,"full original request and result within busy lifetime")
        try expect(!saved.automatic_replay && !saved.new_submission_allowed && saved.cloud_sync=="not_checked","local save never asserts sync or replay")
        f.calls=[]
        let repeated=try result(await f.executor.execute(tool:AppleCapability.reminderCreate,argumentsJSON:input,callID:UUID()))
        try expect(repeated.state=="saved_local" && f.calls == [.task_status] && f.repository.saveAttempts==1,"same UUID repeat is read only")
        f.calls=[]
        let status=try result(await f.executor.execute(tool:AppleCapability.reminderStatus,argumentsJSON:args(id,nil),callID:UUID()))
        try expect(status.state=="saved_local" && f.ensures==2 && f.calls == [.task_status],"status never starts helper or enters save")
        for state in ["draft","scoped","unknown","cancelled"] {
            let x=try fixture(),i=uuid()
            switch state {
            case "draft":_=try x.store.prepare(id:i,title:"Synthetic owner task")
            case "scoped":_=try x.scoped(i)
            case "cancelled":let d=try x.store.prepare(id:i,title:"Synthetic owner task");_=try x.store.cancel(id:i,expected:d.digest)
            default:
                let d=try x.scoped(i)
                do{_=try x.store.submit(id:i,expected:d.digest,nowMS:Int64(Date().timeIntervalSince1970*1000),uptime:ProcessInfo.processInfo.systemUptime,validate:{_ in},effect:{_ in throw Failure.journal})}catch{}
            }
            let r=try result(await x.executor.execute(tool:AppleCapability.reminderCreate,argumentsJSON:args(i),callID:UUID()))
            try expect(x.calls == [.task_status] && x.repository.saveAttempts==0 && r.task_id==i,"existing \(state) is never resumed")
        }
        let missing=try fixture(),missingID=uuid()
        let missingResult=try result(await missing.executor.execute(tool:AppleCapability.reminderStatus,argumentsJSON:args(missingID,nil),callID:UUID()))
        try expect(missingResult.state=="operation_missing" && missing.calls == [.task_status] && missing.ensures==0,"missing status cannot bootstrap an operation")
        let declined=try fixture();declined.decline=true
        let no=try result(await declined.executor.execute(tool:AppleCapability.reminderCreate,argumentsJSON:args(uuid()),callID:UUID()))
        try expect(no.state=="cancelled" && !declined.calls.contains(.task_submit) && declined.repository.saveAttempts==0,"native decline prevents submission")
        let late=try fixture();late.cancelAfterScope=true;let lateID=uuid()
        let child=Task{try await late.executor.execute(tool:AppleCapability.reminderCreate,argumentsJSON:args(lateID),callID:UUID())}
        let cancelled=try result(await child.value)
        try expect(cancelled.state=="not_dispatched" && cancelled.code=="cancelled" && !late.calls.contains(.task_submit) && late.repository.saveAttempts==0,"late native confirmation cannot save a cancelled owner call")
        let busy=try fixture();busy.busy=true
        let blocked=try result(await busy.executor.execute(tool:AppleCapability.reminderCreate,argumentsJSON:args(uuid()),callID:UUID()))
        try expect(blocked.state=="owner_busy" && busy.calls.isEmpty && busy.ensures==0 && busy.endCount==0,"busy gate precedes any service call")
        let inputFailure=try fixture();inputFailure.failInput=true
        do{_=try await inputFailure.executor.execute(tool:AppleCapability.reminderCreate,argumentsJSON:args(uuid()),callID:UUID());throw Failure.assertion("input log failure accepted")}catch Failure.journal{checks+=1}
        try expect(inputFailure.calls.isEmpty && inputFailure.ensures==0 && inputFailure.beginCount==0,"failed input persistence prevents effects")
        let outputFailure=try fixture();outputFailure.failOutput=true;let outputID=uuid()
        do{_=try await outputFailure.executor.execute(tool:AppleCapability.reminderCreate,argumentsJSON:args(outputID),callID:UUID());throw Failure.assertion("output log failure accepted")}catch Failure.journal{checks+=1}
        try expect(outputFailure.repository.saveAttempts==1 && (try outputFailure.store.read(outputID)).state == .saved && outputFailure.endCount==1,"lost output log leaves original durable saved task and releases gate")
        outputFailure.failOutput=false;outputFailure.calls=[]
        _=try await outputFailure.executor.execute(tool:AppleCapability.reminderCreate,argumentsJSON:args(outputID),callID:UUID())
        try expect(outputFailure.repository.saveAttempts==1 && outputFailure.calls == [.task_status],"output persistence failure cannot cause another save")
        let uncertain=try fixture();uncertain.repository.failAfterSave=true;let uncertainID=uuid()
        let unknown=try result(await uncertain.executor.execute(tool:AppleCapability.reminderCreate,argumentsJSON:args(uncertainID),callID:UUID()))
        uncertain.calls=[]
        let reconciled=try result(await uncertain.executor.execute(tool:AppleCapability.reminderCreate,argumentsJSON:args(uncertainID),callID:UUID()))
        try expect(unknown.state=="outcome_unknown" && reconciled.state=="outcome_unknown" && uncertain.calls == [.task_status] && uncertain.repository.saveAttempts==1,"post-commit unknown is never replayed")
        let permission=try fixture();permission.failEnsure=true
        let noPermission=try result(await permission.executor.execute(tool:AppleCapability.reminderCreate,argumentsJSON:args(uuid()),callID:UUID()))
        try expect(noPermission.state=="not_dispatched" && noPermission.code=="needs_permission" && permission.calls.isEmpty && permission.repository.saveAttempts==0,"permission preflight failure is explicitly not dispatched")
        let wrong=try fixture();wrong.badReply=true
        let invalid=try result(await wrong.executor.execute(tool:AppleCapability.reminderCreate,argumentsJSON:args(uuid()),callID:UUID()))
        try expect(invalid.code=="invalid_response" && wrong.calls == [.task_status] && wrong.repository.saveAttempts==0,"wrong reply UUID cannot advance chain")
        let mismatch=try fixture();let mismatchID=uuid();_=try mismatch.store.prepare(id:mismatchID,title:"Original exact title")
        let changed=try result(await mismatch.executor.execute(tool:AppleCapability.reminderCreate,argumentsJSON:args(mismatchID),callID:UUID()))
        try expect(changed.code=="task_changed" && mismatch.calls == [.task_status],"same UUID cannot replace exact title")
        for field in ["approved","target","list_id","command","path"] {var a:[String:Any]=["task_id":uuid(),"title":"Synthetic"];a[field]="injected";try reject("caller cannot supply \(field)"){_=try AppleCapability.request(tool:AppleCapability.reminderCreate,argumentsJSON:bytes(a))}}
        try reject("duplicate JSON key rejected"){_=try AppleCapability.request(tool:AppleCapability.reminderStatus,argumentsJSON:Data("{\"task_id\":\"\(id)\",\"task_id\":\"\(id)\"}".utf8))}
        // Local UI explicitly confirms scope, then separately submits that exact digest.
        let local=try fixture(),localID=uuid();let localDraft=try local.store.prepare(id:localID,title:"Synthetic owner task")
        let scopeFrame=RemindersFirstFrame(task:.task_scope,requestID:UUID(),taskID:localID,expected:localDraft.digest)
        let localScope=try result(await local.executor.executeLocal(scopeFrame,callID:UUID()))
        try expect(localScope.state=="awaiting_local_action" && local.calls == [.task_status,.task_scope] && local.repository.saveAttempts==0,"explicit local scope confirms but does not save")
        let loggedScope=try OwnerReadJSON.object(local.records[0].0,limit:OwnerReadWire.requestLimit)
        try expect(loggedScope["action"] as? String=="task_scope" && loggedScope["expected_digest"] as? String==localDraft.digest && local.records.count==2 && local.endCount==1,"local scope original frame and result use common log and busy boundary")
        local.calls=[]
        _=try await local.executor.execute(tool:AppleCapability.reminderCreate,argumentsJSON:args(localID),callID:UUID())
        try expect(local.calls == [.task_status] && local.repository.saveAttempts==0,"Mio cannot resume a locally scoped task")
        local.calls=[]
        let submitFrame=RemindersFirstFrame(task:.task_submit,requestID:UUID(),taskID:localID,expected:localScope.task!.digest)
        let localSaved=try result(await local.executor.executeLocal(submitFrame,callID:UUID()))
        try expect(localSaved.state=="saved_local" && local.calls == [.task_status,.task_submit] && local.repository.saveAttempts==1,"explicit local submit reaches same production effect exactly once")
        try expect(local.records.count==6 && local.beginCount==3 && local.endCount==3,"manual continuation preserves full input/result logging inside admission")
        local.calls=[]
        _=try await local.executor.executeLocal(submitFrame,callID:UUID())
        try expect(local.calls == [.task_status] && local.repository.saveAttempts==1,"repeated explicit local submit reconciles terminal record without resend")
        let staleLocal=try fixture(),staleID=uuid();let staleTask=try staleLocal.scoped(staleID)
        let staleFrame=RemindersFirstFrame(task:.task_submit,requestID:UUID(),taskID:staleID,expected:String(repeating:"d",count:64))
        let staleResult=try result(await staleLocal.executor.executeLocal(staleFrame,callID:UUID()))
        try expect(staleResult.code=="task_changed" && staleLocal.calls == [.task_status] && staleLocal.repository.saveAttempts==0,"local submit cannot replace the displayed exact digest")
        let failedLog=try fixture();failedLog.failInput=true
        do{_=try await failedLog.executor.executeLocal(scopeFrame,callID:UUID());throw Failure.assertion("local input log failure accepted")}catch Failure.journal{checks+=1}
        try expect(failedLog.calls.isEmpty && failedLog.ensures==0,"manual scope cannot proceed without original input persistence")
        let localOutput=try fixture(),localOutputID=uuid();let outputTask=try localOutput.scoped(localOutputID);localOutput.failOutput=true
        let outputFrame=RemindersFirstFrame(task:.task_submit,requestID:UUID(),taskID:localOutputID,expected:outputTask.digest)
        do{_=try await localOutput.executor.executeLocal(outputFrame,callID:UUID());throw Failure.assertion("local output log failure accepted")}catch Failure.journal{checks+=1}
        try expect(localOutput.repository.saveAttempts==1 && (try localOutput.store.read(localOutputID)).state == .saved && localOutput.endCount==1,"manual output persistence failure preserves durable task and releases gate")
        localOutput.failOutput=false;localOutput.calls=[]
        _=try await localOutput.executor.executeLocal(outputFrame,callID:UUID())
        try expect(localOutput.repository.saveAttempts==1 && localOutput.calls == [.task_status],"manual output failure cannot permit a second save")
        let cancelledLocal=try fixture(),cancelID=uuid();let cancelDraft=try cancelledLocal.store.prepare(id:cancelID,title:"Synthetic owner task")
        let cancelFrame=RemindersFirstFrame(task:.task_cancel,requestID:UUID(),taskID:cancelID,expected:cancelDraft.digest)
        let cancelResult=try result(await cancelledLocal.executor.executeLocal(cancelFrame,callID:UUID()))
        try expect(cancelResult.state=="cancelled" && cancelledLocal.records.count==2 && cancelledLocal.repository.saveAttempts==0,"manual task cancellation shares the same logging boundary")
        let list=try MioReadOwnerAdapter.respond(["jsonrpc":"2.0","id":1,"method":"tools/list"],ownerCall:{_,_ in throw OwnerReadFault.unavailable})
        let tools=(list["result"] as! [String:Any])["tools"] as! [[String:Any]]
        try validateMioPublishedDescriptors(tools)
        try expect(try jsonBytes(Array(tools.prefix(20)))==jsonBytes(MioReadCatalog.descriptors()),"exact previous twenty descriptors preserved")
        try expect(try jsonBytes(tools.filter { AppleCapability.names.contains($0["name"] as? String ?? "") })==jsonBytes(AppleCapability.descriptors),"two finite Apple tools are actually published")
        try reject("partial published catalog rejected"){try validateMioPublishedDescriptors(Array(tools.filter { $0["name"] as? String != AppleCapability.names.sorted().first }))}
        var altered=tools;altered[altered.count-1]["inputSchema"]=["type":"object"]
        try reject("altered published catalog rejected"){try validateMioPublishedDescriptors(altered)}
        let call:[String:Any]=["jsonrpc":"2.0","id":9,"method":"tools/call","params":["name":AppleCapability.reminderCreate,"arguments":try OwnerReadJSON.object(input,limit:OwnerReadWire.requestLimit)]]
        var forwarded=0
        let mcp=try MioReadOwnerAdapter.respond(call,ownerCall:{name,a in try expect(name==AppleCapability.reminderCreate && a==input,"actual MCP routes exact input");forwarded+=1;return try saved.encoded()})
        let mcpResult=mcp["result"] as! [String:Any],structured=mcpResult["structuredContent"] as! [String:Any]
        let text=(mcpResult["content"] as! [[String:Any]])[0]["text"] as! String
        try expect(forwarded==1 && mcpResult["isError"] as? Bool==false && (try OwnerReadJSON.object(Data(text.utf8),limit:OwnerReadWire.responseLimit))["task_id"] as? String==structured["task_id"] as? String,"MCP text and structured result bind original task")
        let lost=try MioReadOwnerAdapter.respond(call,ownerCall:{_,_ in throw OwnerReadFault.deadline})
        let lostResult=lost["result"] as! [String:Any],lostValue=lostResult["structuredContent"] as! [String:Any]
        try expect(lostResult["isError"] as? Bool==true && lostValue["task_id"] as? String==id && OwnerReadWire.falseBoolean(lostValue["automatic_replay"]) && OwnerReadWire.falseBoolean(lostValue["new_submission_allowed"]),"lost owner response preserves UUID and forbids replay")
        let statusCall:[String:Any]=["jsonrpc":"2.0","id":10,"method":"tools/call","params":["name":AppleCapability.reminderStatus,"arguments":["task_id":id]]]
        let statusLost=try MioReadOwnerAdapter.respond(statusCall,ownerCall:{_,_ in throw OwnerReadFault.deadline})
        let statusValue=(statusLost["result"] as! [String:Any])["structuredContent"] as! [String:Any]
        try expect(statusValue["state"] as? String=="status_unavailable" && statusValue["task_id"] as? String==id,"query failure never claims a save may have occurred")
        var descriptors:[Int32]=[-1,-1];guard socketpair(AF_UNIX,SOCK_STREAM,0,&descriptors)==0 else{throw Failure.assertion("socketpair")}
        let stop=RemindersExchangeCancellation();try stop.attach(descriptors[0]);stop.cancel();var byte:UInt8=0
        try expect(recv(descriptors[1],&byte,1,0)==0,"cancellation wakes real socket reader by shutdown")
        stop.release(descriptors[0]);close(descriptors[0]);close(descriptors[1])
        try reject("cancelled exchange cannot attach later descriptor"){try stop.attach(999)}
        var second:[Int32]=[-1,-1];guard socketpair(AF_UNIX,SOCK_STREAM,0,&second)==0 else{throw Failure.assertion("socketpair")}
        let released=RemindersExchangeCancellation();try released.attach(second[0]);released.release(second[0]);released.cancel()
        byte=42;try expect(send(second[0],&byte,1,0)==1,"late cancellation never shuts down released descriptor")
        close(second[0]);close(second[1])
        print("apple_owner_execution_pass checks=\(checks) real_eventkit_calls=0 real_saves=0 network_calls=0")
    }
}
