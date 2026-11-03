import Foundation
import Darwin
import ARLRemindersCore

private final class BoundaryDeleteRepository: ReminderRepository {
    let base = FixtureRepository()
    var deletions = 0
    func sources(ids:Set<String>) throws -> [ReminderSource] { try base.sources(ids:ids) }
    func lists(ids:Set<String>) throws -> [ReminderList] { try base.lists(ids:ids) }
    func createList(title:String,sourceID:String,beforeCommit:()throws->Void) throws -> ReminderList { try base.createList(title:title,sourceID:sourceID,beforeCommit:beforeCommit) }
    func query(listID:String,includeCompleted:Bool,dueWindow:DueWindow?,checkRead:()throws->Void) throws -> [ReminderSnapshot] { try base.query(listID:listID,includeCompleted:includeCompleted,dueWindow:dueWindow,checkRead:checkRead) }
    func get(id:String,listID:String) throws -> ReminderSnapshot { try base.get(id:id,listID:listID) }
    func create(listID:String,title:String,patch:Patch,beforeCommit:()throws->Void) throws -> ReminderSnapshot { try base.create(listID:listID,title:title,patch:patch,beforeCommit:beforeCommit) }
    func update(id:String,listID:String,revision:String,patch:Patch?,completed:Bool?,beforeCommit:()throws->Void) throws -> ReminderSnapshot { try base.update(id:id,listID:listID,revision:revision,patch:patch,completed:completed,beforeCommit:beforeCommit) }
    func delete(id:String,listID:String,revision:String,beforeCommit:()throws->Void) throws -> ReminderDeletion {
        try validateDelete(get(id:id,listID:listID),id:id,listID:listID,revision:revision)
        try beforeCommit()
        try validateDelete(get(id:id,listID:listID),id:id,listID:listID,revision:revision)
        deletions += 1; base.reminderItems.removeAll { $0.id == id && $0.list_id == listID }
        return .init(id:id,listID:listID,expectedRevision:revision)
    }
}

@MainActor @main enum RemindersProductBoundaryTests {
    static func main()throws {
        var checks=0
        func expect(_ value:Bool,_ label:String) {precondition(value,label);checks+=1}
        func rejects(_ body:()throws->Void)->Bool {do{try body();return false}catch{return true}}
        let root=URL(fileURLWithPath:CommandLine.arguments[1])
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        let repo=FixtureRepository()
        let identity=RemindersFirstIdentity(helper_bundle_id:"local.arl.remindersbridge",executable_sha256:String(repeating:"a",count:64),designated_requirement_sha256:String(repeating:"b",count:64))
        var permissionReads=0,allowed=true
        let handler=RemindersProductHandler(home:root.path,identity:identity,policy:String(repeating:"c",count:64),repository:repo,catalog:{
            .init(sources:repo.sourceItems.map{.init(id:$0.id,title:$0.title,type:$0.type)},lists:repo.listItems.map{.init(id:$0.id,title:$0.title,source_id:$0.source_id,writable:$0.writable)})
        },permission:{permissionReads+=1;return allowed ? "full_access":"denied"})
        let deployment=RemindersNativeDeployment(schema_version:1,helper_bundle_path:"/synthetic/ARLRemindersBridge.app",host_home:root.path,
            control_requirement:RemindersStablePeerIdentity.controlRequirement,helper_requirement:RemindersStablePeerIdentity.helperRequirement,
            helper_executable_sha256:identity.executable_sha256,helper_designated_requirement_sha256:identity.designated_requirement_sha256,
            closure_sha256:String(repeating:"d",count:64),policy_sha256:String(repeating:"c",count:64))
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        let selected=handler.handle(.init(.select,sourceID:"fixture-source",listID:"fixture-list"),check:{})
        expect(selected.code=="target_selected","same helper target selection")
        let task=UUID().uuidString.lowercased()
        let notes=String(repeating:"\"",count:4096)
        let patch:[String:Any]=["notes":["action":"set","value":notes],"priority":["action":"set","value":9],
            "due":["action":"set","value":["kind":"date_time","value":"2099-10-02T09:00:00+08:00","time_zone":"Asia/Shanghai"]],
            "start":["action":"set","value":["kind":"date_time","value":"2099-10-02T08:00:00+08:00","time_zone":"Asia/Shanghai"]],
            "recurrence":["action":"set","value":["frequency":"weekly","interval":2,"count":3]],"alert":["action":"set","value":["kind":"relative","offset_seconds":-900]]]
        let frame=try RemindersProductController.mutationFrame("create",taskID:task,args:["list_id":"fixture-list","title":"Synthetic full consumer","patch":patch])
        let input=try encoder.encode(frame)
        expect(input.count>16384 && input.count<=RemindersProductFrame.requestLimit,"maximum escaped field fits product-only request budget")
        expect(rejects{_ = try RemindersNativeIO.flatObject(input)},"old flat protocol retains 16KiB budget")
        let admittedFrame=try RemindersProductFrame.decode(input)
        let core=try RemindersProductRequest.decode(taskID:task,requestJSON:Data(admittedFrame.request_json!.utf8))
        expect(core.request.args.patch?.due?.value?.time_zone=="Asia/Shanghai" && core.request.args.patch?.alert?.value?.offset_seconds == -900,"UI builder preserves full fields")
        let raw=handler.handle(admittedFrame,check:{})
        let wire=try encoder.encode(raw)
        expect(wire.count>16384 && wire.count<=262144,"full saved result fits product-only response budget")
        let accepted=try RemindersNativeClient.admitProductReply(wire,for:frame,deployment:deployment)
        expect(accepted.result?.reminder?.notes==notes && accepted.result?.reminder?.priority==9,"native DTO preserves complete result")
        expect(accepted.result?.reminder?.recurrence.descriptors.count==1 && accepted.result?.reminder?.alerts.descriptors.count==1,"native recurrence/alarm result preserved")
        let productArgs:[String:Any]=["task_id":task,"list_id":"fixture-list","title":"Synthetic full consumer","patch":patch]
        let projected=try MioReadOwnerAdapter.respond(["jsonrpc":"2.0","id":11,"method":"tools/call","params":["name":"mio_reminders_create_item","arguments":productArgs]],ownerCall:{_,_ in
            try OwnerReadWire.encode(["schema_version":1,"capability":"apple.product.v1","tool":"mio_reminders_create_item","task_id":task,"state":"saved_local","code":"saved_local","automatic_replay":false,"result":JSONSerialization.jsonObject(with:wire)],limit:OwnerReadWire.responseLimit-2048)
        })
        expect((projected["result"] as? [String:Any])?["isError"] as? Bool==false,"actual helper/native receipt admitted by actual Mio consumer")
        expect(accepted.task?.result_json==nil && accepted.result_json != nil,"wire does not duplicate full result")
        expect(try handler.record(task)?.result_json != nil,"durable record retains complete result")
        expect(repo.saveAttempts==1,"one fixture effect")
        var changed=try JSONSerialization.jsonObject(with:wire) as! [String:Any]
        var forgedIdentity=changed["identity"] as! [String:Any];forgedIdentity["executable_sha256"]=String(repeating:"e",count:64);changed["identity"]=forgedIdentity
        expect(rejects{_ = try RemindersNativeClient.admitProductReply(JSONSerialization.data(withJSONObject:changed),for:frame,deployment:deployment)},"wrong helper evidence rejected")
        allowed=false
        let reads=permissionReads
        let selectionFrame=RemindersProductFrame(.selection)
        let selection=handler.handle(selectionFrame,check:{})
        let acceptedSelection=try RemindersNativeClient.admitProductReply(encoder.encode(selection),for:selectionFrame,deployment:deployment)
        expect(acceptedSelection.target?.list?.id=="fixture-list" && permissionReads==reads,"visible page restores stored target without permission or metadata reads")
        let historyFrame=RemindersProductFrame(.history,offset:0)
        let history=handler.handle(try RemindersProductFrame.decode(encoder.encode(historyFrame)),check:{})
        let acceptedHistory=try RemindersNativeClient.admitProductReply(encoder.encode(history),for:historyFrame,deployment:deployment)
        expect(acceptedHistory.history?.first?.task_id==task && acceptedHistory.history?.first?.state=="saved_local","history reconstructs durable original task")
        expect(permissionReads==reads && repo.saveAttempts==1,"history does not probe permission or execute")
        let statusFrame=RemindersProductFrame(.status,taskID:task)
        let status=handler.handle(statusFrame,check:{})
        let acceptedStatus=try RemindersNativeClient.admitProductReply(encoder.encode(status),for:statusFrame,deployment:deployment)
        expect(acceptedStatus.result?.reminder?.notes==notes && repo.saveAttempts==1,"original task status retains full result without replay")
        expect(permissionReads==reads,"status does not probe permission")
        let malformed=RemindersProductReply(schema_version:3,capability_id:"reminders.product.v1",request_id:historyFrame.request_id,action:.history,identity:identity,policy_sha256:String(repeating:"c",count:64),outcome:"refreshed",code:"ok")
        expect(rejects{_ = try RemindersNativeClient.admitProductReply(encoder.encode(malformed),for:historyFrame,deployment:deployment)},"missing history payload rejected")
        expect(!RemindersProductCopy.message(acceptedSelection).contains("未完成"),"selection restoration has success copy")
        // Exercise the production encoded DTO boundary on both first submit
        // and its original status, rather than injecting a decoded reply.
        let deleteHome = root.appendingPathComponent("delete-wire")
        try FileManager.default.createDirectory(at:deleteHome,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        let deleteRepo = BoundaryDeleteRepository()
        var item = ReminderSnapshot(id:"synthetic-delete-wire",listID:"fixture-list",title:"Synthetic wire deletion")
        try item.revise(); deleteRepo.base.reminderItems.append(item)
        let deleteHelper = RemindersProductHandler(home:deleteHome.path,identity:identity,policy:String(repeating:"c",count:64),repository:deleteRepo,catalog:{
            .init(sources:deleteRepo.base.sourceItems.map{.init(id:$0.id,title:$0.title,type:$0.type)},
                lists:deleteRepo.base.listItems.map{.init(id:$0.id,title:$0.title,source_id:$0.source_id,writable:$0.writable)})
        },permission:{"full_access"})
        let deleteTask = UUID().uuidString.lowercased()
        let deleteFrame = try RemindersProductController.mutationFrame("delete",taskID:deleteTask,
            args:["list_id":item.list_id,"reminder_id":item.id,"expected_revision":item.revision])
        let deleteSubmit = deleteHelper.handle(deleteFrame,check:{})
        let deleted = try RemindersNativeClient.admitProductReply(encoder.encode(deleteSubmit),for:deleteFrame,deployment:deployment)
        expect(deleted.code=="deleted_local" && deleted.result?.persistence=="deleted_local" && deleted.result?.deletion?.id==item.id,
            "first real helper deletion passes native encoded admission")
        let deleteStatusFrame = RemindersProductFrame(.status,taskID:deleteTask)
        let deleteStatus = deleteHelper.handle(deleteStatusFrame,check:{})
        let observed = try RemindersNativeClient.admitProductReply(encoder.encode(deleteStatus),for:deleteStatusFrame,deployment:deployment)
        expect(observed.result_json==deleted.result_json && deleteRepo.deletions==1 && deleteRepo.base.reminderItems.isEmpty,
            "original deleted status passes same gate without replay")
        for (response,requestFrame) in [(deleteSubmit,deleteFrame),(deleteStatus,deleteStatusFrame)] {
            let original = try JSONSerialization.jsonObject(with:encoder.encode(response)) as! [String:Any]
            func altered(_ change:(inout [String:Any],inout [String:Any],inout [String:Any])->Void) throws -> Data {
                var value=original,task=value["task"] as! [String:Any]
                var result=try JSONSerialization.jsonObject(with:Data((value["result_json"] as! String).utf8)) as! [String:Any]
                change(&value,&task,&result)
                value["task"]=task;value["result_json"]=String(decoding:try JSONSerialization.data(withJSONObject:result,options:[.sortedKeys]),as:UTF8.self)
                return try JSONSerialization.data(withJSONObject:value)
            }
            let wrongPersistence=try altered { _,_,result in result["persistence"]="saved_local" }
            expect(rejects{_ = try RemindersNativeClient.admitProductReply(wrongPersistence,for:requestFrame,deployment:deployment)},"delete never accepts saved_local persistence")
            for field in ["id","list_id","expected_revision"] {
                let wrong=try altered { _,_,result in var proof=result["deletion"] as! [String:Any];proof[field]="wrong";result["deletion"]=proof }
                expect(rejects{_ = try RemindersNativeClient.admitProductReply(wrong,for:requestFrame,deployment:deployment)},"delete proof exact "+field)
            }
            for code in ["ok","saved_local","outcome_unknown"] {
                let wrong=try altered { value,task,_ in value["code"]=code;task["code"]=code }
                expect(rejects{_ = try RemindersNativeClient.admitProductReply(wrong,for:requestFrame,deployment:deployment)},"delete rejects unrelated code "+code)
            }
            let wrongTarget=try altered { _,task,_ in var target=task["target"] as! [String:Any];var list=target["list"] as! [String:Any];list["id"]="wrong-list";target["list"]=list;task["target"]=target }
            expect(rejects{_ = try RemindersNativeClient.admitProductReply(wrongTarget,for:requestFrame,deployment:deployment)},"delete frozen target must match original list")
            let wrongReplyTarget=try altered { value,task,_ in var target=task["target"] as! [String:Any];var list=target["list"] as! [String:Any];list["id"]="wrong-reply-list";target["list"]=list;value["target"]=target }
            expect(rejects{_ = try RemindersNativeClient.admitProductReply(wrongReplyTarget,for:requestFrame,deployment:deployment)},"delete response target must match frozen target")
            let badHash=try altered { _,task,_ in task["request_sha256"]=String(repeating:"0",count:64) }
            expect(rejects{_ = try RemindersNativeClient.admitProductReply(badHash,for:requestFrame,deployment:deployment)},"delete frozen request hash cannot change")
            let wrongOperation=try altered { _,_,result in result["operation_id"]=UUID().uuidString.lowercased() }
            expect(rejects{_ = try RemindersNativeClient.admitProductReply(wrongOperation,for:requestFrame,deployment:deployment)},"delete receipt operation cannot change")
            let noDeletion=try altered { _,_,result in result.removeValue(forKey:"deletion") }
            expect(rejects{_ = try RemindersNativeClient.admitProductReply(noDeletion,for:requestFrame,deployment:deployment)},"delete must carry absence proof")
            let inventedItem=try altered { _,_,result in result["reminder"]=try! JSONSerialization.jsonObject(with:JSONEncoder().encode(accepted.result!.reminder!)) }
            expect(rejects{_ = try RemindersNativeClient.admitProductReply(inventedItem,for:requestFrame,deployment:deployment)},"delete never fabricates a live reminder")
            if requestFrame.action == .submit {
                var changedFrame=requestFrame
                var request=try JSONSerialization.jsonObject(with:Data(requestFrame.request_json!.utf8)) as! [String:Any]
                var args=request["args"] as! [String:Any];args["reminder_id"]="another-submitted-id";request["args"]=args
                changedFrame.request_json=String(decoding:try JSONSerialization.data(withJSONObject:request),as:UTF8.self)
                expect(rejects{_ = try RemindersNativeClient.admitProductReply(encoder.encode(response),for:changedFrame,deployment:deployment)},"delete reply cannot satisfy a different original submitted intent")
            }
        }
        var createAsDelete=try JSONSerialization.jsonObject(with:wire) as! [String:Any]
        var createResult=try JSONSerialization.jsonObject(with:Data((createAsDelete["result_json"] as! String).utf8)) as! [String:Any]
        createResult["persistence"]="deleted_local";createAsDelete["result_json"]=String(decoding:try JSONSerialization.data(withJSONObject:createResult),as:UTF8.self)
        expect(rejects{_ = try RemindersNativeClient.admitProductReply(JSONSerialization.data(withJSONObject:createAsDelete),for:frame,deployment:deployment)},"old create remains saved_local-only")
        func lineFixture(_ length:Int)throws->Data? {
            var pair:[Int32]=[0,0]
            guard socketpair(AF_UNIX,SOCK_STREAM,0,&pair)==0 else{throw RemindersTransportFault("fixture_socket")}
            defer{close(pair[0]);close(pair[1])}
            var bytes=Data(repeating:65,count:length);bytes.append(10)
            _=bytes.withUnsafeBytes{write(pair[0],$0.baseAddress!,$0.count)}
            return try RemindersNativeIO.line(pair[1],limit:64,seconds:1)
        }
        expect(try lineFixture(64)?.count==64,"exact byte limit consumes trailing newline")
        expect(rejects{_ = try lineFixture(65)},"one extra payload byte rejected")
        let budgetHome=root.appendingPathComponent("catalog-budget")
        try FileManager.default.createDirectory(at:budgetHome,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        let largeSources=(0..<100).map{RemindersProductSource(id:String($0)+String(repeating:"s",count:900),title:String(repeating:"t",count:1000),type:0)}
        let largeLists=(0..<200).map{RemindersProductList(id:String($0)+String(repeating:"l",count:900),title:String(repeating:"u",count:1000),source_id:largeSources[$0%100].id,writable:true)}
        let largeRepository=FixtureRepository()
        largeRepository.sourceItems=largeSources.map{.init(id:$0.id,title:$0.title,type:$0.type)}
        largeRepository.listItems=largeLists.map{.init(id:$0.id,title:$0.title,sourceID:$0.source_id,writable:$0.writable)}
        let large=RemindersProductHandler(home:budgetHome.path,identity:identity,policy:String(repeating:"c",count:64),repository:largeRepository,catalog:{.init(sources:largeSources,lists:largeLists)},permission:{"full_access"})
        let limited=large.handle(.init(.catalog),check:{})
        let limitedBytes=try encoder.encode(limited)
        expect(limited.code=="catalog_limit" && limited.catalog==nil && limitedBytes.count<RemindersProductFrame.responseLimit,"valid oversized catalog returns bounded finite error")
        print("PASS "+String(checks)+" Reminders UI-builder/helper/native-boundary checks; UI compiled; real_Apple=0 socket_signature_not_exercised=true")
    }
}
