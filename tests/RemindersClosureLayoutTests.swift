import Foundation

@main struct RemindersClosureLayoutTests {
    static func main() throws {
        let legacy=try RemindersNativeDeployment.expectedClosure(linkage:nil)
        let staticallyLinked=try RemindersNativeDeployment.expectedClosure(linkage:"static")
        precondition(legacy.count==5 && staticallyLinked.count==3)
        precondition(staticallyLinked.isSubset(of:legacy))
        precondition(legacy.subtracting(staticallyLinked)==["Contents/Frameworks/libARLRemindersCore.dylib","Contents/Frameworks/libARLRemindersEventKit.dylib"])
        for invalid in ["dynamic","STATIC","",1,true,NSNull()] as [Any] {
            do {_ = try RemindersNativeDeployment.expectedClosure(linkage:invalid);fatalError("unknown layout admitted")}
            catch let error as RemindersTransportFault {precondition(error.code=="identity_changed_closure")}
        }
        let shutdown = RemindersFirstFrame(action:.shutdown,requestID:UUID())
        let encoded = try JSONEncoder().encode(shutdown)
        let decoded = try RemindersFirstFrame.decode(encoded)
        precondition(decoded.action == .shutdown && decoded.request_id == shutdown.request_id)
        // A lifecycle request must never borrow an operation capability/grant.
        let borrowed = RemindersFirstFrame(action:.shutdown,requestID:UUID(),capability:"apple.reminders.create.v3")
        do { _ = try RemindersFirstFrame.decode(JSONEncoder().encode(borrowed));fatalError("shutdown admitted on operation capability") }
        catch let error as RemindersTransportFault { precondition(error.code == "invalid_arguments") }
        let hash = String(repeating:"a",count:64)
        let deployment = RemindersNativeDeployment(schema_version:1,helper_bundle_path:"/fixture/ARLRemindersBridge.app",host_home:"/fixture",control_requirement:"fixture",helper_requirement:"fixture",helper_executable_sha256:hash,helper_designated_requirement_sha256:hash,closure_sha256:hash,policy_sha256:hash)
        let reply = RemindersFirstReply(schema_version:1,request_id:shutdown.request_id,action:.shutdown,outcome:"completed",code:"shutdown_requested",snapshot:nil)
        _ = try RemindersNativeClient.admitReply(JSONEncoder().encode(reply),for:shutdown,deployment:deployment)
        let wrongRequest = RemindersFirstFrame(action:.shutdown,requestID:UUID())
        do { _ = try RemindersNativeClient.admitReply(JSONEncoder().encode(reply),for:wrongRequest,deployment:deployment);fatalError("stale shutdown reply admitted") }
        catch let error as RemindersTransportFault { precondition(error.code == "invalid_response") }
        print("Reminders shutdown protocol PASS: first capability only; exact request correlation; no OS calls")
        print("Reminders closure layout PASS: legacy5/static3, unknown layouts reject; no Security/EventKit call")
    }
}
