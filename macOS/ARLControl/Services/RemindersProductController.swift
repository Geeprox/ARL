import Foundation
import Observation

@MainActor @Observable final class RemindersProductController {
    struct Port {
        let begin:(UUID)->Bool
        let end:(UUID)->Void
        let ensureService:()async throws->Void
        let send:(RemindersProductFrame)async throws->RemindersProductReply
        let record:(String,UUID,Data,Data?)throws->Void
    }
    let port:Port
    private(set) var busy=false
    private(set) var catalog:RemindersProductCatalog?
    // UI preference only. Reply targets describe individual requests.
    private(set) var target:RemindersProductTarget?
    var defaultTarget:RemindersProductTarget? {target}
    private(set) var items:[RemindersProductItem]=[]
    private(set) var task:RemindersProductRecord?
    private(set) var message:String?
    private(set) var businessLogAvailable=true
    private(set) var pendingTaskID:String?
    private(set) var operationIDs:[String]=[]
    private(set) var history:[RemindersProductSummary]=[]
    private(set) var historyNextOffset:Int?
    init(port:Port) {
        self.port=port
        pendingTaskID=UserDefaults.standard.string(forKey:"remindersProductPendingV1").flatMap{RemindersTaskContract.uuid($0) ? $0:nil}
        operationIDs=(UserDefaults.standard.stringArray(forKey:"remindersProductOperationsV1") ?? []).filter{RemindersTaskContract.uuid($0)}
        if let pendingTaskID,!operationIDs.contains(pendingTaskID) {operationIDs.append(pendingTaskID)}
    }
    @discardableResult func execute(_ frame:RemindersProductFrame,tool:String="reminders.product",argumentsJSON:Data?=nil)async throws->RemindersProductReply {
        let id=UUID(uuidString:frame.request_id)!
        guard !busy,port.begin(id) else{throw RemindersTransportFault("owner_busy")}
        busy=true;message=nil;defer{busy=false;port.end(id)}
        let arguments=try argumentsJSON ?? JSONEncoder().encode(frame)
        do{try port.record(tool,id,arguments,nil)}catch{businessLogAvailable=false}
        do {
            if frame.action != .status && frame.action != .history && frame.action != .selection {try await port.ensureService()}
            if frame.action == .submit {
                pendingTaskID=frame.task_id
                if let id=frame.task_id,!operationIDs.contains(id) {operationIDs.append(id);UserDefaults.standard.set(operationIDs,forKey:"remindersProductOperationsV1")}
                UserDefaults.standard.set(frame.task_id,forKey:"remindersProductPendingV1")
            }
            var reply=try await port.send(frame)
            apply(reply,frame:frame)
            do{try port.record(tool,id,arguments,try JSONEncoder().encode(reply))}catch{businessLogAvailable=false}
            reply.business_log_available=businessLogAvailable
            return reply
        } catch {
            let code=(error as? RemindersTransportFault)?.code ?? "transport_unavailable"
            message=frame.action == .submit ? "本次结果未确认，请查看原操作记录（"+(frame.task_id ?? "")+"）。":"操作未完成："+code
            let raw=try? JSONSerialization.data(withJSONObject:["code":code,"task_id":frame.task_id ?? "","automatic_replay":false])
            do{try port.record(tool,id,arguments,raw)}catch{businessLogAvailable=false}
            throw error
        }
    }
    private func apply(_ reply:RemindersProductReply,frame:RemindersProductFrame) {
        message=RemindersProductCopy.message(reply)
        if let catalog=reply.catalog {self.catalog=catalog}
        if [.catalog,.select,.selection].contains(reply.action) {
            // Only preference responses update the UI default. A Mio read or
            // write to another list must not silently change the default.
            target=reply.default_target ?? reply.target
        }
        if let task=reply.task {self.task=task;pendingTaskID=task.task_id}
        if let history=reply.history {
            if frame.offset==0 {self.history=history}
            else {
                for row in history {
                    if let index=self.history.firstIndex(where:{$0.id==row.id}) {self.history[index]=row}
                    else {self.history.append(row)}
                }
            }
            historyNextOffset=reply.next_offset
        }
        if let result=reply.result {
            if let rows=result.reminders {items=rows}
            if let item=result.reminder {
                if let index=items.firstIndex(where:{$0.id==item.id}) {items[index]=item}
                else if item.list_id==target?.list?.id {items.insert(item,at:0)}
            }
        }
    }
    func restoreSelection() {run(.init(.selection))}
    func discover() {run(.init(.catalog))}
    func select(sourceID:String,listID:String?) {run(.init(.select,sourceID:sourceID,listID:listID))}
    func query(listID:String?=nil,includeCompleted:Bool=false) {
        var args:[String:Any]=["include_completed":includeCompleted]
        if let listID {args["list_id"]=listID}
        do{run(try Self.readFrame("query",args:args))}catch{message="请求无效。"}
    }
    func refreshHistory(more:Bool=false) {run(.init(.history,offset:more ? historyNextOffset ?? 0:0))}
    func refreshOperation() {if let id=pendingTaskID {run(.init(.status,taskID:id))}}
    func submit(_ operation:String,taskID:String,args:[String:Any]) {
        do {run(try Self.mutationFrame(operation,taskID:taskID,args:args))}catch{message="请检查填写内容。"}
    }
    func run(_ frame:RemindersProductFrame) {
        guard !busy else{return}
        Task {do{_ = try await execute(frame)}catch{}}
    }
    static func readFrame(_ operation:String,args:[String:Any])throws->RemindersProductFrame {
        .init(.read,requestJSON:String(decoding:try JSONSerialization.data(withJSONObject:["tool":"apple.reminders."+operation+".v3","args":args],options:[.sortedKeys]),as:UTF8.self))
    }
    static func mutationFrame(_ operation:String,taskID:String,args:[String:Any])throws->RemindersProductFrame {
        guard RemindersTaskContract.uuid(taskID),["list.create","create","update","complete","uncomplete","delete"].contains(operation) else{throw RemindersTransportFault("invalid_arguments")}
        var args=args;args["operation_id"]=RemindersProductContract.operationID(taskID)
        return .init(.submit,taskID:taskID,requestJSON:String(decoding:try JSONSerialization.data(withJSONObject:["tool":"apple.reminders."+operation+".v3","args":args],options:[.sortedKeys]),as:UTF8.self))
    }
}
