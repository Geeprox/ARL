import Foundation

enum RemindersProductAction: String, Codable, Sendable { case catalog, select, read, submit, status, history, selection }
struct RemindersProductFrame: Codable, Sendable {
    static let requestLimit=65536
    static let responseLimit=262144
    let schema_version: Int
    let capability_id: String
    let request_id: String
    let action: RemindersProductAction
    var task_id: String?
    var request_json: String?
    var source_id: String?
    var list_id: String?
    var offset:Int?
    init(_ action: RemindersProductAction, taskID: String? = nil, requestJSON: String? = nil, sourceID: String? = nil, listID: String? = nil,offset:Int?=nil) {
        schema_version=3;capability_id="reminders.product.v1";request_id=UUID().uuidString.lowercased()
        self.action=action;task_id=taskID;request_json=requestJSON;source_id=sourceID;list_id=listID;self.offset=offset
    }
    static func decode(_ data: Data) throws -> Self {
        let raw=try RemindersNativeIO.flatObject(data,limit:requestLimit)
        let required: Set<String>=["schema_version","capability_id","request_id","action"]
        guard let action=raw["action"] as? String,let op=RemindersProductAction(rawValue:action),
              RemindersNativeIO.integer(raw["schema_version"])==3,
              raw["capability_id"] as? String=="reminders.product.v1",
              let id=raw["request_id"] as? String,RemindersTaskContract.uuid(id) else {throw RemindersTransportFault("invalid_product_frame")}
        let extras: Set<String>
        switch op {
        case .catalog, .selection: extras=[]
        case .history:extras=["offset"]
        case .select:
            extras=raw["list_id"] == nil ? ["source_id"] : ["source_id","list_id"]
        case .read: extras=["request_json"]
        case .submit: extras=["task_id","request_json"]
        case .status: extras=["task_id"]
        }
        guard Set(raw.keys)==required.union(extras) else {throw RemindersTransportFault("invalid_product_frame")}
        for key in extras {
            if key=="offset" {
                guard let value=RemindersNativeIO.integer(raw[key]),(0...4096).contains(value) else{throw RemindersTransportFault("invalid_product_frame")}
                continue
            }
            guard let value=raw[key] as? String,!value.isEmpty,value.utf8.count <= (key=="request_json" ? 12_000:1024) else {throw RemindersTransportFault("invalid_product_frame")}
        }
        if let task=raw["task_id"] as? String {guard RemindersTaskContract.uuid(task) else {throw RemindersTransportFault("invalid_product_task_id")}}
        return try JSONDecoder().decode(Self.self,from:data)
    }
}
struct RemindersProductSource: Codable, Identifiable, Equatable, Sendable {
    let id:String;let title:String;let type:Int
    var reminder_list_count:Int?=nil
    var is_delegate:Bool?=nil
    var is_system_default_account:Bool?=nil
}
struct RemindersProductList: Codable, Identifiable, Equatable, Sendable {
    let id:String;let title:String;let source_id:String;let writable:Bool
    var calendar_type:Int?=nil
    var subscribed:Bool?=nil
    var immutable:Bool?=nil
    var is_system_default:Bool?=nil
}
struct RemindersProductCatalog: Codable, Sendable {
    let sources:[RemindersProductSource]
    let lists:[RemindersProductList]
    var system_default_list_id:String?=nil
    func validate() throws {
        guard sources.count<=100,lists.count<=200,Set(sources.map(\.id)).count==sources.count,Set(lists.map(\.id)).count==lists.count,
              lists.allSatisfy({row in sources.contains(where:{$0.id==row.source_id})}) else {throw RemindersTransportFault("catalog_limit")}
        for id in sources.map(\.id)+lists.map(\.id)+lists.map(\.source_id) {
            guard !id.isEmpty,id.utf8.count<=1024,!id.unicodeScalars.contains(where:{$0.value<32}) else {throw RemindersTransportFault("invalid_catalog")}
        }
        guard sources.allSatisfy({$0.title.utf8.count<=1024}),lists.allSatisfy({$0.title.utf8.count<=1024}) else {throw RemindersTransportFault("catalog_limit")}
    }
}
struct RemindersProductTarget: Codable, Equatable, Sendable {
    let source:RemindersProductSource
    let list:RemindersProductList?
    let helper_requirement_sha256:String
    let policy_sha256:String
}
struct RemindersProductRecord: Codable, Sendable {
    let task_id:String
    let operation_id:String
    let request_sha256:String
    let request_json:String
    let target:RemindersProductTarget
    var state:String
    var code:String
    var result_json:String?
}
struct RemindersProductReply: Codable, Sendable {
    let schema_version:Int
    let capability_id:String
    let request_id:String
    let action:RemindersProductAction
    let identity:RemindersFirstIdentity
    let policy_sha256:String
    var outcome:String
    var code:String
    var catalog:RemindersProductCatalog?
    var target:RemindersProductTarget?
    // A preference, never an access grant or an implicit read filter.
    var default_target:RemindersProductTarget?
    var default_status:String?
    var read_scope:String?
    var task:RemindersProductRecord?
    var result_json:String?
    var history:[RemindersProductSummary]?
    var next_offset:Int?
    var automatic_replay:Bool=false
    var business_log_available:Bool?=nil
    var result:RemindersProductResult? {result_json.flatMap{try? JSONDecoder().decode(RemindersProductResult.self,from:Data($0.utf8))}}
}
struct RemindersProductSummary:Codable,Identifiable,Sendable {
    let task_id:String;let title:String;let state:String;let code:String
    var id:String{task_id}
}
struct RemindersProductDate: Codable, Equatable, Sendable {let kind:String;let value:String;let time_zone:String?}
struct RemindersProductRichField: Codable, Sendable {let editable:Bool;let descriptors:[[String:String]]}
struct RemindersProductItem: Codable, Identifiable, Sendable {
    let id:String;let list_id:String;let title:String;let notes:String?;let priority:Int;let completed:Bool
    let completion_date:String?;let modified:String?;let due:RemindersProductDate?;let start:RemindersProductDate?
    let due_components:[String:String];let start_components:[String:String]
    let recurrence:RemindersProductRichField;let alerts:RemindersProductRichField;let url:String?;let location:String?;let revision:String
}
struct RemindersProductDeletion: Codable, Sendable {let id:String;let list_id:String;let expected_revision:String}
struct RemindersProductResult: Codable, Sendable {
    let schema_version:Int;let status:String
    let sources:[RemindersProductSource]?;let lists:[RemindersProductList]?;let list:RemindersProductList?
    let reminders:[RemindersProductItem]?;let reminder:RemindersProductItem?
    let deletion:RemindersProductDeletion?
    let operation_id:String?;let persistence:String?;let cloud_sync:String?
}

enum RemindersProductCopy {
    static func message(_ reply:RemindersProductReply)->String {
        switch reply.code {
        case "deleted_local": return "本机已删除这条提醒；云同步尚未核验。"
        case "recurring_delete_unsupported": return "重复提醒不支持单项删除，请在系统提醒事项中核对。"
        case "saved_local": return "本机已保存；云同步尚未核验。"
        case "target_selected": return "已设置默认清单；显式指定的清单优先。"
        case "stored_selection": return "已恢复默认清单；读取范围由本次请求决定。"
        case "ok": return "已读取。"
        case "target_required", "default_list_required": return "未指定新建清单，请先设置默认清单。"
        case "default_list_unavailable": return "默认清单已不可写，请重新设置；仍可显式指定其他清单。"
        case "needs_permission": return "请先允许访问提醒事项。"
        case "revision_conflict": return "这条提醒已有变化，请重新打开后编辑。"
        case "operation_missing": return "尚无这条操作记录。"
        case "outcome_unknown": return "保存结果待核；同一任务不会再次执行。"
        case "idempotency_conflict": return "任务编号已绑定另一份内容，请查看原操作。"
        default: return "操作未完成："+reply.code
        }
    }
}

enum RemindersProductContract {
    static func operationID(_ taskID:String)->String {
        let h=Array(RemindersNativeIO.hash(Data(("arl.reminders.product.v1:"+taskID).utf8)).prefix(32))
        return String(h[0..<8])+"-"+String(h[8..<12])+"-"+String(h[12..<16])+"-"+String(h[16..<20])+"-"+String(h[20..<32])
    }
}
