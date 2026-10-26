import Foundation
import Darwin
import ARLRemindersCore

/// The existing signed helper owns this handler. UI and Mio use the same socket
/// and OS-authorized catalog. A saved default is a preference, never a scope grant.
final class RemindersProductHandler: @unchecked Sendable {
    let home:String
    let identity:RemindersFirstIdentity
    let policy:String
    let repository:any ReminderRepository
    let catalogAccess:()throws->RemindersProductCatalog
    let permission:()->String
    private let encoder:JSONEncoder
    init(home:String,identity:RemindersFirstIdentity,policy:String,repository:any ReminderRepository,
         catalog:@escaping()throws->RemindersProductCatalog,permission:@escaping()->String) {
        self.home=home;self.identity=identity;self.policy=policy;self.repository=repository;catalogAccess=catalog;self.permission=permission
        encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
    }
    private var root:String {home+"/product-v1"}
    private var targetPath:String {root+"/target.json"}
    private func ensureRoot()throws {_=try verifyRoot(create:true)}
    private func verifyRoot(create:Bool=false)throws->Bool {
        try RemindersNativeIO.privateDirectory(home)
        let anchor=home+"/product-v1.anchor"
        var dir=stat(),mark=stat(),tasks=stat()
        let hasDir=lstat(root,&dir)==0,dirError=errno
        let hasMark=lstat(anchor,&mark)==0,markError=errno
        guard hasDir || dirError==ENOENT,hasMark || markError==ENOENT,hasDir==hasMark else{throw RemindersTransportFault("product_journal_missing_or_replaced")}
        if !hasDir {
            guard create else{return false}
            guard mkdir(root,0o700)==0,mkdir(root+"/tasks",0o700)==0,lstat(root,&dir)==0,lstat(root+"/tasks",&tasks)==0 else{throw RemindersTransportFault("unsafe_home")}
            let binding=Data(("v1\n"+String(dir.st_dev)+"\n"+String(dir.st_ino)+"\n"+String(tasks.st_dev)+"\n"+String(tasks.st_ino)+"\n").utf8)
            try RemindersNativeIO.writeNew(binding,to:anchor)
        }
        try RemindersNativeIO.privateDirectory(root);try RemindersNativeIO.privateDirectory(root+"/tasks")
        guard lstat(root,&dir)==0,lstat(root+"/tasks",&tasks)==0 else{throw RemindersTransportFault("unsafe_home")}
        let binding=Data(("v1\n"+String(dir.st_dev)+"\n"+String(dir.st_ino)+"\n"+String(tasks.st_dev)+"\n"+String(tasks.st_ino)+"\n").utf8)
        guard try RemindersNativeIO.privateFile(anchor)==binding else{throw RemindersTransportFault("product_journal_missing_or_replaced")}
        return true
    }
    private func path(_ id:String)throws->String {
        guard RemindersTaskContract.uuid(id) else{throw RemindersTransportFault("invalid_product_task_id")}
        return root+"/tasks/"+id+".json"
    }
    func record(_ id:String)throws->RemindersProductRecord? {
        let file=try path(id)
        guard try verifyRoot() else{return nil}
        guard access(file,F_OK)==0 else{return nil}
        let record=try JSONDecoder().decode(RemindersProductRecord.self,from:RemindersNativeIO.privateFile(file,limit:180_000))
        let request=try RemindersProductRequest.decode(taskID:id,requestJSON:Data(record.request_json.utf8))
        guard record.task_id==id,record.request_sha256==request.digest,record.operation_id==request.request.args.operation_id,
              ["pending","saved_local","rejected","unknown"].contains(record.state),
              record.target.helper_requirement_sha256==identity.designated_requirement_sha256,record.target.policy_sha256==policy else {
            throw RemindersTransportFault("product_record_changed")
        }
        return record
    }
    private func target()throws->RemindersProductTarget {
        guard try verifyRoot(),access(targetPath,F_OK)==0 else{throw RemindersTransportFault("target_required")}
        let value=try JSONDecoder().decode(RemindersProductTarget.self,from:RemindersNativeIO.privateFile(targetPath))
        guard value.helper_requirement_sha256==identity.designated_requirement_sha256,value.policy_sha256==policy else {throw RemindersTransportFault("target_changed")}
        return value
    }
    private func catalog()throws->RemindersProductCatalog {
        guard permission()=="full_access" else{throw RemindersTransportFault("needs_permission")}
        let value=try catalogAccess();try value.validate()
        let nativeSources=try repository.sources(ids:Set(value.sources.map(\.id)))
        let nativeLists=try repository.lists(ids:Set(value.lists.map(\.id)))
        guard Set(nativeSources.map(\.id))==Set(value.sources.map(\.id)),Set(nativeLists.map(\.id))==Set(value.lists.map(\.id)) else{throw RemindersTransportFault("catalog_changed")}
        let sources=nativeSources.map {row in
            RemindersProductSource(id:row.id,title:row.title,type:row.type,
                reminder_list_count:row.reminder_list_count ?? nativeLists.filter{$0.source_id==row.id}.count,
                is_delegate:row.is_delegate,is_system_default_account:row.is_system_default_account)
        }
        let lists=nativeLists.map {row in
            RemindersProductList(id:row.id,title:row.title,source_id:row.source_id,writable:row.writable,
                calendar_type:row.calendar_type,subscribed:row.subscribed,immutable:row.immutable,is_system_default:row.is_system_default)
        }
        let result=RemindersProductCatalog(sources:sources,lists:lists,system_default_list_id:try repository.defaultListID())
        try result.validate();return result
    }
    private func makeTarget(_ source:RemindersProductSource,_ list:RemindersProductList?=nil)->RemindersProductTarget {
        .init(source:source,list:list,helper_requirement_sha256:identity.designated_requirement_sha256,policy_sha256:policy)
    }
    private func listTarget(_ id:String,in values:RemindersProductCatalog,writable:Bool)throws->RemindersProductTarget {
        guard let list=values.lists.first(where:{$0.id==id}),let source=values.sources.first(where:{$0.id==list.source_id}),[0,1,2,3].contains(source.type) else{throw AdapterFault("target_not_authorized")}
        guard !writable || (list.writable && list.subscribed != true) else{throw AdapterFault("list_not_writable")}
        return makeTarget(source,list)
    }
    private func defaultTarget(in values:RemindersProductCatalog)throws->RemindersProductTarget {
        do {
            let stored=try target()
            guard let id=stored.list?.id else{throw RemindersTransportFault("default_list_required")}
            let fresh=try listTarget(id,in:values,writable:true)
            guard fresh.source.id==stored.source.id else{throw RemindersTransportFault("default_list_unavailable")}
            return fresh
        } catch let fault as RemindersTransportFault where fault.code=="target_required" {
            // System default is useful metadata, but CalDAV does not identify
            // the user's main iCloud account. Never adopt Google/another account
            // merely because it is the system default or has an iCloud-like name.
            throw RemindersTransportFault("default_list_required")
        }
    }
    private func publishDefault(_ values:RemindersProductCatalog,to reply:inout RemindersProductReply)throws {
        do {reply.default_target=try defaultTarget(in:values);reply.default_status="available"}
        catch let fault as RemindersTransportFault where ["target_required","default_list_required","default_list_unavailable","target_changed"].contains(fault.code) {reply.default_status=fault.code}
        catch let fault as AdapterFault where ["target_not_authorized","list_not_found","list_not_writable"].contains(fault.code) {reply.default_status="default_list_unavailable"}
    }
    private func verify(_ value:RemindersProductTarget,writable:Bool=true)throws {
        guard permission()=="full_access" else{throw RemindersTransportFault("needs_permission")}
        let sources=try repository.sources(ids:[value.source.id])
        guard sources.contains(where:{$0.id==value.source.id && $0.type==value.source.type}),[0,1,2,3].contains(value.source.type) else{throw AdapterFault("source_not_found")}
        if let list=value.list {
            guard let actual=try repository.lists(ids:[list.id]).first,actual.source_id==value.source.id else{throw AdapterFault("list_not_found")}
            guard !writable || (actual.writable && actual.subscribed != true) else{throw AdapterFault("list_not_writable")}
        }
    }
    private func attach(_ record:RemindersProductRecord,to reply:inout RemindersProductReply) {
        var summary=record;summary.result_json=nil
        reply.task=summary;reply.result_json=record.result_json
    }
    func handle(_ frame:RemindersProductFrame,check:@escaping()throws->Void)->RemindersProductReply {
        var reply=RemindersProductReply(schema_version:3,capability_id:"reminders.product.v1",request_id:frame.request_id,action:frame.action,
            identity:identity,policy_sha256:policy,outcome:"unavailable",code:"outcome_unknown")
        do {
            try check()
            if frame.action == .selection {
                reply.target=try target();reply.default_target=reply.target;reply.default_status="stored_unverified";reply.outcome="refreshed";reply.code="stored_selection";return reply
            }
            if frame.action == .history {
                guard try verifyRoot() else{reply.history=[];reply.outcome="refreshed";reply.code="ok";return reply}
                let names=try FileManager.default.contentsOfDirectory(atPath:root+"/tasks").filter {
                    $0.hasSuffix(".json") && RemindersTaskContract.uuid(String($0.dropLast(5)))
                }.sorted()
                guard names.count<=4096,let offset=frame.offset,offset<=names.count else{throw RemindersTransportFault("invalid_history_offset")}
                let page=Array(names.dropFirst(offset).prefix(20))
                reply.history=try page.map {name in
                    guard let row=try record(String(name.dropLast(5))) else{throw RemindersTransportFault("product_record_changed")}
                    let raw=try JSONSerialization.jsonObject(with:Data(row.request_json.utf8)) as! [String:Any]
                    let args=raw["args"] as! [String:Any]
                    let patch=args["patch"] as? [String:Any]
                    let titlePatch=patch?["title"] as? [String:Any]
                    return .init(task_id:row.task_id,title:args["title"] as? String ?? titlePatch?["value"] as? String ?? String(raw["tool"] as? String ?? "reminders"),state:row.state,code:row.state=="pending" ? "outcome_unknown":row.code)
                }
                reply.next_offset=offset+page.count<names.count ? offset+page.count:nil
                reply.outcome="refreshed";reply.code="ok";return reply
            }
            if frame.action == .status {
                if let record=try record(frame.task_id!) {attach(record,to:&reply)}
                reply.outcome="refreshed";reply.code=reply.task == nil ? "operation_missing":reply.task!.code
                if reply.task?.state=="pending" {reply.code="outcome_unknown"}
                return reply
            }
            // Repeated task IDs inspect the frozen result before touching permission,
            // target or EventKit. Unknown and rejected attempts are never resumed.
            var mutation:RemindersProductRequest?
            if frame.action == .submit {
                let decoded=try RemindersProductRequest.decode(taskID:frame.task_id!,requestJSON:Data(frame.request_json!.utf8))
                mutation=decoded
                if let old=try record(decoded.taskID) {
                    guard old.request_sha256==decoded.digest else{throw AdapterFault("idempotency_conflict")}
                    attach(old,to:&reply);reply.outcome="refreshed"
                    reply.code=old.state=="pending" ? "outcome_unknown":old.code
                    return reply
                }
            }
            guard permission()=="full_access" else{throw RemindersTransportFault("needs_permission")}
            if frame.action == .catalog {
                let values=try catalog();reply.catalog=values
                try publishDefault(values,to:&reply);reply.target=reply.default_target
                reply.outcome="refreshed";reply.code="ok"
                guard try encoder.encode(reply).count<=RemindersProductFrame.responseLimit else{reply.catalog=nil;reply.target=nil;reply.default_target=nil;throw RemindersTransportFault("catalog_limit")}
                return reply
            }
            if frame.action == .select {
                let values=try catalog()
                guard let source=values.sources.first(where:{$0.id==frame.source_id}),[0,1,2,3].contains(source.type) else{throw AdapterFault("source_not_found")}
                guard let listID=frame.list_id else{throw RemindersTransportFault("default_list_required")}
                guard let list=values.lists.first(where:{$0.id==listID && $0.source_id==source.id && $0.writable && $0.subscribed != true}) else{throw AdapterFault("list_not_found")}
                let selected=RemindersProductTarget(source:source,list:list,helper_requirement_sha256:identity.designated_requirement_sha256,policy_sha256:policy)
                try verify(selected);try check();try ensureRoot()
                try RemindersNativeIO.atomicWrite(try encoder.encode(selected),to:targetPath)
                reply.target=selected;reply.default_target=selected;reply.default_status="available";reply.outcome="completed";reply.code="target_selected";return reply
            }
            let request:ARLRemindersCore.Request
            if let mutation {request=mutation.request}
            else {
                let raw=Data(frame.request_json!.utf8)
                try RemindersProductRequest.uniqueKeys(raw)
                request=try ARLRemindersCore.Request.decode(raw)
                guard !request.isMutation else{throw AdapterFault("product_operation_mismatch")}
            }
            let values=try catalog()
            var selected:RemindersProductTarget?
            var defaultListID:String?
            var defaultBytes:Data?
            if let id=request.args.list_id ?? request.args.selector?.id {
                selected=try listTarget(id,in:values,writable:request.isMutation)
                reply.read_scope="explicit_list"
            } else if request.operation=="create" {
                selected=try defaultTarget(in:values);defaultListID=selected?.list?.id
                if access(targetPath,F_OK)==0 {defaultBytes=try RemindersNativeIO.privateFile(targetPath)}
                reply.read_scope="default_list"
            } else if let sourceID=request.args.source_id ?? request.args.selector?.source_id {
                guard let source=values.sources.first(where:{$0.id==sourceID}),[0,1,2,3].contains(source.type) else{throw AdapterFault("source_not_found")}
                selected=makeTarget(source);reply.read_scope="explicit_source"
            } else {reply.read_scope="all_authorized_lists"}
            let scopeSources=selected.map{[$0.source]} ?? values.sources.filter{[0,1,2,3].contains($0.type)}
            let scopeSourceIDs=Set(scopeSources.map(\.id))
            let scopeLists=selected?.list.map{[$0]} ?? values.lists.filter{scopeSourceIDs.contains($0.source_id)}
            let expiry=Date().addingTimeInterval(120)
            func validate()throws {
                try check()
                guard Date()<expiry,permission()=="full_access" else{throw AdapterFault("review_not_authorized")}
                // Only implicit creation depends on the default preference. Explicit
                // targets and unfiltered reads never depend on target.json.
                if let defaultBytes {guard try RemindersNativeIO.privateFile(targetPath)==defaultBytes else{throw AdapterFault("target_not_authorized")}}
                if let selected {try verify(selected,writable:request.isMutation)}
                else {
                    let actual=try repository.lists(ids:Set(scopeLists.map(\.id)))
                    guard actual.count==scopeLists.count,actual.allSatisfy({row in scopeLists.contains(where:{$0.id==row.id && $0.source_id==row.source_id})}) else{throw AdapterFault("target_not_authorized")}
                }
            }
            // Each request is bounded to native metadata already covered by the
            // existing OS grant; a caller supplies IDs, never host authority.
            let authority=HostAuthority(owner:"reminders-product:"+identity.designated_requirement_sha256.prefix(32),
                requestDigest:try ARLRemindersCore.digest(request),key:request.args.operation_id ?? "read",
                expires:expiry,allowedTools:[request.tool],listIDs:Set(scopeLists.map(\.id)),sourceIDs:scopeSourceIDs,
                defaultListID:defaultListID,checkCancelled:validate)
            try authority.check(request)
            try ensureRoot()
            let journal=try OperationJournal(directory:URL(fileURLWithPath:root+"/operation-journal"))
            let adapter=RemindersAdapter(repository:repository,journal:journal)
            if let mutation {
                guard let selected else{throw AdapterFault("target_not_authorized")}
                let canonical=String(decoding:try encoder.encode(request),as:UTF8.self)
                var task=RemindersProductRecord(task_id:mutation.taskID,operation_id:request.args.operation_id!,request_sha256:mutation.digest,
                    request_json:canonical,target:selected,state:"pending",code:"outcome_unknown",result_json:nil)
                let taskPath=try path(mutation.taskID)
                guard try FileManager.default.contentsOfDirectory(atPath:root+"/tasks").count<4096 else{throw RemindersTransportFault("task_capacity")}
                // This durable intent is mandatory. The optional UI business log
                // cannot substitute for it or prevent unrelated future tasks.
                try RemindersNativeIO.writeNew(try encoder.encode(task),to:taskPath)
                do {
                    let result=try adapter.execute(request,authority:authority)
                    task.result_json=String(decoding:try encoder.encode(result),as:UTF8.self)
                    task.state="saved_local";task.code=request.operation == "delete" ? "deleted_local":"saved_local"
                } catch {
                    let code=(error as? AdapterFault)?.code ?? (error as? RemindersTransportFault)?.code ?? "outcome_unknown"
                    task.state=code=="outcome_unknown" ? "unknown":"rejected";task.code=code
                }
                try RemindersNativeIO.atomicWrite(try encoder.encode(task),to:taskPath)
                attach(task,to:&reply);reply.target=selected
                reply.outcome=task.state=="saved_local" ? "saved_local":task.state=="unknown" ? "needs_review":"unavailable";reply.code=task.code
            } else {
                let result=try adapter.execute(request,authority:authority)
                let encoded=try encoder.encode(result)
                guard encoded.count<=60000 else{throw RemindersTransportFault("result_limit")}
                reply.result_json=String(decoding:encoded,as:UTF8.self)
                reply.target=selected;reply.outcome="refreshed";reply.code="ok"
            }
        } catch {reply.code=(error as? AdapterFault)?.code ?? (error as? RemindersTransportFault)?.code ?? "outcome_unknown"}
        return reply
    }
}

/// Host transfers one serial action to the existing helper worker.
final class RemindersProductWorker: @unchecked Sendable {
    let handler:RemindersProductHandler
    let frame:RemindersProductFrame
    let check:()throws->Void
    init(handler:RemindersProductHandler,frame:RemindersProductFrame,check:@escaping()throws->Void) {
        self.handler=handler;self.frame=frame;self.check=check
    }
    func run()->RemindersProductReply {handler.handle(frame,check:check)}
}
