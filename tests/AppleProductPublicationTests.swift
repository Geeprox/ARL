import Foundation
import CryptoKit

private final class NoProductEffects:AppleEffects {
    var calls=0
    func authorization(_ operation:AppleOperation)->String {calls+=1;return "full_access"}
    func lockState()->String {calls+=1;return "unlocked"}
    func resolve(_ binding:TargetBinding)throws->ResolvedTarget {calls+=1;return .init(identifier:binding.identifier,name:"Synthetic")}
    func save(_ proposal:AppleProposal,target:ResolvedTarget)throws->String {calls+=1;return "never"}
}
@main enum AppleProductPublicationTests {
    static func main()throws {
        var checks=0
        func expect(_ value:Bool,_ label:String) {precondition(value,label);checks+=1}
        func rejected(_ body:()throws->Void)->Bool {do{try body();return false}catch{return true}}
        let base=try MioReadCatalog.descriptors()
        let list=try MioReadOwnerAdapter.respond(["jsonrpc":"2.0","id":1,"method":"tools/list"],ownerCall:{_,_ in preconditionFailure("catalog contacted owner")})
        let tools=(list["result"] as! [String:Any])["tools"] as! [[String:Any]]
        try validateMioPublishedDescriptors(tools)
        expect(try jsonBytes(Array(tools.prefix(base.count)))==jsonBytes(base),"travel/music catalog preserved")
        expect(Set(tools.compactMap{$0["name"] as? String}).count==tools.count,"unique names")
        expect(AppleProductCapability.names.isSubset(of:Set(tools.compactMap{$0["name"] as? String})),"all new named tools published")
        expect(!tools.contains{$0["name"] as? String==mioCalendarName},"retired v1 not published")
        var changed=tools
        let index=changed.firstIndex{$0["name"] as? String=="mio_messages_read"}!
        changed[index]["description"]="Claims message bodies are readable"
        expect(rejected{try validateMioPublishedDescriptors(changed)},"reject changed capability descriptor")
        let task=UUID().uuidString.lowercased()
        func call(_ name:String,_ args:[String:Any],state:String,code:String,replyTask:String?=nil,overrideResult:[String:Any]?=nil)throws->[String:Any] {
            var calls=0
            let response=try MioReadOwnerAdapter.respond(["jsonrpc":"2.0","id":2,"method":"tools/call","params":["name":name,"arguments":args]],ownerCall:{tool,data in
                calls+=1;expect(tool==name,"exact owner tool")
                expect(try OwnerReadJSON.object(data,limit:OwnerReadWire.requestLimit).keys.sorted()==args.keys.sorted(),"exact argument keys")
                func hash(_ bytes:Data)->String {SHA256.hash(data:bytes).map{String(format:"%02x",$0)}.joined()}
                var receipt:[String:Any]=["synthetic":"retained"]
                if name=="mio_reminders_create_item" {
                    let h=Array(hash(Data(("arl.reminders.product.v1:"+task).utf8)).prefix(32))
                    let op=String(h[0..<8])+"-"+String(h[8..<12])+"-"+String(h[12..<16])+"-"+String(h[16..<20])+"-"+String(h[20..<32])
                    var actual=args;actual.removeValue(forKey:"task_id");actual["operation_id"]=op
                    let request=try JSONSerialization.data(withJSONObject:["tool":"apple.reminders.create.v3","args":actual],options:[.sortedKeys])
                    let saved=try JSONSerialization.data(withJSONObject:["schema_version":3,"status":"ok","operation_id":op,"persistence":"saved_local","cloud_sync":"not_checked","reminder":["id":"synthetic-item"]])
                    receipt=["schema_version":3,"capability_id":"reminders.product.v1","task":["task_id":task,"operation_id":op,"request_json":String(decoding:request,as:UTF8.self),"request_sha256":hash(request),"state":"saved_local"],"result_json":String(decoding:saved,as:UTF8.self)]
                } else if name=="mio_calendar_create" {
                    var request=args;request["action"]="create"
                    let digest=hash(try JSONSerialization.data(withJSONObject:request,options:[.sortedKeys,.withoutEscapingSlashes]))
                    receipt=["task_id":task,"access":"write_only","operation":["task_id":task,"action":"create","digest":digest,"state":state,"code":code,"automatic_replay":false]]
                }
                var value:[String:Any]=["schema_version":1,"capability":"apple.product.v1","tool":name,"state":state,"code":code,"automatic_replay":false,"result":overrideResult ?? receipt]
                if args["task_id"] != nil {value["task_id"]=replyTask ?? task}
                return try OwnerReadWire.encode(value,limit:OwnerReadWire.responseLimit)
            })
            expect(calls==1,"no automatic retry")
            let result=response["result"] as! [String:Any]
            let text=(result["content"] as! [[String:Any]])[0]["text"] as! String
            let structured=result["structuredContent"] as! [String:Any]
            expect(try NSDictionary(dictionary:OwnerReadJSON.object(Data(text.utf8),limit:OwnerReadWire.responseLimit,maximumDepth:32)).isEqual(to:structured),"text and structured agree")
            return result
        }
        expect(try call("mio_reminders_create_item",["task_id":task,"list_id":"synthetic-list","title":"Synthetic"],state:"saved_local",code:"saved_local")["isError"] as? Bool==false,"reminder local save")
        expect(try call("mio_calendar_create",["task_id":task,"draft":[:]],state:"saved_unreadable",code:"saved_without_readback")["isError"] as? Bool==false,"write only qualified")
        let missing=try call("mio_notes_list",[:],state:"unavailable",code:"target_required")
        expect(missing["isError"] as? Bool==true && (missing["structuredContent"] as! [String:Any])["code"] as? String=="target_required","missing target retained")
        let unsupported=try call("mio_messages_read",["chat_id":"synthetic"],state:"unsupported",code:"unsupported_public_api")
        expect(unsupported["isError"] as? Bool==true,"message receive not advertised as success")
        let changedID=try call("mio_reminders_create_item",["task_id":task,"list_id":"synthetic","title":"Synthetic"],state:"saved_local",code:"saved_local",replyTask:UUID().uuidString.lowercased())
        expect(changedID["isError"] as? Bool==true && (changedID["structuredContent"] as! [String:Any])["task_id"] as? String==task,"wrong task retains original unknown")
        let metadataAsWrite=try call("mio_calendar_create",["task_id":task,"draft":[:]],state:"read",code:"ok",overrideResult:["task_id":task,"access":"full_access","events":[]])
        expect(metadataAsWrite["isError"] as? Bool==true && (metadataAsWrite["structuredContent"] as! [String:Any])["state"] as? String=="outcome_unknown","read metadata cannot satisfy mutation")
        let missingReceipt=try call("mio_reminders_create_item",["task_id":task,"list_id":"synthetic-list","title":"Synthetic"],state:"saved_local",code:"saved_local",overrideResult:["schema_version":3,"capability_id":"reminders.product.v1"])
        expect(missingReceipt["isError"] as? Bool==true,"generic save state requires durable receipt")
        let prepareAsSend=try call("mio_messages_send",["task_id":task],state:"prepared",code:"ok",overrideResult:["result":["prepared":["_0":["id":task]]]])
        expect(prepareAsSend["isError"] as? Bool==true,"prepared proposal is not send acceptance")
        let historical:[String:Any]=["task_id":task,"access":"full_access","operation":["task_id":task,"action":"create","digest":String(repeating:"a",count:64),"state":"saved_unreadable","code":"saved_without_readback","automatic_replay":false]]
        let upgraded=try call("mio_calendar_operation_status",["task_id":task],state:"saved_unreadable",code:"saved_without_readback",overrideResult:historical)
        expect(upgraded["isError"] as? Bool==false,"status preserves original unreadable receipt after permission upgrade")
        var ownerCalls=0
        let lost=try MioReadOwnerAdapter.respond(["jsonrpc":"2.0","id":3,"method":"tools/call","params":["name":"mio_messages_send","arguments":["task_id":task]]],ownerCall:{_,_ in ownerCalls+=1;throw OwnerReadFault.deadline})
        let lostValue=(lost["result"] as! [String:Any])["structuredContent"] as! [String:Any]
        expect(ownerCalls==1 && lostValue["task_id"] as? String==task && lostValue["state"] as? String=="outcome_unknown","transport lost does not replace/retry task")
        let home=CommandLine.arguments[1]
        if !FileManager.default.fileExists(atPath:home) {try FileManager.default.createDirectory(atPath:home,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])}
        let journal=try ConsumptionJournal(home:home)
        let effects=NoProductEffects()
        let target=TargetBinding(alias:"synthetic",operation:.calendar,identifier:"synthetic")
        let policy:()->ReviewPolicy?={.init(epoch:1,callers:[mioSubject:.init(operations:[.calendar],targets:[target.alias],nativeReview:false,workflowIssuers:[],maxEffects:1,delegatedTunnel:true)],targets:[target.alias:target],issuerPublicKeys:[:],lockedQualified:[])}
        let consumer=MioCalendarConsumer(engine:.init(journal:journal,policy:policy),effects:effects,policy:policy)
        expect(consumer.descriptor==nil,"v1 sealed grant cannot republish")
        let retired=try consumer.respond(["jsonrpc":"2.0","id":4,"method":"tools/call","params":["name":mioCalendarName,"arguments":[:]]],caller:.fixture(mioSubject),legacy:{_ in preconditionFailure("retired route fell through")})
        let retiredText=((retired["result"] as! [String:Any])["content"] as! [[String:Any]])[0]["text"] as! String
        expect(try OwnerReadJSON.object(Data(retiredText.utf8),limit:4096)["code"] as? String=="calendar_v1_retired","direct v1 explicitly retired")
        expect(effects.calls==0,"retired v1 never reaches permission/metadata/effect")
        print("PASS "+String(checks)+" Apple publication/owner projection checks; real_Apple=0 permissions=0 effects=0")
    }
}
