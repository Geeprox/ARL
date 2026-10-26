import Foundation

/// Reuses the existing owner-only, fsynced, cross-process locked eight-day
/// business journal. Apple content never enters credential/provider requests.
public final class AppleBusinessJournal: @unchecked Sendable {
    private let journal: MusicBusinessJournal
    public init(directory: URL) { journal=MusicBusinessJournal(directory:directory) }
    public func record(tool: String, callID: UUID, argumentsJSON: Data, responseJSON: Data?) throws {
        guard let args=try JSONSerialization.jsonObject(with:argumentsJSON) as? [String:Any],
              let id=args["task_id"] as? String,id.utf8.count==36,let taskID=UUID(uuidString:id)
        else { throw MusicBusinessLogFailure.unavailable }
        if ["mio_reminders_create","mio_reminders_operation_status"].contains(tool) {
            guard Set(args.keys)==(tool == "mio_reminders_create" ? ["task_id","title"]:["task_id"]),
                  tool != "mio_reminders_create" || args["title"] is String
            else { throw MusicBusinessLogFailure.unavailable }
        } else {
            let actions=["task_prepare","task_scope","task_submit","task_cancel"]
            guard let action=args["action"] as? String,actions.contains(action),tool=="arl_ui_reminders_"+action,
                  args["schema_version"] as? Int==2,args["capability_id"] as? String=="reminders.task.create.v1",
                  let request=args["request_id"] as? String,request.utf8.count==36,UUID(uuidString:request) != nil
            else { throw MusicBusinessLogFailure.unavailable }
            let base:Set<String>=["schema_version","capability_id","action","request_id","task_id"]
            guard Set(args.keys)==base.union([action == "task_prepare" ? "title":"expected_digest"])
            else { throw MusicBusinessLogFailure.unavailable }
            if action == "task_prepare" {
                guard let title=args["title"] as? String,!title.isEmpty,title.utf8.count<=1200
                else { throw MusicBusinessLogFailure.unavailable }
            } else {
                guard let digest=args["expected_digest"] as? String,digest.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil
                else { throw MusicBusinessLogFailure.unavailable }
            }
        }
        var row: [String:Any] = ["event":responseJSON == nil ? "apple_request":"apple_response", "tool":tool,
            "arguments_text":String(decoding:argumentsJSON,as:UTF8.self)]
        if let responseJSON { row["response_text"]=String(decoding:responseJSON,as:UTF8.self) }
        try journal.append(row,requestID:taskID,callID:callID)
    }

    /// Product-only logging entry point. This records already validated native
    /// requests and grants no execution authority. Legacy record stays closed.
    public func recordProduct(tool:String,callID:UUID,argumentsJSON:Data,responseJSON:Data?)throws {
        guard argumentsJSON.count<=65536,responseJSON.map({$0.count<=262144}) ?? true,
              let args=try JSONSerialization.jsonObject(with:argumentsJSON) as? [String:Any]
        else{throw MusicBusinessLogFailure.unavailable}
        func uuid(_ value:Any?)->UUID? {
            guard let text=value as? String,let id=UUID(uuidString:text),id.uuidString.lowercased()==text else{return nil};return id
        }
        let taskID:UUID?
        if tool=="reminders.product" {
            let base:Set<String>=["schema_version","capability_id","request_id","action"]
            guard args["schema_version"] as? Int==3,args["capability_id"] as? String=="reminders.product.v1",
                  uuid(args["request_id"])==callID,let action=args["action"] as? String else{throw MusicBusinessLogFailure.unavailable}
            let extra:Set<String>
            switch action {
            case "catalog","selection":extra=[]
            case "history":extra=["offset"]
            case "select":extra=args["list_id"]==nil ? ["source_id"]:["source_id","list_id"]
            case "read":extra=["request_json"]
            case "submit":extra=["task_id","request_json"]
            case "status":extra=["task_id"]
            default:throw MusicBusinessLogFailure.unavailable
            }
            guard Set(args.keys)==base.union(extra),!extra.contains("task_id") || uuid(args["task_id"]) != nil else{throw MusicBusinessLogFailure.unavailable}
            taskID=uuid(args["task_id"])
        } else {
            let shapes:[String:(Set<String>,Set<String>)]=[
                "mio_reminders_catalog":([],[]),
                "mio_reminders_query":([],["list_id","include_completed","due_window","offset","limit"]),
                "mio_reminders_get":(["list_id","reminder_id"],[]),
                "mio_reminders_create_list":(["task_id","source_id","title"],[]),
                "mio_reminders_create_item":(["task_id","title"],["list_id","patch"]),
                "mio_reminders_update_item":(["task_id","list_id","reminder_id","expected_revision","patch"],[]),
                "mio_reminders_complete_item":(["task_id","list_id","reminder_id","expected_revision"],[]),
                "mio_reminders_uncomplete_item":(["task_id","list_id","reminder_id","expected_revision"],[]),
                "mio_reminders_delete_item":(["task_id","list_id","reminder_id","expected_revision"],[]),
                "mio_reminders_product_operation_status":(["task_id"],[]),
                "mio_calendar_calendars":(["task_id"],[]),
                "mio_calendar_query":(["task_id","query"],[]),
                "mio_calendar_get":(["task_id","target"],[]),
                "mio_calendar_create":(["task_id","draft"],[]),
                "mio_calendar_update":(["task_id","target","draft"],[]),
                "mio_calendar_delete":(["task_id","target"],[]),
                "mio_calendar_operation_status":(["task_id"],[])]
            guard let (required,optional)=shapes[tool],required.isSubset(of:Set(args.keys)),Set(args.keys).isSubset(of:required.union(optional)),
                  !required.contains("task_id") || uuid(args["task_id"]) != nil else{throw MusicBusinessLogFailure.unavailable}
            taskID=uuid(args["task_id"])
        }
        var row:[String:Any]=["event":responseJSON==nil ? "apple_product_request":"apple_product_response",
            "tool":tool,"arguments_text":String(decoding:argumentsJSON,as:UTF8.self)]
        if let responseJSON{row["response_text"]=String(decoding:responseJSON,as:UTF8.self)}
        try journal.append(row,requestID:taskID,callID:callID)
    }
}
