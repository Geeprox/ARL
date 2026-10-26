import Foundation
import ARLRemindersCore

@main struct RemindersProductHandlerTests {
    static func main()throws {
        let fm=FileManager.default
        let root=URL(fileURLWithPath:CommandLine.arguments[1])
        try fm.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        let repo=FixtureRepository()
        let identity=RemindersFirstIdentity(helper_bundle_id:"local.arl.remindersbridge",executable_sha256:String(repeating:"a",count:64),designated_requirement_sha256:String(repeating:"b",count:64))
        var allowed=true
        func handler()->RemindersProductHandler {
            .init(home:root.path,identity:identity,policy:String(repeating:"c",count:64),repository:repo,catalog:{
                .init(sources:repo.sourceItems.map{.init(id:$0.id,title:$0.title,type:$0.type)},
                    lists:repo.listItems.map{.init(id:$0.id,title:$0.title,source_id:$0.source_id,writable:$0.writable)})
            },permission:{allowed ? "full_access":"denied"})
        }
        var count=0
        func expect(_ value:Bool,_ label:String) {
            precondition(value,label);count+=1
        }
        func call(_ frame:RemindersProductFrame)->RemindersProductReply {handler().handle(frame,check:{})}
        func frame(_ op:String,_ args:[String:Any],task:String=UUID().uuidString.lowercased())throws->RemindersProductFrame {
            var args=args
            if RemindersProductRequest.mutations.contains(op) {args["operation_id"]=try RemindersProductRequest.operationID(task)}
            return .init(RemindersProductRequest.mutations.contains(op) ? .submit:.read,taskID:RemindersProductRequest.mutations.contains(op) ? task:nil,
                requestJSON:String(decoding:try JSONSerialization.data(withJSONObject:["tool":"apple.reminders."+op+".v3","args":args],options:[.sortedKeys]),as:UTF8.self))
        }
        expect(call(.init(.catalog)).catalog?.lists.count==1,"metadata catalog")
        expect(repo.saveAttempts==0,"catalog no effects")
        expect(!fm.fileExists(atPath:root.appendingPathComponent("product-v1").path),"catalog no persistence")
        allowed=false
        expect(call(.init(.catalog)).code=="needs_permission","permission does not grant business")
        allowed=true
        expect(call(.init(.select,sourceID:"wrong",listID:"fixture-list")).code=="source_not_found","selected source required")
        expect(call(.init(.select,sourceID:"fixture-source",listID:"fixture-list")).code=="target_selected","select exact target")
        let task=UUID().uuidString.lowercased()
        let patch:[String:Any]=[
            "notes":["action":"set","value":"Synthetic full fields"],
            "priority":["action":"set","value":9],
            "due":["action":"set","value":["kind":"date_time","value":"2099-10-02T09:00:00+08:00","time_zone":"Asia/Shanghai"]],
            "start":["action":"set","value":["kind":"date_time","value":"2099-10-02T08:00:00+08:00","time_zone":"Asia/Shanghai"]],
            "recurrence":["action":"set","value":["frequency":"weekly","interval":2,"count":3]],
            "alert":["action":"set","value":["kind":"relative","offset_seconds":-900]]]
        let create=try frame("create",["list_id":"fixture-list","title":"Synthetic item","patch":patch],task:task)
        let saved=call(create)
        expect(saved.code=="saved_local" && saved.task?.state=="saved_local","saved durable task")
        let item=saved.result!.reminder!
        expect(item.priority==9 && item.notes=="Synthetic full fields" && item.due?.time_zone=="Asia/Shanghai","full fields returned")
        expect(item.recurrence.descriptors.count==1 && item.alerts.descriptors.count==1,"recurrence and alarm")
        expect(repo.saveAttempts==1,"one effect")
        allowed=false
        expect(call(create).result_json==saved.result_json && repo.saveAttempts==1,"repeat reads durable result without permission")
        let changed=try frame("create",["list_id":"fixture-list","title":"Changed"],task:task)
        expect(call(changed).code=="idempotency_conflict" && repo.saveAttempts==1,"body conflict")
        expect(call(.init(.status,taskID:task)).task?.state=="saved_local","status reads task")
        allowed=true
        let edit=try frame("update",["list_id":"fixture-list","reminder_id":item.id,"expected_revision":item.revision,"patch":["title":["action":"set","value":"Edited"],"due":["action":"clear"]]])
        let edited=call(edit).result!.reminder!
        expect(edited.title=="Edited" && edited.due==nil && edited.alerts.descriptors.count==1,"edit preserves unedited fields")
        expect(call(try frame("update",["list_id":"fixture-list","reminder_id":item.id,"expected_revision":item.revision,"patch":["title":["action":"set","value":"Stale"]]])).code=="revision_conflict","revision fence")
        let completed=call(try frame("complete",["list_id":"fixture-list","reminder_id":item.id,"expected_revision":edited.revision])).result!.reminder!
        expect(completed.completed,"complete")
        let reopened=call(try frame("uncomplete",["list_id":"fixture-list","reminder_id":item.id,"expected_revision":completed.revision])).result!.reminder!
        expect(!reopened.completed,"uncomplete")
        let read=call(try frame("get",["list_id":"fixture-list","reminder_id":item.id]))
        expect(read.result?.reminder?.revision==reopened.revision,"get same production adapter")
        expect(call(try frame("query",["list_id":"fixture-list","include_completed":true])).result?.reminders?.count==1,"query")
        expect(call(try frame("create",["list_id":"unselected","title":"No"])).code=="target_not_authorized","arbitrary list rejected")
        repo.failAfterSave=true
        let unknownFrame=try frame("create",["list_id":"fixture-list","title":"Unknown"])
        let unknown=call(unknownFrame)
        expect(unknown.task?.state=="unknown" && unknown.code=="outcome_unknown","post save unknown")
        let afterUnknown=repo.saveAttempts
        repo.failAfterSave=false
        expect(call(unknownFrame).code=="outcome_unknown" && repo.saveAttempts==afterUnknown,"restart never replays unknown")
        expect(call(try frame("create",["list_id":"fixture-list","title":"Independent"])).code=="saved_local","unknown scoped to one task")
        let list=call(try frame("list.create",["source_id":"fixture-source","title":"New list"])).result!.list!
        expect(list.source_id=="fixture-source" && list.writable,"create list in selected source")
        expect(call(.init(.catalog)).catalog?.lists.contains(where:{$0.id==list.id})==true,"catalog includes newly created list")
        expect(call(.init(.select,sourceID:"fixture-source",listID:list.id)).code=="target_selected","explicit select newly created list")
        expect(call(try frame("create",["list_id":"fixture-list","title":"Old target"])).code=="saved_local","default change preserves explicit previous list")
        let encoded=try JSONEncoder().encode(RemindersProductFrame(.status,taskID:task))
        expect(try RemindersProductFrame.decode(encoded).task_id==task,"strict frame roundtrip")
        expect(try RemindersProductRequest.operationID(task)==RemindersProductContract.operationID(task),"UI/helper task namespace identical")
        let taskDir=root.appendingPathComponent("product-v1/tasks")
        let retained=root.appendingPathComponent("product-v1/retained-tasks")
        try fm.moveItem(at:taskDir,to:retained)
        try fm.createDirectory(at:taskDir,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        let saves=repo.saveAttempts
        expect(call(.init(.status,taskID:task)).code=="product_journal_missing_or_replaced","replaced task directory not missing record")
        expect(call(try frame("create",["list_id":list.id,"title":"Must not save"])).code=="product_journal_missing_or_replaced" && repo.saveAttempts==saves,"lost task directory cannot admit effects")
        try fm.removeItem(at:taskDir);try fm.moveItem(at:retained,to:taskDir)
        expect(call(.init(.status,taskID:task)).task?.state=="saved_local","original inode restores original receipt")
        print("PASS "+String(count)+" Reminders product handler checks; EventKit=0 permissions=0 real_writes=0")
    }
}
