import Foundation
import Darwin
import ARLRemindersCore

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
        let large=RemindersProductHandler(home:budgetHome.path,identity:identity,policy:String(repeating:"c",count:64),repository:repo,catalog:{.init(sources:largeSources,lists:largeLists)},permission:{"full_access"})
        let limited=large.handle(.init(.catalog),check:{})
        let limitedBytes=try encoder.encode(limited)
        expect(limited.code=="catalog_limit" && limited.catalog==nil && limitedBytes.count<RemindersProductFrame.responseLimit,"valid oversized catalog returns bounded finite error")
        print("PASS "+String(checks)+" Reminders UI-builder/helper/native-boundary checks; UI compiled; real_Apple=0 socket_signature_not_exercised=true")
    }
}
