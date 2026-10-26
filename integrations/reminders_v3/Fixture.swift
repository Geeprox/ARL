import Foundation
import ARLRemindersCore
@main struct RemindersPermissionFixture {
    static func main() async throws {
        precondition(RemindersV3PermissionIntegration.capabilityIDs.count == 11)
        var checks=1
        for (status,expected) in [("full_access","authorized_full"),("not_determined","not_determined"),("denied","denied"),("restricted","restricted"),("write_only","unknown"),("unknown","unknown")] {
            precondition(RemindersV3PermissionIntegration.classifyOwnerAuthorization(status).state == expected);checks+=1
        }
        precondition(RemindersV3PermissionIntegration.capabilityIDs.contains("apple.reminders.list.create.v3"));checks+=1
        precondition(RemindersV3PermissionIntegration.capabilityIDs.contains("apple.reminders.delete.v3"));checks+=1
        precondition(!RemindersV3PermissionIntegration.capabilityIDs.contains("apple.reminders.list.delete.v3"));checks+=1
        let identity=NativePermissionIdentity(helper_bundle_id:"local.arl.remindersbridge",executable_sha256:String(repeating:"a",count:64),designated_requirement_sha256:String(repeating:"b",count:64))
        for extra in [["schema_version":true,"capability_id":"apple.reminders.create.v3","action":"request","request_id":UUID().uuidString.lowercased()], ["schema_version":1,"capability_id":"apple.reminders.delete.v3","action":"request","request_id":UUID().uuidString.lowercased()], ["schema_version":1,"capability_id":"apple.reminders.create.v3","action":"request","request_id":UUID().uuidString.lowercased(),"approved":true], ["schema_version":1,"capability_id":"apple.reminders.create.v3","action":"request","request_id":UUID().uuidString.lowercased()]] as [[String:Any]] {
            let reply=await RemindersV3PermissionIntegration.handlePermissionRequest(frame:try JSONSerialization.data(withJSONObject:extra),kernelPeerAuditToken:Data(),pinnedControlRequirement:"identifier \"local.arl.control\"",approvedHelperIdentity:identity,cancelled:{false})
            let object=try JSONSerialization.jsonObject(with:reply) as! [String:Any]
            precondition(object["outcome"] as? String == "unavailable");checks+=1
        }
        checks += try twoSaveSlice()
        print("reminders_v3_permission_bridge_checks=\(checks); fixture_saves=2; EventKitStore_created=0; prompts=0; native_effects=0")
    }
    /// Exercise the actual permission-owner operation facade and durable owner
    /// journal, with synthetic repository injection rather than EventKit data.
    static func twoSaveSlice() throws -> Int {
        let parent=FileManager.default.temporaryDirectory.appendingPathComponent("arl-permission-v3-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:parent,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        defer {try? FileManager.default.removeItem(at:parent)}
        let journal=parent.appendingPathComponent("journal")
        let repository=FixtureRepository()
        let host=try RemindersV3PermissionIntegration(privateJournalDirectory:journal,repository:repository)
        var allowedLists=Set<String>()
        func call(_ tool:String,_ args:[String:Any],allowed:Bool=true,using facade:RemindersV3PermissionIntegration?=nil) throws -> Response {
            let wire=try JSONSerialization.data(withJSONObject:["tool":"apple.reminders.\(tool).v3","args":args])
            let request=try Request.decode(wire)
            let authority=HostAuthority(owner:"isolated-two-save-fixture",requestDigest:try digest(request),key:request.args.operation_id ?? "fixture-read",expires:Date().addingTimeInterval(60),allowedTools:allowed ? [request.tool]:[],listIDs:allowedLists,sourceIDs:["fixture-source"],checkCancelled:{})
            return try JSONDecoder().decode(Response.self,from:(facade ?? host).callReviewedOperation(requestJSON:wire,authority:authority))
        }
        let listArgs:[String:Any]=["operation_id":"c7ed8df4-90e2-42e7-8871-58a5ef26d1fe","source_id":"fixture-source","title":"ARL adapter smoke isolated-fixture"]
        do {_ = try call("list.create",listArgs,allowed:false);preconditionFailure("OS permission must not create operation authority")}
        catch let error as AdapterFault {precondition(error.code == "review_not_authorized")}
        precondition(repository.saveAttempts == 0)
        let list=try call("list.create",listArgs).list!
        allowedLists.insert(list.id)
        let byID=try call("list.lookup",["selector":["id":list.id]]).list
        precondition(byID == list)
        let byTitle=try call("list.lookup",["selector":["title":list.title,"source_id":"fixture-source"]]).list
        precondition(byTitle == list)
        let create:[String:Any]=["operation_id":"8a845e3f-8efb-498e-93df-8ba4a0b752eb","list_id":list.id,"title":"ARL synthetic smoke","patch":["due":["action":"set","value":["kind":"date","value":"2099-10-02"]]]]
        let item=try call("create",create).reminder!
        precondition(repository.saveAttempts == 2)
        let restarted=try RemindersV3PermissionIntegration(privateJournalDirectory:journal,repository:repository)
        let replayed=try call("create",create,using:restarted).reminder
        precondition(replayed == item)
        precondition(repository.saveAttempts == 2)
        let readback=try call("get",["list_id":list.id,"reminder_id":item.id]).reminder!
        let query=try call("query",["list_id":list.id,"include_completed":true]).reminders!
        precondition(query == [readback] && !readback.completed && readback.due?.value == "2099-10-02" && readback.start == nil && readback.recurrence.descriptors.isEmpty && readback.alerts.descriptors.isEmpty)
        let records=try FileManager.default.contentsOfDirectory(at:journal,includingPropertiesForKeys:nil).filter {$0.pathExtension == "json"}
        precondition(records.count == 2)
        return 9
    }
}
