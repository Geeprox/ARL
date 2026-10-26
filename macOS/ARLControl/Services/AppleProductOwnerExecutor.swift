import Foundation
import AppKit

@MainActor final class AppleProductOwnerExecutor {
    struct Port {
        let begin:(UUID)->Bool
        let end:(UUID)->Void
        let verify:()throws->Void
        let notesFolder:()->NotesDirectFolder?
        let messagesAccount:()->MessagesDirectAccount?
    }
    let home:URL
    let events:AppleDirectExecutor
    let reminders:RemindersProductController
    let calendar:CalendarBusinessHandler
    let port:Port
    private let confirmation:@MainActor (String,String) async->Bool
    init(home:URL,events:AppleDirectExecutor,reminders:RemindersProductController,calendar:CalendarBusinessHandler,port:Port,
         confirmation:@escaping @MainActor (String,String) async->Bool = {title,details in await AppleProductOwnerExecutor.confirm(title,details)}) {
        self.home=home;self.events=events;self.reminders=reminders;self.calendar=calendar;self.port=port;self.confirmation=confirmation
    }
    func execute(tool:String,argumentsJSON:Data,callID:UUID)async throws->Data {
        var mutationEntered=false
        do{return try await perform(tool:tool,argumentsJSON:argumentsJSON,callID:callID,mutationEntered:&mutationEntered)}
        catch {
            let code=(error as? AppleDirectFault)?.code ?? (error as? NotesDirectCreateFault)?.code ?? (error as? MessagesDirectSendFault)?.code ?? (error as? CalendarBusinessFault)?.code ?? (error as? RemindersTransportFault)?.code ?? (error as? OwnerReadFault)?.rawValue ?? "outcome_unknown"
            let consumed=(error as? NotesDirectCreateFault)?.consumed ?? (error as? MessagesDirectSendFault)?.consumed ?? (error as? CalendarBusinessFault)?.consumed ?? mutationEntered
            var value:[String:Any]=["schema_version":1,"capability":"apple.product.v1","tool":tool,"state":consumed ? "outcome_unknown":"unavailable","code":code,"automatic_replay":false]
            if let args=try? OwnerReadJSON.object(argumentsJSON,limit:OwnerReadWire.requestLimit,maximumDepth:24),let id=args["task_id"] as? String {value["task_id"]=id}
            let log=(error as? AppleDirectFault)?.businessLogAvailable ?? (error as? NotesDirectCreateFault)?.businessLogAvailable ?? (error as? MessagesDirectSendFault)?.businessLogAvailable
                ?? (AppleProductCapability.calendar.contains(tool) ? calendar.businessLogAvailable:AppleProductCapability.reminders.contains(tool) ? reminders.businessLogAvailable:nil)
            if let log {value["business_log_available"]=log}
            if !consumed, let recovery=ApplePublicPrecondition.recovery(tool:tool,code:code,sessionIssue:(error as? AppleDirectFault)?.sessionIssue) {value["recovery"]=recovery}
            return try OwnerReadWire.encode(value,limit:OwnerReadWire.responseLimit-2048)
        }
    }
    private func perform(tool:String,argumentsJSON:Data,callID:UUID,mutationEntered:inout Bool)async throws->Data {
        let args=try AppleProductCapability.arguments(tool:tool,data:argumentsJSON)
        if AppleProductCapability.reminders.contains(tool) {
            let frame:RemindersProductFrame
            if tool=="mio_reminders_catalog" {
                guard args.isEmpty else{throw OwnerReadFault.invalid};frame = .init(.catalog)
            } else if tool=="mio_reminders_product_operation_status" {
                guard Set(args.keys)==["task_id"] else{throw OwnerReadFault.invalid}
                frame = .init(.status,taskID:args["task_id"] as? String)
            } else {
                let names=["mio_reminders_query":"query","mio_reminders_get":"get","mio_reminders_create_list":"list.create","mio_reminders_create_item":"create","mio_reminders_update_item":"update","mio_reminders_complete_item":"complete","mio_reminders_uncomplete_item":"uncomplete","mio_reminders_delete_item":"delete"]
                guard let operation=names[tool] else{throw OwnerReadFault.invalid}
                var input=args;input.removeValue(forKey:"task_id")
                frame=AppleProductCapability.mutations.contains(tool)
                    ? try RemindersProductController.mutationFrame(operation,taskID:args["task_id"] as! String,args:input)
                    : try RemindersProductController.readFrame(operation,args:input)
            }
            if tool == "mio_reminders_delete_item" {
                // Treat the connector schema as documentation, never as input authority.
                // Validate before status/read/confirmation and keep only typed values below.
                try keys(args,["task_id","list_id","reminder_id","expected_revision"])
                guard let taskID=args["task_id"] as? String,RemindersTaskContract.uuid(taskID),
                      let listID=args["list_id"] as? String,let reminderID=args["reminder_id"] as? String,
                      [listID,reminderID].allSatisfy({(1...1024).contains($0.utf8.count) && !$0.unicodeScalars.contains(where:{CharacterSet.controlCharacters.contains($0)})}),
                      let expectedRevision=args["expected_revision"] as? String,
                      expectedRevision.utf8.count == 64,
                      expectedRevision.utf8.allSatisfy({(48...57).contains($0) || (97...102).contains($0)}),
                      let requestJSON=frame.request_json else{throw OwnerReadFault.invalid}
                // Inspect the original task before any current-target read or confirmation.
                // An existing consumed task is never submitted again, even after permission loss.
                let statusFrame=RemindersProductFrame(.status,taskID:taskID)
                let status:RemindersProductReply
                do {status=try await reminders.execute(statusFrame,tool:tool,argumentsJSON:argumentsJSON)}
                catch let error as RemindersTransportFault where error.code == "transport_unavailable" {
                    // Cold service startup uses the ordinary verified read path, never a permission request.
                    let catalog=try await reminders.execute(.init(.catalog),tool:tool,argumentsJSON:argumentsJSON)
                    guard catalog.code == "ok" else{throw RemindersTransportFault(catalog.code)}
                    status=try await reminders.execute(statusFrame,tool:tool,argumentsJSON:argumentsJSON)
                }
                if let prior=status.task {
                    guard let frozen=try JSONSerialization.jsonObject(with:Data(prior.request_json.utf8)) as? NSDictionary,
                          let proposed=try JSONSerialization.jsonObject(with:Data(requestJSON.utf8)) as? NSDictionary,
                          frozen.isEqual(proposed) else{throw RemindersTransportFault("idempotency_conflict")}
                    return try envelope(tool:tool,taskID:frame.task_id,state:prior.state,code:status.code,result:status,businessLogAvailable:status.business_log_available)
                }
                guard status.code == "operation_missing" else{throw RemindersTransportFault(status.code)}
                let read=try RemindersProductController.readFrame("get",args:["list_id":listID,"reminder_id":reminderID])
                let snapshot=try await reminders.execute(read,tool:tool,argumentsJSON:argumentsJSON)
                guard snapshot.code == "ok",let item=snapshot.result?.reminder,let list=snapshot.target?.list,
                      item.id == reminderID,item.list_id == listID,
                      list.id == item.list_id,list.writable,item.revision == expectedRevision
                else{throw RemindersTransportFault(snapshot.code == "ok" ? "revision_conflict":snapshot.code)}
                guard item.recurrence.descriptors.isEmpty else{throw RemindersTransportFault("recurring_delete_unsupported")}
                try AppleDirectAuthority.requireUserSession()
                guard await confirmation("删除提醒事项",list.title+"\n"+item.title+"\n仅删除这一条提醒，可能同步到其他设备。") else{throw AppleDirectFault("user_cancelled")}
                try port.verify();try Task.checkCancellation();try AppleDirectAuthority.requireUserSession()
            }
            mutationEntered=frame.action == .submit
            let reply=try await reminders.execute(frame,tool:tool,argumentsJSON:argumentsJSON)
            return try envelope(tool:tool,taskID:frame.task_id,state:reply.task?.state ?? reply.outcome,code:reply.code,result:reply,businessLogAvailable:reply.business_log_available)
        }
        guard port.begin(callID) else{throw OwnerReadFault.busy}
        defer{port.end(callID)}
        try port.verify()
        if AppleProductCapability.calendar.contains(tool) {
            mutationEntered=AppleProductCapability.mutations.contains(tool)
            let reply=try await calendar.execute(tool:tool,argumentsJSON:argumentsJSON)
            return try envelope(tool:tool,taskID:reply.task_id,state:reply.operation?.state.rawValue ?? (reply.code=="ok" ? "read":"unavailable"),code:reply.operation?.code ?? reply.code,result:reply,businessLogAvailable:reply.businessLogAvailable)
        }
        if AppleProductCapability.notes.contains(tool) {
            // Check the existing session before any write confirmation can appear.
            // AppleDirectSession repeats this check before every native event.
            try AppleDirectAuthority.requireUserSession()
            let folder=port.notesFolder()
            let scope=folder.map{NotesDirectScope(folder:$0,expires:Date().addingTimeInterval(600))}
            let request:NotesDirectRequest
            switch tool {
            case "mio_notes_folders":
                try keys(args,[]);request = .folders
            case "mio_notes_list":
                guard Set(args.keys).isSubset(of:["offset","limit"]),let scope else{throw AppleDirectFault("target_required")}
                request = .page(scope:scope,query:"",offset:try pageInteger(args["offset"],default:0,maximum:Int.max),limit:try pageInteger(args["limit"],default:50,maximum:50))
            case "mio_notes_search":
                guard Set(args.keys).isSubset(of:["query","offset","limit"]),let scope else{throw AppleDirectFault("target_required")}
                guard let query=args["query"] as? String else{throw OwnerReadFault.invalid}
                request = .page(scope:scope,query:query,offset:try pageInteger(args["offset"],default:0,maximum:Int.max),limit:try pageInteger(args["limit"],default:50,maximum:50))
            case "mio_notes_read":
                guard Set(args.keys).isSubset(of:["row","offset","max_bytes"]),args["row"] != nil else{throw AppleDirectFault("invalid_arguments")};guard let scope else{throw AppleDirectFault("target_required")};request = .readPage(scope:scope,row:try decode(NotesDirectRow.self,args["row"]),offset:try pageInteger(args["offset"],default:0,maximum:Int.max),maxBytes:try pageInteger(args["max_bytes"],default:8192,maximum:8192))
            case "mio_notes_create":
                try keys(args,["task_id","title","plaintext"])
                guard let scope else{throw AppleDirectFault("target_required")}
                guard let title=args["title"] as? String,let text=args["plaintext"] as? String else{throw OwnerReadFault.invalid}
                guard await confirmation("创建备忘录",scope.folder.label+"\n"+title+"\n\n"+text) else{throw AppleDirectFault("user_cancelled")}
                try port.verify();guard port.notesFolder()==folder else{throw AppleDirectFault("target_changed")}
                let proposal=NotesDirectProposal(id:UUID(uuidString:args["task_id"] as! String)!,scope:scope,title:title,plaintext:text,expires:Date().addingTimeInterval(120))
                request = .create(proposal:proposal,expectedDigest:proposal.digest)
            case "mio_notes_update":
                try keys(args,["task_id","row","source_body_digest","title","plaintext"])
                guard let scope else{throw AppleDirectFault("target_required")}
                guard let title=args["title"] as? String,let text=args["plaintext"] as? String,let hash=args["source_body_digest"] as? String else{throw OwnerReadFault.invalid}
                let row=try decode(NotesDirectRow.self,args["row"])
                guard await confirmation("修改备忘录",scope.folder.label+"\n"+row.title+" → "+title+"\n\n"+text) else{throw AppleDirectFault("user_cancelled")}
                try port.verify();guard port.notesFolder()==folder else{throw AppleDirectFault("target_changed")}
                let proposal=NotesDirectEditProposal(id:UUID(uuidString:args["task_id"] as! String)!,scope:scope,row:row,sourceBodyDigest:hash,title:title,plaintext:text,expires:Date().addingTimeInterval(120))
                request = .update(proposal:proposal,expectedDigest:proposal.digest)
            case "mio_notes_delete":
                try keys(args,["task_id","row","source_body_digest"])
                guard let scope else{throw AppleDirectFault("target_required")}
                guard let hash=args["source_body_digest"] as? String else{throw OwnerReadFault.invalid}
                let row=try decode(NotesDirectRow.self,args["row"])
                let proposal=NotesDirectDeleteProposal(id:UUID(uuidString:args["task_id"] as! String)!,scope:scope,row:row,sourceBodyDigest:hash,expires:Date().addingTimeInterval(120))
                try proposal.validate()
                guard await confirmation("删除备忘录",scope.folder.label+"\n"+row.title+"\n仅删除这一条备忘录，可能同步到其他设备。") else{throw AppleDirectFault("user_cancelled")}
                try port.verify();try Task.checkCancellation();try AppleDirectAuthority.requireUserSession()
                guard port.notesFolder()==folder else{throw AppleDirectFault("target_changed")}
                request = .delete(proposal:proposal,expectedDigest:proposal.digest)
            default:throw OwnerReadFault.unsupported
            }
            mutationEntered=AppleProductCapability.mutations.contains(tool)
            let stop=AppleDirectCancellation(),home=home
            let reply=try await withTaskCancellationHandler(operation:{
                try await events.run {
                    let session=try AppleDirectSession(target:.notes,stop:stop,expires:Date().addingTimeInterval(120))
                    return try NotesDirectHandler(home:home,backend:NotesDirectBackend(session:session),selectedFolder:folder).handle(request)
                }
            },onCancel:{stop.cancel()})
            let deleted=tool == "mio_notes_delete"
            return try envelope(tool:tool,taskID:args["task_id"] as? String,state:deleted ? "deleted_local":AppleProductCapability.mutations.contains(tool) ? "saved_local":"read",code:deleted ? "deleted_local":"ok",result:reply,businessLogAvailable:reply.businessLogAvailable)
        }
        guard AppleProductCapability.messages.contains(tool) else{throw OwnerReadFault.unsupported}
        let account=port.messagesAccount()
        let request:MessagesDirectRequest
        switch tool {
        case "mio_messages_accounts":try keys(args,[]);request = .accounts
        case "mio_messages_chats":
            guard let account else{throw AppleDirectFault("target_required")}
            guard Set(args.keys).isSubset(of:["query"]),args["query"] == nil || args["query"] is String else{throw OwnerReadFault.invalid}
            request = .chats(account:account,query:args["query"] as? String ?? "")
        case "mio_messages_prepare_send":
            try keys(args,["task_id","address","plaintext"])
            guard let account else{throw AppleDirectFault("target_required")}
            guard let address=args["address"] as? String,let text=args["plaintext"] as? String else{throw OwnerReadFault.invalid}
            request = .prepareSend(id:UUID(uuidString:args["task_id"] as! String)!,account:account,address:address,plaintext:text)
        case "mio_messages_send":
            try keys(args,["task_id","proposal","expected_digest"])
            guard let account else{throw AppleDirectFault("target_required")}
            guard let expected=args["expected_digest"] as? String else{throw OwnerReadFault.invalid}
            let proposal=try decode(MessagesDirectProposal.self,args["proposal"])
            guard proposal.id.uuidString.lowercased()==args["task_id"] as? String,proposal.recipient.account==account else{throw AppleDirectFault("account_changed")}
            try proposal.validate()
            guard proposal.digest==expected else{throw AppleDirectFault("proposal_changed")}
            guard await confirmation("发送信息",account.label+"\n"+proposal.recipient.handle+"\n\n"+proposal.plaintext) else{throw AppleDirectFault("user_cancelled")}
            try port.verify();guard port.messagesAccount()==account else{throw AppleDirectFault("account_changed")}
            request = .send(proposal:proposal,expectedDigest:expected)
        case "mio_messages_read":
            try keys(args,["chat_id"]);guard let account else{throw AppleDirectFault("target_required")}
            guard let id=args["chat_id"] as? String else{throw OwnerReadFault.invalid};request = .read(account:account,chatID:id)
        default:throw OwnerReadFault.unsupported
        }
        mutationEntered=AppleProductCapability.mutations.contains(tool)
        let stop=AppleDirectCancellation(),home=home
        let reply=try await withTaskCancellationHandler(operation:{
            try await events.run {
                let session=try AppleDirectSession(target:.messages,stop:stop,expires:Date().addingTimeInterval(120))
                return try MessagesDirectHandler(home:home,backend:MessagesDirectBackend(session:session),selectedAccount:account).handle(request)
            }
        },onCancel:{stop.cancel()})
        var state="read",code="ok"
        switch reply.result {
        case .accepted:state="accepted_local"
        case .prepared:state="prepared"
        case .unsupported(let reason,_):state="unsupported";code=reason
        default:break
        }
        let encoded=try envelope(tool:tool,taskID:args["task_id"] as? String,state:state,code:code,result:reply,businessLogAvailable:reply.businessLogAvailable)
        if case .prepared(let proposal)=reply.result {
            var value=try OwnerReadJSON.object(encoded,limit:OwnerReadWire.responseLimit,maximumDepth:32)
            value["prepared_digest"]=proposal.digest
            return try OwnerReadWire.encode(value,limit:OwnerReadWire.responseLimit-2048)
        }
        return encoded
    }
    private func envelope<T:Encodable>(tool:String,taskID:String?,state:String,code:String,result:T,businessLogAvailable:Bool?=nil)throws->Data {
        var value:[String:Any]=["schema_version":1,"capability":"apple.product.v1","tool":tool,"state":state,"code":code,"automatic_replay":false,
            "result":try JSONSerialization.jsonObject(with:JSONEncoder().encode(result))]
        if let taskID{value["task_id"]=taskID}
        if let businessLogAvailable{value["business_log_available"]=businessLogAvailable}
        if !["outcome_unknown","unknown","pending"].contains(state), let recovery=ApplePublicPrecondition.recovery(tool:tool,code:code) {value["recovery"]=recovery}
        return try OwnerReadWire.encode(value,limit:OwnerReadWire.responseLimit-2048)
    }
    private func pageInteger(_ raw:Any?,default fallback:Int,maximum:Int)throws->Int {
        guard let raw else{return fallback}
        guard let n=raw as? NSNumber,CFGetTypeID(n) != CFBooleanGetTypeID(),let value=Int(n.stringValue),value>=0,value<=maximum
        else {throw OwnerReadFault.invalid};return value
    }
    private func keys(_ args:[String:Any],_ expected:Set<String>)throws {
        guard Set(args.keys)==expected else{throw OwnerReadFault.invalid}
    }
    private func decode<T:Codable>(_ type:T.Type,_ value:Any?)throws->T {
        guard let value else{throw OwnerReadFault.invalid}
        let result=try JSONDecoder().decode(type,from:JSONSerialization.data(withJSONObject:value))
        guard (value as? NSDictionary)?.isEqual(try JSONSerialization.jsonObject(with:JSONEncoder().encode(result)))==true else{throw OwnerReadFault.invalid}
        return result
    }
    static func confirm(_ title:String,_ details:String)async->Bool {
        let alert=NSAlert();alert.messageText=title;alert.informativeText=details
        alert.addButton(withTitle:"确认");alert.addButton(withTitle:"取消")
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:560,height:180),styleMask:[.titled],backing:.buffered,defer:false)
        window.title="ARL";window.center();window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps:true)
        defer{window.orderOut(nil)}
        return await withTaskCancellationHandler(operation:{
            await withCheckedContinuation{continuation in alert.beginSheetModal(for:window){continuation.resume(returning:$0 == .alertFirstButtonReturn)}}
        },onCancel:{Task{@MainActor in if let sheet=window.attachedSheet{window.endSheet(sheet,returnCode:.alertSecondButtonReturn)}}})
    }
}
