import Foundation
@MainActor private final class F1LateFixture {
    let scope=UUID().uuidString.lowercased(),job=UUID()
    var submissions:[UUID]=[],inputs:[String]=[],gets=0,getStarted=false,releaseGet=false,cancels=0
    func json(_ v:[String:Any])throws->ARLJSON{try JSONDecoder().decode(ARLJSON.self,from:JSONSerialization.data(withJSONObject:v))}
    func status()throws->CodexServiceStatus{try CodexServiceStatus.decode(json(["schema_version":1,"state":"ready","caller":"arl-control","model":CodexScopeOwner.model,"scope_generation":scope,"route_enabled":true,"reasoning_effort":"xhigh","service_tier":"default","execution_preferences_verified":true,"checked_at_ms":1,"stale_after_ms":90000,"last_error_code":NSNull(),"last_inference_at_ms":NSNull(),"inference_verified":false,"max_pending":1,"remaining_calls":32,"max_calls":32,"max_input_bytes":8192,"max_output_bytes":32768,"max_wall_ms":30000,"token_hard_cap_supported":false,"cost_hard_cap_supported":false,"simulated":true]))}
    func reply(_ state:String,_ updated:Double)throws->CodexTaskReply{try CodexTaskReply.decode(json(["id":job.uuidString.lowercased(),"tool":"codex.text.plan.v1","state":state,"attempts":1,"result":state=="succeeded" ? ["provider":"codex_app_server","model":CodexScopeOwner.model,"text":"synthetic second result","simulated":true] as Any:NSNull(),"error":NSNull(),"updated":updated]),model:CodexScopeOwner.model)}
    var port:CodexNativeController.Port{.init(status:{try self.status()},submit:{input,id in self.inputs.append(input);self.submissions.append(id);return try self.reply(self.submissions.count==1 ? "running":"succeeded",self.submissions.count==1 ? 1:3)},get:{id in precondition(id==self.job);self.gets += 1;self.getStarted=true;let end=ContinuousClock.now.advanced(by:.seconds(2));while !self.releaseGet{precondition(ContinuousClock.now<end);try await Task.sleep(for:.milliseconds(2))};return try self.reply("running",1)},cancel:{id in precondition(id==self.job);self.cancels += 1;return try self.reply("cancelled",2)})}
}

private enum F1RecoveryFailure:Error {case assertion(String)}
@MainActor private func exerciseLateReceiptRecovery(home:URL, viaNewIntent:Bool) async throws -> Int {
    var checks=0
    func check(_ value:Bool,_ label:String)throws {guard value else{throw F1RecoveryFailure.assertion(label)};checks+=1}
    func wait(_ condition:()->Bool)async throws {let end=ContinuousClock.now.advanced(by:.seconds(4));while !condition(){guard ContinuousClock.now<end else{throw F1RecoveryFailure.assertion("finite probe")};try await Task.sleep(for:.milliseconds(5))}}
    try check(!FileManager.default.fileExists(atPath:home.path),"fresh fixture")
    try FileManager.default.createDirectory(at:home,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
    let f=F1LateFixture(),c=CodexNativeController(home:home,enabled:true,port:f.port)
    await c.refreshStatus();c.submit("synthetic first intent");try await wait{f.getStarted}
    c.requestCancel();try await wait{c.taskRecord?.phase=="cancelled" && c.taskRecord?.outputLogged==true && f.cancels==1}
    let original=c.taskRecord!.operationID,journal=home.appendingPathComponent("codex-business-v1.noindex")
    try FileManager.default.setAttributes([.posixPermissions:0o750],ofItemAtPath:journal.path);f.releaseGet=true;try await wait{!c.busy}
    try check(c.errorCode=="business_log_unavailable" && c.pendingReceiptCount==1,"explicit deferred audit error")
    try check(c.taskRecord?.phase=="cancelled" && c.taskRecord?.reply?.updated==2 && c.taskRecord?.outputLogged==true,"real terminal and its logged flag remain true")
    try check(c.canSubmit && c.message?.contains("只能") != true,"a true new intent remains allowed without false exclusive-recovery hint")
    let tasks=home.appendingPathComponent("codex-tasks-v1.noindex")
    let pending=try FileManager.default.contentsOfDirectory(at:tasks,includingPropertiesForKeys:nil).filter{$0.lastPathComponent.hasPrefix("pending-receipt-")}
    try check(pending.count==1,"one durable original late receipt")
    let row=try JSONSerialization.jsonObject(with:Data(contentsOf:pending[0])) as! [String:Any]
    let saved=Data(base64Encoded:row["response"] as! String)!,savedArgs=Data(base64Encoded:row["arguments"] as! String)!
    let raw=try JSONSerialization.jsonObject(with:saved) as! [String:Any],args=try JSONSerialization.jsonObject(with:savedArgs) as! [String:Any]
    try check(raw["state"] as? String=="running" && (raw["updated"] as? NSNumber)?.doubleValue==1 && row["action"] as? String=="get","older receipt is retained independently")
    try check(UUID(uuidString:row["operationID"] as! String)==original && UUID(uuidString:args["operation_id"] as! String)==original,"pending receipt retains original operation and full args")
    let reopened=CodexNativeController(home:home,enabled:true,port:f.port);await reopened.refreshStatus()
    try check(reopened.canSubmit && reopened.taskRecord?.operationID==original && reopened.pendingReceiptCount==1 && reopened.errorCode=="business_log_unavailable","reopen exposes gap without blocking true new intents")
    reopened.inspectOriginal();try await wait{!reopened.busy}
    try check(reopened.canSubmit && reopened.pendingReceiptCount==1 && reopened.taskRecord?.phase=="cancelled","failed repair preserves terminal and recoverable gap")
    try check(f.submissions.count==1 && f.gets==1 && f.cancels==1,"audit repair never resubmits, cancels or requeries provider")
    try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:journal.path)
    let repaired=CodexNativeController(home:home,enabled:true,port:f.port);await repaired.refreshStatus()
    try check(repaired.canSubmit && repaired.pendingReceiptCount==1,"repairing filesystem does not silently discard gap")
    if viaNewIntent {repaired.submit("synthetic genuinely new intent")}
    else {repaired.inspectOriginal()}
    try await wait{!repaired.busy}
    try check(repaired.pendingReceiptCount==0 && repaired.errorCode==nil,"explicit action repairs exact pending receipt")
    let segments=try FileManager.default.contentsOfDirectory(at:journal,includingPropertiesForKeys:nil).filter{$0.lastPathComponent.hasSuffix(".jsonl.noindex")}
    let records=try segments.flatMap{try String(contentsOf:$0,encoding:.utf8).split(separator:"\n").map{try JSONSerialization.jsonObject(with:Data($0.utf8)) as! [String:Any]}}
    try check(records.contains{$0["action"] as? String=="get" && $0["response_text"] as? String==String(decoding:saved,as:UTF8.self) && $0["arguments_text"] as? String==String(decoding:savedArgs,as:UTF8.self)},"byte-identical late args and receipt reach real journal")
    if !viaNewIntent {
        try check(repaired.taskRecord?.operationID==original && repaired.taskRecord?.phase=="cancelled" && f.submissions.count==1 && f.gets==1,"old terminal recovery is local audit-only")
        repaired.submit("synthetic genuinely new intent");try await wait{!repaired.busy}
    }
    try check(f.submissions.count==2 && Set(f.submissions).count==2 && f.inputs==["synthetic first intent","synthetic genuinely new intent"],"only explicit different new input uses second UUID")
    try check(f.gets==1 && f.cancels==1,"new intent does not replay old operation")
    let final=CodexNativeController(home:home,enabled:true,port:f.port);await final.refreshStatus()
    try check(final.canSubmit && final.pendingReceiptCount==0 && final.errorCode==nil,"reopen after repair is clear")
    return checks
}

@MainActor @main enum CodexSharedConsumerTests {
    enum Failure: Error { case assertion(String) }
    static var checks = 0
    static func expect(_ value: Bool, _ name: String) throws { guard value else { throw Failure.assertion(name) }; checks += 1 }
    static func json(_ value: [String: Any]) throws -> ARLJSON { try JSONDecoder().decode(ARLJSON.self, from: JSONSerialization.data(withJSONObject: value)) }
    static func object(_ bytes: Data) throws -> [String: Any] { try OwnerReadJSON.object(bytes, limit: 131072, maximumDepth: 32) }
    @MainActor final class Fixture {
        let scope = UUID().uuidString.lowercased(), job = UUID()
        var submissions: [(String, UUID)] = [], gets = 0, cancels = 0
        var loseAck = false, ongoing = false, cancelled = false
        func status() throws -> CodexServiceStatus {
            try CodexServiceStatus.decode(CodexSharedConsumerTests.json(["schema_version":1,"state":"ready","caller":"arl-control","model":CodexScopeOwner.model,
                "scope_generation":scope,"route_enabled":true,"reasoning_effort":"xhigh","service_tier":"default","execution_preferences_verified":true,
                "checked_at_ms":1,"stale_after_ms":90000,"last_error_code":NSNull(),"last_inference_at_ms":NSNull(),"inference_verified":false,
                "max_pending":1,"remaining_calls":32,"max_calls":32,"max_input_bytes":8192,"max_output_bytes":32768,"max_wall_ms":30000,
                "token_hard_cap_supported":false,"cost_hard_cap_supported":false,"simulated":false]))
        }
        func reply(_ state: String) throws -> CodexTaskReply {
            let result: Any = state == "succeeded" ? ["provider":"codex_app_server","model":CodexScopeOwner.model,"text":"完整原始返回\n尾部", "simulated":true] : NSNull()
            return try CodexTaskReply.decode(CodexSharedConsumerTests.json(["id":job.uuidString.lowercased(),"tool":"codex.text.plan.v1","state":state,"attempts":1,
                "result":result,"error":NSNull(),"updated":state == "running" ? 1.0 : 2.0,
                "progress":["phase":state == "running" ? "running":"terminal","turn_sent":true,
                    "native":["interrupt":cancelled ? "acknowledged":"not_requested","terminal":cancelled ? "interrupted":state == "succeeded" ? "completed":"unknown"]]]), model:CodexScopeOwner.model)
        }
        var port: CodexNativeController.Port {
            .init(status:{ try self.status() }, submit:{ input, id in
                self.submissions.append((input,id))
                if self.loseAck { self.loseAck=false;throw ARLError(code:"disconnected") }
                return try self.reply("running")
            }, get:{ id in
                try CodexSharedConsumerTests.expect(id == self.job,"same original job queried")
                self.gets += 1
                return try self.reply(self.cancelled ? "cancelled":self.ongoing ? "running":"succeeded")
            }, cancel:{ id in
                try CodexSharedConsumerTests.expect(id == self.job,"same original job cancelled")
                self.cancels += 1;self.cancelled=true;return try self.reply("cancelled")
            })
        }
    }
    static func wait(_ controller: CodexNativeController) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 4
        while controller.busy && ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(for:.milliseconds(10)) }
        try expect(!controller.busy,"finite controller operation finished")
    }
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else { throw Failure.assertion("new fixture directory required") }
        let root = URL(fileURLWithPath:CommandLine.arguments[1]);try expect(!FileManager.default.fileExists(atPath:root.path),"fresh fixture")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        var index=0
        func home() throws -> URL {index+=1;let p=root.appendingPathComponent("case-\(index)");try FileManager.default.createDirectory(at:p,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700]);return p}
        let first = try CodexScopeOwner.configuration(previous:nil,manifest:String(repeating:"a",count:64),requirement:"synthetic reviewed requirement")
        let repeated = try CodexScopeOwner.configuration(previous:first,manifest:String(repeating:"a",count:64),requirement:"synthetic reviewed requirement")
        try expect(first == repeated,"same installed scope persists identical generation and bytes")
        let rotated = try CodexScopeOwner.configuration(previous:first,manifest:String(repeating:"b",count:64),requirement:"synthetic reviewed requirement")
        try expect(try object(first)["scope_generation"] as? String != object(rotated)["scope_generation"] as? String,"changed package authority rotates scope")
        var invalid = try object(first);invalid["model"]="other-model"
        do {_ = try CodexScopeOwner.configuration(previous:JSONSerialization.data(withJSONObject:invalid),manifest:String(repeating:"a",count:64),requirement:"synthetic reviewed requirement");throw Failure.assertion("model switched")}
        catch let e as ARLError {try expect(e.code == "codex_scope_review_required","no automatic model change")}
        let h = try home(), f = Fixture(), c = CodexNativeController(home:h,enabled:true,port:f.port)
        try expect(f.submissions.isEmpty && !FileManager.default.fileExists(atPath:h.appendingPathComponent(CodexScopeOwner.filename).path),"initialization neither grants scope nor submits")
        await c.refreshStatus();try expect(c.canSubmit && c.status?.inference_verified == false,"protocol ready is separate from successful inference")
        let text="原始输入，不裁剪。\n尾部  "
        c.submit(text);try await wait(c)
        try expect(f.submissions.count == 1 && f.submissions[0].0 == text && c.taskRecord?.reply?.text == "完整原始返回\n尾部","full explicit input and output retained")
        let original = c.taskRecord!.operationID
        let reopened = CodexNativeController(home:h,enabled:true,port:f.port)
        try expect(reopened.taskRecord?.operationID == original && f.submissions.count == 1,"reopen restores same task without submission")
        let files=try FileManager.default.contentsOfDirectory(at:h.appendingPathComponent("codex-business-v1.noindex"),includingPropertiesForKeys:nil).filter{$0.lastPathComponent.hasSuffix(".jsonl.noindex")}
        let records=try files.flatMap{try String(contentsOf:$0,encoding:.utf8).split(separator:"\n").map{try object(Data($0.utf8))}}
        try expect(records.contains{($0["arguments_text"] as? String)?.contains("原始输入") == true} && records.contains{($0["response_text"] as? String)?.contains("尾部") == true},"actual eight-day journal keeps full user input and native result")
        let lostHome=try home(), lost=Fixture();lost.loseAck=true
        let uncertain=CodexNativeController(home:lostHome,enabled:true,port:lost.port);await uncertain.refreshStatus();uncertain.submit(text);try await wait(uncertain)
        let id=uncertain.taskRecord!.operationID
        try expect(lost.submissions.count == 1 && uncertain.taskRecord?.jobID == nil && !uncertain.canSubmit,"lost acknowledgement cannot enable another key")
        let restored=CodexNativeController(home:lostHome,enabled:true,port:lost.port);await restored.refreshStatus()
        try expect(lost.submissions.count == 1,"status and restoration cannot resend")
        restored.inspectOriginal();try await wait(restored)
        try expect(lost.submissions.count == 2 && lost.submissions.allSatisfy{$0.1 == id && $0.0 == text},"explicit recovery uses exact same UUID and original body")
        let inputFailureHome=try home(), inputFailure=Fixture()
        try Data("not a directory".utf8).write(to:inputFailureHome.appendingPathComponent("codex-business-v1.noindex"))
        let blocked=CodexNativeController(home:inputFailureHome,enabled:true,port:inputFailure.port);await blocked.refreshStatus();blocked.submit(text);try await wait(blocked)
        try expect(inputFailure.submissions.isEmpty && blocked.errorCode == "business_log_unavailable","input journal failure precedes provider call")
        let cancelHome=try home(), cancel=Fixture();cancel.ongoing=true
        let cancelling=CodexNativeController(home:cancelHome,enabled:true,port:cancel.port);await cancelling.refreshStatus();cancelling.submit(text)
        let deadline=ProcessInfo.processInfo.systemUptime+2
        while cancelling.taskRecord?.jobID == nil && ProcessInfo.processInfo.systemUptime<deadline {try await Task.sleep(for:.milliseconds(5))}
        cancelling.suspendForExit();try await wait(cancelling)
        try expect(cancel.submissions.count == 1 && cancel.cancels == 1 && cancelling.taskRecord?.phase == "cancelled","exit asks cancellation of original in-flight job")
        try expect(cancelling.taskRecord?.reply?.text == nil,"cancelled task never publishes generated text")
        let preview=Fixture(), disabled=CodexNativeController(home:try home(),enabled:false,port:preview.port);await disabled.refreshStatus();disabled.submit(text)
        try expect(!disabled.canSubmit && preview.submissions.isEmpty && disabled.status == nil,"disabled/demo composition has no model/status action")
        checks += try await exerciseLateReceiptRecovery(home:try home().appendingPathComponent("late-inspect"),viaNewIntent:false)
        checks += try await exerciseLateReceiptRecovery(home:try home().appendingPathComponent("late-new"),viaNewIntent:true)
        print("PASS Codex shared controller/scope \(checks) checks; synthetic client only; real turns/install/config writes = 0")
    }
}
