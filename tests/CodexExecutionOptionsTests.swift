import Foundation

@main @MainActor enum CodexExecutionOptionsTests {
    static var checks = 0
    static func check(_ condition: Bool, _ name: String) { precondition(condition, name); checks += 1 }
    static func json(_ value: [String: Any]) throws -> ARLJSON { try JSONDecoder().decode(ARLJSON.self, from: JSONSerialization.data(withJSONObject: value)) }
    static func wait(_ c: CodexNativeController) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(3))
        while c.busy { precondition(ContinuousClock.now < end); try await Task.sleep(for: .milliseconds(10)) }
    }
    @MainActor final class Fixture {
        let scope = UUID().uuidString.lowercased(), job = UUID()
        var selections: [CodexExecutionSelection] = [], ids: [UUID] = [], loseAck = false, wrongReceipt = false
        var models: [[String: Any]] { [
            ["model":CodexScopeOwner.model,"display_name":"Current","description":"offline","default_effort":"medium", "efforts":[["id":"medium","description":"default"],["id":"xhigh","description":"deep"]],"fast_available":true,"fast_description":"catalog Fast"],
            ["model":"synthetic-small","display_name":"Small","description":"offline","default_effort":"low", "efforts":[["id":"low","description":"light"]],"fast_available":false,"fast_description":""]] }
        func status() throws -> CodexServiceStatus {
            try CodexServiceStatus.decode(json(["schema_version":1,"state":"ready","caller":"arl-control","model":CodexScopeOwner.model,"scope_generation":scope,"route_enabled":true,
                "reasoning_effort":"xhigh","service_tier":"default","execution_preferences_verified":true,"checked_at_ms":1,"stale_after_ms":90000,"last_error_code":NSNull(),
                "last_inference_at_ms":NSNull(),"inference_verified":false,"max_pending":1,"remaining_calls":32,"max_calls":32,"max_input_bytes":8192,"max_output_bytes":32768,"max_wall_ms":30000,
                "token_hard_cap_supported":false,"cost_hard_cap_supported":false,"simulated":true,
                "execution_catalog":["schema_version":1,"source":"test_double","models":models,"selection_enabled":true,
                    "current":["model":CodexScopeOwner.model,"reasoning_effort":"xhigh","service_tier":"default"]]]))
        }
        func reply(_ selection: CodexExecutionSelection) throws -> CodexTaskReply {
            try CodexTaskReply.decode(json(["id":job.uuidString.lowercased(),"tool":"codex.text.plan.v1","state":"succeeded","attempts":1,
                "result":["provider":"codex_app_server","model":selection.model,"text":"offline receipt", "execution_preferences":["reasoning_effort":selection.reasoning_effort,"service_tier":wrongReceipt ? "wrong" : selection.service_tier,"source":"test_double"]],"error":NSNull(),"updated":2]), model:selection.model)
        }
        var port: CodexNativeController.Port {
            .init(status:{ try self.status() },submit:{ _,_ in preconditionFailure("selection path required") },get:{ _ in try self.reply(self.selections.last!) },cancel:{ _ in try self.reply(self.selections.last!) },
                submitSelection:{ _, id, value in
                    self.ids.append(id); self.selections.append(value)
                    if self.loseAck { self.loseAck = false; throw ARLError(code:"disconnected") }
                    return try self.reply(value)
                })
        }
    }
    static func main() async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        let f=Fixture(),c=CodexNativeController(home:root,enabled:true,port:f.port)
        await c.refreshStatus();check(c.executionSelection?.reasoning_effort == "xhigh", "read existing service configuration")
        let catalog=c.executionCatalog!;check(catalog.isValid,"validate dynamic catalog")
        let chosen=CodexExecutionSelection(model:CodexScopeOwner.model,reasoning_effort:"medium",service_tier:"fast")
        c.selectExecution(chosen);check(c.executionSelection == chosen,"user selection changes actual controller state")
        let unsupported=CodexExecutionSelection(model:"synthetic-small",reasoning_effort:"xhigh",service_tier:"fast")
        c.selectExecution(unsupported);check(c.executionSelection == chosen,"unsupported combination rejected")
        let switched=catalog.models[1].selecting(from:chosen)
        check(switched.reasoning_effort == "low" && !switched.fast,"model switch uses advertised effort and drops unavailable Fast")
        let reopened=CodexNativeController(home:root,enabled:true,port:f.port);await reopened.refreshStatus()
        check(reopened.executionSelection == chosen,"saved choices survive restart and service refresh")
        f.loseAck=true;reopened.submit("offline selected input");try await wait(reopened)
        check(f.selections == [chosen] && reopened.taskRecord?.selection == chosen,"selected parameters reach request and immutable intent")
        let operation=f.ids[0];reopened.selectExecution(switched);reopened.inspectOriginal();try await wait(reopened)
        check(f.ids == [operation,operation] && f.selections == [chosen,chosen],"lost acknowledgement retry keeps original UUID and settings")
        check(reopened.taskRecord?.reply?.text == "offline receipt","confirmed original output visible")
        let final=CodexNativeController(home:root,enabled:true,port:f.port);await final.refreshStatus()
        check(final.taskRecord?.selection == chosen && final.executionSelection == switched,"task settings and next-task preferences read back independently")
        final.submit("second offline input");try await wait(final)
        check(f.selections.last == switched,"next explicit task sends saved new selection")
        let badRoot=root.appendingPathComponent("bad");try FileManager.default.createDirectory(at:badRoot,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        let bad=Fixture();bad.wrongReceipt=true;let rejected=CodexNativeController(home:badRoot,enabled:true,port:bad.port)
        await rejected.refreshStatus();rejected.selectExecution(chosen);rejected.submit("wrong receipt fixture");try await wait(rejected)
        check(rejected.errorCode == "codex_preferences_unverified" && rejected.taskRecord?.reply?.text == nil,"wrong-tier response never accepted as success")
        print("PASS Codex execution choices \(checks) checks; synthetic ports only; paid calls/config writes/install = 0")
    }
}
