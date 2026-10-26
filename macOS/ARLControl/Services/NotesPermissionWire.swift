import Foundation
import CoreFoundation
import Darwin

/// A finite typed decode boundary. Native authorization is never an execution grant.
enum NotesPermissionWire {
    static func boolean(_ value:Any?) -> Bool? {
        guard let n=value as? NSNumber,CFGetTypeID(n)==CFBooleanGetTypeID() else{return nil};return n.boolValue
    }
    static func integer(_ value:Any?) -> Int64? {
        guard let n=value as? NSNumber,CFGetTypeID(n) != CFBooleanGetTypeID(),String(cString:n.objCType) != "d",String(cString:n.objCType) != "f",n.stringValue==String(n.int64Value) else{return nil};return n.int64Value
    }
    static func identity(_ raw:Any?,_ d:NotesPermissionDeployment)->Bool {
        guard let row=raw as? [String:String],Set(row.keys)==["helper_bundle_id","executable_sha256","designated_requirement_sha256","cdhash"] else{return false}
        return row["helper_bundle_id"]==d.helper_bundle_id && row["executable_sha256"]==d.helper_executable_sha256 && row["designated_requirement_sha256"]==d.helper_designated_requirement_sha256 && row["cdhash"]==d.helper_cdhash
    }
    static func decodeEnvelope(_ data:Data,method:String)throws->[String:Any] {
        let envelope=try MessagesJSON.decode(data).value
        guard Set(envelope.keys)==["schema_version","method","status","result_json","error_code","indeterminate"],integer(envelope["schema_version"])==2,envelope["method"] as? String==method else{throw NotesControlFault("invalid_response")}
        if envelope["status"] as? String=="error" {
            guard envelope["result_json"] is NSNull,let code=envelope["error_code"] as? String,code.range(of:"^[a-z_]{1,80}$",options:.regularExpression) != nil,let uncertain=integer(envelope["indeterminate"]),[0,1].contains(uncertain) else{throw NotesControlFault("invalid_response")}
            throw NotesControlFault(uncertain==1 ? "permission_needs_review":"native_request_refused")
        }
        guard envelope["status"] as? String=="ok",envelope["error_code"] is NSNull,integer(envelope["indeterminate"])==0,let text=envelope["result_json"] as? String else{throw NotesControlFault("invalid_response")}
        return try MessagesJSON.decode(Data(text.utf8)).value
    }
    static func validateBootstrap(_ row:[String:Any],_ d:NotesPermissionDeployment,pid:pid_t,parent:pid_t)throws {
        guard Set(row.keys)==["host_mode","session_kind","profile_sha256","source_closure_sha256","peer_pid","host_pid","identity","kernel_peer_verified","self_code_pin_verified","notes_events_sent","permission_queries"],
              row["host_mode"] as? String==(d.surface_scope=="synthetic_only" ? "synthetic":"notes"),row["session_kind"] as? String=="permission_setup",row["profile_sha256"] as? String==d.profile_sha256,
              row["source_closure_sha256"] as? String==d.source_closure_sha256,integer(row["peer_pid"])==Int64(parent),integer(row["host_pid"])==Int64(pid),
              identity(row["identity"],d),boolean(row["kernel_peer_verified"])==true,boolean(row["self_code_pin_verified"])==true,integer(row["notes_events_sent"])==0,integer(row["permission_queries"])==0 else{throw NotesControlFault("invalid_bootstrap")}
    }
    static func classification(_ state:String,_ code:String,synthetic:Bool)->Bool {
        switch (state,code) {case ("authorized_automation","ok"),("denied","denied"),("not_determined","not_determined"),("unknown","target_not_running"),("unknown","permission_unknown"):return !synthetic
        case ("unknown","synthetic_only"):return synthetic
        default:return false}
    }
    static func fresh(_ value:Any?)->Int64? {
        guard let ms=integer(value),ms>0 else{return nil};let age=Int64(Date().timeIntervalSince1970*1000)-ms;return age>=0 && age<=30000 ? ms:nil
    }
    static func requestResult(_ row:[String:Any],_ d:NotesPermissionDeployment)throws->String {
        guard Set(row.keys)==["schema_version","request_id","capability_id","action","outcome","permission_state","preflight_code","request_attempted","prompts_requested","prompt_presentation","execution_grant_created","notes_events_sent","data_read","identity","observed_at_ms","surface_scope"],
              integer(row["schema_version"])==1,row["request_id"] as? String==d.request_id,row["capability_id"] as? String==d.capability_id,row["action"] as? String=="request",row["surface_scope"] as? String==d.surface_scope,identity(row["identity"],d),fresh(row["observed_at_ms"]) != nil,
              boolean(row["execution_grant_created"])==false,boolean(row["data_read"])==false,integer(row["notes_events_sent"])==0,
              let attempted=boolean(row["request_attempted"]),boolean(row["prompts_requested"])==attempted,row["prompt_presentation"] as? String=="not_observed",
              let state=row["permission_state"] as? String,let code=row["preflight_code"] as? String,classification(state,code,synthetic:false),
              let outcome=row["outcome"] as? String,outcome==(state=="authorized_automation" ? "authorized":code) else{throw NotesControlFault("invalid_response")}
        return outcome
    }
    static func catalog(_ object:[String:Any],_ d:NotesPermissionDeployment)throws->[NotesPermissionStatus] {
        let synthetic=d.surface_scope=="synthetic_only"
        guard Set(object.keys)==["schema_version","records","synthetic","actual_notes_access","permission_requests_enabled","permission_request_source_implemented","append_enabled","attachment_write_enabled"],integer(object["schema_version"])==2,
              boolean(object["synthetic"])==synthetic,boolean(object["actual_notes_access"])==false,boolean(object["permission_requests_enabled"])==true,boolean(object["permission_request_source_implemented"])==true,
              boolean(object["append_enabled"])==false,boolean(object["attachment_write_enabled"])==false,let rows=object["records"] as? [[String:Any]],rows.count==3 else{throw NotesControlFault("invalid_response")}
        var records:[NotesPermissionStatus]=[],seen=Set<String>()
        for row in rows {
            guard Set(row.keys)==["capability_id","permission_kind","identity","observed_at_ms","permission_state","preflight_code","implementation_state","request_route_state","request_source_implemented","request_profile_admitted","readiness","event_class","event_ids","prompts_requested","data_read"],
                  let id=row["capability_id"] as? String,NotesIntegrationRecord.records.contains(where:{$0.id==id}),seen.insert(id).inserted,identity(row["identity"],d),row["permission_kind"] as? String=="automation",row["implementation_state"] as? String=="source_only",row["request_route_state"] as? String=="requires_user_action",boolean(row["request_source_implemented"])==true,boolean(row["request_profile_admitted"])==(id==d.capability_id),
                  let state=row["permission_state"] as? String,let code=row["preflight_code"] as? String,classification(state,code,synthetic:synthetic),row["readiness"] as? String==(state=="authorized_automation" ? "grant_inactive":"needs_permission"),
                  let ms=fresh(row["observed_at_ms"]),boolean(row["prompts_requested"])==false,boolean(row["data_read"])==false,integer(row["event_class"])==0x636f7265,
                  let events=row["event_ids"] as? [Any],events.compactMap(integer)==[0x67657464,0x636e7465]+(id=="notes.create.v2" ? [0x6372656c]:[]),events.allSatisfy({integer($0) != nil}) else{throw NotesControlFault("invalid_response")}
            records.append(.init(capabilityID:id,state:state,code:code,observedAtMS:ms))
        }
        return records
    }
}
