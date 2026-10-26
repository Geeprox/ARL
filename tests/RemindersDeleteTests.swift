
import Foundation
import ARLRemindersCore

final class DeleteFixture: ReminderRepository {
    let base=FixtureRepository()
    var attempts=0,failAfterDelete=false,badReceipt=false
    var beforeRemove:(() throws->Void)?
    func sources(ids:Set<String>)throws->[ReminderSource]{try base.sources(ids:ids)}
    func lists(ids:Set<String>)throws->[ReminderList]{try base.lists(ids:ids)}
    func createList(title:String,sourceID:String,beforeCommit:()throws->Void)throws->ReminderList{try base.createList(title:title,sourceID:sourceID,beforeCommit:beforeCommit)}
    func query(listID:String,includeCompleted:Bool,dueWindow:DueWindow?,checkRead:()throws->Void)throws->[ReminderSnapshot]{try base.query(listID:listID,includeCompleted:includeCompleted,dueWindow:dueWindow,checkRead:checkRead)}
    func get(id:String,listID:String)throws->ReminderSnapshot{try base.get(id:id,listID:listID)}
    func create(listID:String,title:String,patch:Patch,beforeCommit:()throws->Void)throws->ReminderSnapshot{try base.create(listID:listID,title:title,patch:patch,beforeCommit:beforeCommit)}
    func update(id:String,listID:String,revision:String,patch:Patch?,completed:Bool?,beforeCommit:()throws->Void)throws->ReminderSnapshot{try base.update(id:id,listID:listID,revision:revision,patch:patch,completed:completed,beforeCommit:beforeCommit)}
    func delete(id:String,listID:String,revision:String,beforeCommit:()throws->Void)throws->ReminderDeletion {
        try validateDelete(get(id:id,listID:listID),id:id,listID:listID,revision:revision)
        try beforeRemove?();try beforeCommit()
        try validateDelete(get(id:id,listID:listID),id:id,listID:listID,revision:revision)
        attempts+=1;base.reminderItems.removeAll{$0.id==id && $0.list_id==listID}
        if failAfterDelete {throw AdapterFault("outcome_unknown")}
        return .init(id:badReceipt ? "wrong":id,listID:listID,expectedRevision:revision)
    }
    func seed(_ id:String,recurring:Bool=false)throws->ReminderSnapshot {
        var x=ReminderSnapshot(id:id,listID:"fixture-list",title:"Synthetic deletion")
        if recurring {x.recurrence=RichField(descriptors:[["frequency":"weekly"]])}
        try x.revise();base.reminderItems.append(x);return x
    }
}

@main enum RemindersDeleteTests {
    static func main()throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1])
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        var checks=0
        func expect(_ v:Bool,_ label:String){precondition(v,label);checks+=1}
        func rejects(_ code:String,_ body:()throws->Void) {
            do {try body();preconditionFailure("accepted "+code)}catch let e as AdapterFault{expect(e.code==code,"exact "+code)}catch{preconditionFailure("unexpected error")}
        }
        let repo=DeleteFixture(),id="fixture-delete"
        let item=try repo.seed(id)
        let identity=RemindersFirstIdentity(helper_bundle_id:"local.arl.remindersbridge",executable_sha256:String(repeating:"a",count:64),designated_requirement_sha256:String(repeating:"b",count:64))
        var allowed=true
        func host()->RemindersProductHandler {
            .init(home:root.path,identity:identity,policy:String(repeating:"c",count:64),repository:repo,catalog:{
                .init(sources:repo.base.sourceItems.map{.init(id:$0.id,title:$0.title,type:$0.type)},lists:repo.base.listItems.map{.init(id:$0.id,title:$0.title,source_id:$0.source_id,writable:$0.writable)})
            },permission:{allowed ? "full_access":"denied"})
        }
        func frame(_ item:ReminderSnapshot,task:String=UUID().uuidString.lowercased(),list:String?=nil,revision:String?=nil)throws->RemindersProductFrame {
            let args:[String:Any]=["operation_id":try RemindersProductRequest.operationID(task),"list_id":list ?? item.list_id,"reminder_id":item.id,"expected_revision":revision ?? item.revision]
            let raw=try JSONSerialization.data(withJSONObject:["tool":"apple.reminders.delete.v3","args":args],options:[.sortedKeys])
            _=try RemindersProductRequest.decode(taskID:task,requestJSON:raw)
            return .init(.submit,taskID:task,requestJSON:String(decoding:raw,as:UTF8.self))
        }
        expect(host().handle(.init(.select,sourceID:"fixture-source",listID:"fixture-list"),check:{}).code=="target_selected","selected scope")
        let f=try frame(item)
        let result=host().handle(f,check:{})
        expect(result.task?.state=="saved_local" && result.code=="deleted_local","durable deletion result")
        expect(result.result?.deletion?.id==id && result.result?.deletion?.expected_revision==item.revision,"exact original deletion proof")
        expect(result.result?.persistence=="deleted_local" && result.result?.cloud_sync=="not_checked","local absence never claims sync")
        expect(result.result?.reminder==nil && repo.attempts==1 && repo.base.reminderItems.isEmpty,"single deletion no fabricated live item")
        allowed=false
        let replay=host().handle(f,check:{})
        expect(replay.result_json==result.result_json && repo.attempts==1,"repeat frozen before permission or read")
        expect(host().handle(.init(.status,taskID:f.task_id),check:{}).result_json==result.result_json,"status original receipt")
        let changed=try frame(item,task:f.task_id!,revision:String(repeating:"d",count:64))
        expect(host().handle(changed,check:{}).code=="idempotency_conflict" && repo.attempts==1,"UUID cannot change original revision")
        allowed=true
        let stale=try repo.seed("stale"),staleFrame=try frame(stale,revision:String(repeating:"d",count:64))
        expect(host().handle(staleFrame,check:{}).code=="revision_conflict" && repo.attempts==1,"stale revision zero removal")
        expect(host().handle(staleFrame,check:{}).code=="revision_conflict" && repo.attempts==1,"rejected task does not retry")
        expect(host().handle(try frame(stale,list:"not-selected"),check:{}).code=="target_not_authorized" && repo.attempts==1,"cross-list rejected")
        let recurring=try repo.seed("recurring",recurring:true)
        expect(host().handle(try frame(recurring),check:{}).code=="recurring_delete_unsupported" && repo.attempts==1,"never silently removes recurrence")
        let uncertain=try repo.seed("uncertain"),unknownFrame=try frame(uncertain)
        repo.failAfterDelete=true
        expect(host().handle(unknownFrame,check:{}).task?.state=="unknown" && repo.attempts==2,"post effect unknown frozen")
        repo.failAfterDelete=false
        expect(host().handle(unknownFrame,check:{}).code=="outcome_unknown" && repo.attempts==2,"unknown never replayed after restart")
        let wrong=try repo.seed("receipt"),wrongFrame=try frame(wrong)
        repo.badReceipt=true
        expect(host().handle(wrongFrame,check:{}).code=="outcome_unknown" && repo.attempts==3,"mismatched deletion proof is unknown")
        repo.badReceipt=false
        let raw=Data(f.request_json!.utf8)
        let req=try Request.decode(raw)
        let a=HostAuthority(owner:"synthetic",requestDigest:try digest(req),key:req.args.operation_id!,expires:Date().addingTimeInterval(60),allowedTools:[req.tool],listIDs:["fixture-list"],sourceIDs:["fixture-source"],checkCancelled:{})
        let defaultJournal=root.appendingPathComponent("default-journal")
        let defaultAdapter=RemindersAdapter(repository:FixtureRepository(),journal:try OperationJournal(directory:defaultJournal))
        rejects("delete_not_supported"){_=try defaultAdapter.execute(req,authority:a)}
        rejects("delete_not_supported"){_=try defaultAdapter.execute(req,authority:a)}
        let cancellation=try repo.seed("cancel")
        let cancelReq=try Request.decode(Data(try frame(cancellation).request_json!.utf8))
        var cancelled=false
        repo.beforeRemove={cancelled=true}
        let cancelAuthority=HostAuthority(owner:"synthetic",requestDigest:try digest(cancelReq),key:cancelReq.args.operation_id!,expires:Date().addingTimeInterval(60),allowedTools:[cancelReq.tool],listIDs:["fixture-list"],sourceIDs:["fixture-source"],checkCancelled:{if cancelled{throw AdapterFault("cancelled")}})
        let cancelAdapter=RemindersAdapter(repository:repo,journal:try OperationJournal(directory:root.appendingPathComponent("cancel-journal")))
        rejects("cancelled"){_=try cancelAdapter.execute(cancelReq,authority:cancelAuthority)}
        expect(repo.attempts==3 && repo.base.reminderItems.contains{$0.id==cancellation.id},"revocation before commit zero removal")
        var args=try JSONSerialization.jsonObject(with:raw) as! [String:Any]
        var fields=args["args"] as! [String:Any];fields["patch"]=["title":["action":"set","value":"bad"]];args["args"]=fields
        rejects("invalid_arguments"){_=try Request.decode(JSONSerialization.data(withJSONObject:args))}
        fields.removeValue(forKey:"patch");fields.removeValue(forKey:"expected_revision");args["args"]=fields
        rejects("invalid_arguments"){_=try Request.decode(JSONSerialization.data(withJSONObject:args))}
        print("PASS \(checks) deletion contract/handler checks; EventKitStore=0 permission_requests=0 real_writes=0")
    }
}
