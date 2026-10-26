import Foundation
import CryptoKit

/// Additive named tools. The native owner performs each domain's strict decode,
/// target admission and durable effect claim; this catalog grants no authority.
enum AppleProductCapability {
    static let reminders:Set<String>=Set(["catalog","query","get","create_list","create_item","update_item","complete_item","uncomplete_item","delete_item","product_operation_status"].map{"mio_reminders_"+$0})
    static let calendar:Set<String>=Set(["calendars","query","get","create","update","delete","operation_status"].map{"mio_calendar_"+$0})
    static let notes:Set<String>=Set(["folders","list","search","read","create","update","delete"].map{"mio_notes_"+$0})
    static let messages:Set<String>=Set(["accounts","chats","prepare_send","send","read"].map{"mio_messages_"+$0})
    static let names=reminders.union(calendar).union(notes).union(messages)
    static let mutations:Set<String>=["mio_reminders_create_list","mio_reminders_create_item","mio_reminders_update_item","mio_reminders_complete_item","mio_reminders_uncomplete_item","mio_reminders_delete_item","mio_calendar_create","mio_calendar_update","mio_calendar_delete","mio_notes_create","mio_notes_update","mio_notes_delete","mio_messages_send"]
    static func arguments(tool:String,data:Data)throws->[String:Any] {
        guard names.contains(tool) else{throw OwnerReadFault.unsupported}
        let args=try OwnerReadJSON.object(data,limit:OwnerReadWire.requestLimit,maximumDepth:24)
        if mutations.contains(tool) || tool.hasSuffix("operation_status") || tool=="mio_messages_prepare_send" || calendar.contains(tool) {
            guard let task=args["task_id"] as? String,UUID(uuidString:task)?.uuidString.lowercased()==task else{throw OwnerReadFault.invalid}
        }
        return args
    }

    /// Admit successful tool results only when the domain receipt agrees with
    /// the requested operation. Metadata cannot stand in for an effect receipt.
    static func admit(_ value:[String:Any],tool:String,arguments:[String:Any])throws->Bool {
        guard let state=value["state"] as? String else{throw OwnerReadFault.invalid}
        if ["unavailable","outcome_unknown","unknown","pending","rejected","attempting","needs_review","unsupported"].contains(state){return false}
        guard let result=value["result"] as? [String:Any] else{throw OwnerReadFault.invalid}
        func hash(_ data:Data)->String {SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
        func validHash(_ value:Any?)->Bool {(value as? String)?.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil}
        func uuid(_ value:Any?)->String? {(value as? String).flatMap{UUID(uuidString:$0)?.uuidString.lowercased()}}
        if calendar.contains(tool) {
            guard result["task_id"] as? String==arguments["task_id"] as? String else{throw OwnerReadFault.invalid}
            if mutations.contains(tool) || tool=="mio_calendar_operation_status" {
                guard let operation=result["operation"] as? [String:Any],
                      operation["task_id"] as? String==arguments["task_id"] as? String,
                      operation["state"] as? String==state,validHash(operation["digest"]),
                      OwnerReadWire.falseBoolean(operation["automatic_replay"]),
                      let action=operation["action"] as? String,["create","update","delete"].contains(action)
                else{throw OwnerReadFault.invalid}
                if mutations.contains(tool) {
                    guard "mio_calendar_"+action==tool else{throw OwnerReadFault.invalid}
                    var request=arguments;request["action"]=action
                    guard operation["digest"] as? String==hash(try JSONSerialization.data(withJSONObject:request,options:[.sortedKeys,.withoutEscapingSlashes])) else{throw OwnerReadFault.invalid}
                }
                guard ["saved_local","saved_unreadable","deleted_local"].contains(state) else{throw OwnerReadFault.invalid}
                guard (action=="delete") == (state=="deleted_local") else{throw OwnerReadFault.invalid}
                if state=="saved_unreadable" {
                    guard action=="create",operation["code"] as? String=="saved_without_readback",(tool=="mio_calendar_operation_status" || result["access"] as? String=="write_only") else{throw OwnerReadFault.invalid}
                } else if state=="saved_local" {guard operation["event"] is [String:Any] else{throw OwnerReadFault.invalid}}
                return true
            }
            guard state=="read",result["code"] as? String=="ok",result["access"] as? String=="full_access",
                  tool=="mio_calendar_calendars" ? result["calendars"] is [[String:Any]]:result["events"] is [[String:Any]]
            else{throw OwnerReadFault.invalid}
            return true
        }
        if reminders.contains(tool) {
            guard OwnerReadWire.integer(result["schema_version"],3),result["capability_id"] as? String=="reminders.product.v1" else{throw OwnerReadFault.invalid}
            if mutations.contains(tool) || tool=="mio_reminders_product_operation_status" {
                guard state=="saved_local",let task=result["task"] as? [String:Any],task["state"] as? String=="saved_local",
                      task["task_id"] as? String==arguments["task_id"] as? String,
                      let taskID=task["task_id"] as? String,let raw=task["request_json"] as? String,
                      task["request_sha256"] as? String==hash(Data(raw.utf8)),
                      let request=try JSONSerialization.jsonObject(with:Data(raw.utf8)) as? [String:Any],
                      let args=request["args"] as? [String:Any],let op=task["operation_id"] as? String,
                      let encoded=result["result_json"] as? String,
                      let receipt=try JSONSerialization.jsonObject(with:Data(encoded.utf8)) as? [String:Any],
                      receipt["status"] as? String=="ok",OwnerReadWire.integer(receipt["schema_version"],3),
                      receipt["operation_id"] as? String==op,receipt["cloud_sync"] as? String=="not_checked"
                else{throw OwnerReadFault.invalid}
                let h=Array(hash(Data(("arl.reminders.product.v1:"+taskID).utf8)).prefix(32))
                let expected=String(h[0..<8])+"-"+String(h[8..<12])+"-"+String(h[12..<16])+"-"+String(h[16..<20])+"-"+String(h[20..<32])
                guard op==expected,args["operation_id"] as? String==op else{throw OwnerReadFault.invalid}
                if mutations.contains(tool) {
                    let operations=["mio_reminders_create_list":"list.create","mio_reminders_create_item":"create","mio_reminders_update_item":"update","mio_reminders_complete_item":"complete","mio_reminders_uncomplete_item":"uncomplete","mio_reminders_delete_item":"delete"]
                    var expectedArgs=arguments;expectedArgs.removeValue(forKey:"task_id");expectedArgs["operation_id"]=op
                    guard request["tool"] as? String=="apple.reminders."+operations[tool]!+".v3",(args as NSDictionary).isEqual(to:expectedArgs) else{throw OwnerReadFault.invalid}
                }
                if request["tool"] as? String=="apple.reminders.delete.v3" {
                    guard receipt["persistence"] as? String=="deleted_local",task["code"] as? String=="deleted_local",
                          value["code"] as? String=="deleted_local",let deletion=receipt["deletion"] as? [String:Any],
                          Set(deletion.keys)==["id","list_id","expected_revision"],
                          let id=args["reminder_id"] as? String,!id.isEmpty,
                          let list=args["list_id"] as? String,!list.isEmpty,validHash(args["expected_revision"]),
                          deletion["id"] as? String==id,deletion["list_id"] as? String==list,
                          deletion["expected_revision"] as? String==args["expected_revision"] as? String
                    else{throw OwnerReadFault.invalid}
                } else {
                    guard receipt["persistence"] as? String=="saved_local",
                          receipt["list"] is [String:Any] || receipt["reminder"] is [String:Any] else{throw OwnerReadFault.invalid}
                }
                return true
            }
            guard state=="refreshed",result["code"] as? String=="ok" else{throw OwnerReadFault.invalid}
            if tool=="mio_reminders_catalog" {guard result["catalog"] is [String:Any] else{throw OwnerReadFault.invalid};return true}
            guard let raw=result["result_json"] as? String,let receipt=try JSONSerialization.jsonObject(with:Data(raw.utf8)) as? [String:Any],
                  receipt["status"] as? String=="ok",tool=="mio_reminders_query" ? receipt["reminders"] is [[String:Any]]:receipt["reminder"] is [String:Any]
            else{throw OwnerReadFault.invalid}
            return true
        }
        guard let payload=result["result"] as? [String:Any] else{throw OwnerReadFault.invalid}
        if notes.contains(tool) {
            if tool=="mio_notes_delete" {
                guard state=="deleted_local",value["code"] as? String=="deleted_local",
                      let mutation=payload["mutation"] as? [String:Any],mutation["outcome"] as? String=="deleted_local",
                      let row=arguments["row"] as? [String:Any],let id=row["id"] as? String,!id.isEmpty,
                      mutation["itemID"] as? String==id else{throw OwnerReadFault.invalid}
                return true
            }
            if mutations.contains(tool) {
                guard state=="saved_local",let mutation=payload["mutation"] as? [String:Any],let id=mutation["itemID"] as? String,!id.isEmpty,
                      mutation["outcome"] as? String=="verified_local" else{throw OwnerReadFault.invalid};return true
            }
            let variant=tool=="mio_notes_folders" ? "folders":tool=="mio_notes_read" ? "read":"search"
            guard state=="read",payload[variant] is [String:Any] else{throw OwnerReadFault.invalid};return true
        }
        if tool=="mio_messages_send" {
            guard state=="accepted_local",let accepted=payload["accepted"] as? [String:Any],uuid(accepted["operationID"])==arguments["task_id"] as? String else{throw OwnerReadFault.invalid}
            return true
        }
        if tool=="mio_messages_prepare_send" {
            guard state=="prepared",let prepared=payload["prepared"] as? [String:Any],let proposal=prepared["_0"] as? [String:Any],
                  uuid(proposal["id"])==arguments["task_id"] as? String,proposal["plaintext"] as? String==arguments["plaintext"] as? String,
                  validHash(value["prepared_digest"]) else{throw OwnerReadFault.invalid};return true
        }
        guard state=="read",tool != "mio_messages_read",payload[tool=="mio_messages_accounts" ? "accounts":"chats"] is [String:Any] else{throw OwnerReadFault.invalid}
        return true
    }
    private static var text:[String:Any] {["type":"string","minLength":1,"maxLength":1024]}
    private static var task:[String:Any] {["type":"string","format":"uuid","description":"Stable lowercase UUID. Preserve the original ID after any uncertain result; status never resumes an effect."]}
    private static var hash:[String:Any] {["type":"string","pattern":"^[a-f0-9]{64}$"]}
    private static func object(_ properties:[String:Any],_ required:[String])->[String:Any] {
        ["type":"object","additionalProperties":false,"properties":properties,"required":required]
    }
    private static var reminderPatch:[String:Any] {
        let date=object(["kind":["type":"string","enum":["date","date_time"]],"value":text,"time_zone":text],["kind","value"])
        let recurrence=object(["frequency":["type":"string","enum":["daily","weekly","monthly","yearly"]],"interval":["type":"integer","minimum":1,"maximum":999],"count":["type":"integer","minimum":1,"maximum":9999],"until":text],["frequency","interval"])
        let alarm=object(["kind":["type":"string","enum":["relative","absolute"]],"at":text,"offset_seconds":["type":"number","minimum":-31536000,"maximum":31536000]],["kind"])
        func change(_ value:[String:Any])->[String:Any] {object(["action":["type":"string","enum":["keep","clear","set"]],"value":value],["action"])}
        return object(["title":change(text),"notes":change(["type":"string","maxLength":4096]),"priority":change(["type":"integer","minimum":0,"maximum":9]),"due":change(date),"start":change(date),"recurrence":change(recurrence),"alert":change(alarm)],[])
    }
    static var descriptors:[[String:Any]] {
        var result:[[String:Any]]=[]
        func add(_ name:String,_ description:String,_ properties:[String:Any],_ required:[String]) {
            let write=mutations.contains(name)
            result.append(["name":name,"description":description,
                "inputSchema":object(properties,required),
                "annotations":["readOnlyHint":!write,"destructiveHint":["mio_calendar_delete","mio_reminders_delete_item","mio_notes_delete"].contains(name),"idempotentHint":true,"openWorldHint":true],
                "_meta":["arl/capability":"apple.product.v1","arl/version":1,"arl/automaticReplay":false]])
        }
        add("mio_reminders_catalog","Read account/list metadata and the existing default-list preference through the signed owner. A default never limits explicit targets or unfiltered reads. Does not request permission or establish business GO.",[:],[])
        add("mio_reminders_query","Read a page of reminders; continue using next_offset with the same query. An explicit list_id is exact; omitted list_id queries all OS-authorized reminder lists and is never narrowed by the default. No automatic writes or permission requests.",["offset":["type":"integer","minimum":0],"limit":["type":"integer","minimum":1,"maximum":100],"list_id":text,"include_completed":["type":"boolean"],"due_window":object(["start":text,"end":text],["start","end"])],[])
        add("mio_reminders_get","Read the exact reminder in the explicitly specified list, including the current revision for edits.",["list_id":text,"reminder_id":text],["list_id","reminder_id"])
        add("mio_reminders_create_list","Create one list in the explicitly specified source. Requires an explicit user intent and a stable task_id. Repeated IDs only inspect the frozen attempt; cloud sync is not checked.",["task_id":task,"source_id":text,"title":text],["task_id","source_id","title"])
        add("mio_reminders_create_item","Create one full-field reminder. Explicit list_id takes priority; when omitted, use the native default-list preference and freeze the resolved target in the original task. Patch supports notes, priority, due/start date or timestamp+IANA time zone, simple recurrence, absolute/relative alarm. Relative alarms require timed start; recurrence requires start. Preserve task_id; unknown never replays. saved_local does not verify cloud sync.",["task_id":task,"list_id":text,"title":["type":"string","minLength":1,"maxLength":300],"patch":reminderPatch],["task_id","title"])
        add("mio_reminders_update_item","Patch the exact explicitly targeted reminder using its read revision. Omitted/keep fields are preserved; clear is explicit. Complex existing recurrence/alarms cannot be rewritten. No delete or automatic retry.",["task_id":task,"list_id":text,"reminder_id":text,"expected_revision":hash,"patch":reminderPatch],["task_id","list_id","reminder_id","expected_revision","patch"])
        for action in ["complete","uncomplete"] {
            add("mio_reminders_"+action+"_item","Set completion of the exact reminder using its current revision and original stable task_id. No replay after an uncertain result.",["task_id":task,"list_id":text,"reminder_id":text,"expected_revision":hash],["task_id","list_id","reminder_id","expected_revision"])
        }
        add("mio_reminders_delete_item","Delete one non-recurring reminder in the explicitly specified list after exact native confirmation. Requires the original reminder revision and stable task_id. deleted_local proves local absence only; cloud sync is not checked. Unknown never replays.",["task_id":task,"list_id":text,"reminder_id":text,"expected_revision":hash],["task_id","list_id","reminder_id","expected_revision"])
        add("mio_reminders_product_operation_status","Inspect the original product task record only. Does not launch a helper, fetch EventKit content, request permission or resume a save.",["task_id":task],["task_id"])
        let target=object(["calendar_id":text,"event_id":text,"occurrence_start":text,"revision":hash],["calendar_id","event_id","occurrence_start","revision"])
        let recurrence=object(["frequency":["type":"string","enum":["daily","weekly","monthly","yearly"]],"interval":["type":"integer","minimum":1,"maximum":99],"count":["type":"integer","minimum":1,"maximum":999],"until":text],["frequency","interval"])
        let draft=object(["calendar_id":text,"title":["type":"string","minLength":1,"maxLength":300],"start":text,"end":text,"time_zone":text,"all_day":["type":"boolean"],"alarm_seconds":["type":"array","items":["type":"integer","minimum":0,"maximum":2678400],"maxItems":5],"recurrence":recurrence],["title","start","end","time_zone","all_day","alarm_seconds"])
        add("mio_calendar_calendars","Read calendar metadata in the main ARL permission identity; requires full access.",["task_id":task],["task_id"])
        add("mio_calendar_query","Query a page of event occurrences over at most 366 days; continue using next_offset in explicitly listed calendars. Requires full access; truncated means incomplete.",["task_id":task,"query":object(["start":text,"end":text,"calendar_ids":["type":"array","items":text,"minItems":1,"maxItems":50],"limit":["type":"integer","minimum":1,"maximum":500],"offset":["type":"integer","minimum":0]],["start","end","calendar_ids","limit"])],["task_id","query"])
        add("mio_calendar_get","Read one exact event occurrence and revision in the main ARL owner.",["task_id":task,"target":target],["task_id","target"])
        add("mio_calendar_create","Create one locally confirmed event. Write-only access permits default calendar only and reports saved_unreadable. Never invites attendees. Preserve task_id after unknown.",["task_id":task,"draft":draft],["task_id","draft"])
        add("mio_calendar_update","Locally confirm and update one occurrence bound to calendar/event/occurrence/revision. Full draft required; no series edits, cross-calendar moves or invitations.",["task_id":task,"target":target,"draft":draft],["task_id","target","draft"])
        add("mio_calendar_delete","Locally confirm deletion of exactly one current event occurrence. Full access and exact revision required. Other recurring instances remain.",["task_id":task,"target":target],["task_id","target"])
        add("mio_calendar_operation_status","Read durable original task only; does not retry or execute an effect.",["task_id":task],["task_id"])
        let row=object(["id":text,"title":["type":"string"],"modified":["type":"number","description":"Copy the exact opaque modified number returned by this Notes consumer."]],["id","title","modified"])
        add("mio_notes_folders","Read Notes folder metadata. Does not select a folder or request permission.",[:],[])
        add("mio_notes_list","List a page in the selected folder; continue using next_offset.",["offset":["type":"integer","minimum":0],"limit":["type":"integer","minimum":1,"maximum":50]],[])
        add("mio_notes_search","Search notes in the selected folder; bounded provider result includes scanned/total.",["query":text,"offset":["type":"integer","minimum":0],"limit":["type":"integer","minimum":1,"maximum":50]],["query"])
        add("mio_notes_read","Read one exact row from the selected folder. Use next_offset on the same row to continue. Copy row and bodyDigest for any subsequent edit.",["row":row,"offset":["type":"integer","minimum":0],"max_bytes":["type":"integer","minimum":4,"maximum":8192]],["row"])
        add("mio_notes_create","Create one plain-text note in the selected folder after native confirmation. Stable task_id cannot be reused for another body. Full local business log is retained; no automatic retry.",["task_id":task,"title":text,"plaintext":["type":"string","minLength":1,"maxLength":8192]],["task_id","title","plaintext"])
        add("mio_notes_update","Edit a strictly plain-text, attachment-free note using exact row/modified and original body SHA. Rich text and attachments stay read-only. Requires native confirmation.",["task_id":task,"row":row,"source_body_digest":hash,"title":text,"plaintext":["type":"string","maxLength":8192]],["task_id","row","source_body_digest","title","plaintext"])
        add("mio_notes_delete","Delete one exact note in the user-selected folder after native confirmation. Requires the original row/modified and body SHA; shared or locked targets stay protected. Preserve task_id after unknown; never automatically retry.",["task_id":task,"row":row,"source_body_digest":hash],["task_id","row","source_body_digest"])
        add("mio_messages_accounts","Read available iMessage account metadata. Does not select an account or request permission.",[:],[])
        add("mio_messages_chats","Read bounded chat metadata for the already selected account. Public API does not expose received message bodies.",["query":["type":"string","maxLength":1024]],[])
        add("mio_messages_prepare_send","Resolve exactly one existing participant using an explicit email or E.164 phone address. Freeze exact plaintext/account/participant into a proposal; this call never sends.",["task_id":task,"address":text,"plaintext":["type":"string","minLength":1,"maxLength":8192]],["task_id","address","plaintext"])
        let account=object(["id":text,"label":text],["id","label"])
        let recipient=object(["account":account,"id":text,"handle":text,"expires":["type":"number"]],["account","id","handle","expires"])
        let proposal=object(["id":task,"recipient":recipient,"plaintext":["type":"string","minLength":1,"maxLength":8192],"expires":["type":"number"]],["id","recipient","plaintext","expires"])
        add("mio_messages_send","Send only the exact frozen prepared proposal with matching expected_digest and native confirmation. Accepted means local Messages acceptance, never delivery/read. A consumed task is never resent.",["task_id":task,"proposal":proposal,"expected_digest":hash],["task_id","proposal","expected_digest"])
        add("mio_messages_read","Return unsupported_public_api: the public Messages scripting API has no message/body/receive event. Does not read chat.db or request Full Disk Access.",["chat_id":text],["chat_id"])
        return result
    }
}
