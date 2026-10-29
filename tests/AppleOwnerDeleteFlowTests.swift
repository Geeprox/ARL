import Foundation

@MainActor final class OwnerDeleteUnusedCalendar: CalendarBusinessBackend {
    var access: CalendarBusinessAccess { .full_access }
    func calendars() throws -> [CalendarBusinessCalendar] { preconditionFailure("calendar must not be touched") }
    func query(_ value: CalendarBusinessQuery) throws -> (events: [CalendarBusinessEvent], truncated: Bool) { preconditionFailure("calendar must not be touched") }
    func get(_ target: CalendarBusinessTarget) throws -> CalendarBusinessEvent { preconditionFailure("calendar must not be touched") }
    func prepare(_ request: CalendarBusinessRequest) throws -> CalendarBusinessClaim { preconditionFailure("calendar must not be touched") }
    func commit(_ claim: CalendarBusinessClaim) throws -> CalendarBusinessOperation { preconditionFailure("calendar must not be touched") }
}

@MainActor final class OwnerDeleteFlowFixture {
    let id = "f6e87204-47be-4840-b5ef-3b7898cd856f"
    let revision = String(repeating: "b", count: 64)
    let identity = RemindersFirstIdentity(helper_bundle_id: "local.arl.remindersbridge",
        executable_sha256: String(repeating: "c", count: 64), designated_requirement_sha256: String(repeating: "d", count: 64))
    var calls: [RemindersProductAction] = []
    var ensures = 0, confirmations = 0, submissions = 0, records = 0
    var priorState: String?, priorCode = "deleted_local"
    var changedIntent = false, badRevision = false, badList = false, recurring = false
    var failFirstStatus = false, failEnsure = false, statusCode = "operation_missing"
    var verificationFault: AppleDirectFault?
    var sessionFault: AppleDirectFault?
    var sessionChecks = 0, verifications = 0, stopAfterVerification: Int?
    var notesFolder: NotesDirectFolder?
    var args: [String: Any] {
        ["task_id": id, "list_id": "synthetic-list", "reminder_id": changedIntent ? "different-item":"synthetic-item", "expected_revision": revision]
    }
    var target: RemindersProductTarget {
        .init(source: .init(id: "synthetic-source", title: "Synthetic source", type: 0),
              list: .init(id: "synthetic-list", title: "Synthetic list", source_id: "synthetic-source", writable: true),
              helper_requirement_sha256: identity.designated_requirement_sha256, policy_sha256: String(repeating: "e", count: 64))
    }
    func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }
    func reply(_ frame: RemindersProductFrame) throws -> RemindersProductReply {
        calls.append(frame.action)
        var reply = RemindersProductReply(schema_version: 3, capability_id: "reminders.product.v1",
            request_id: frame.request_id, action: frame.action, identity: identity,
            policy_sha256: target.policy_sha256, outcome: "refreshed", code: "ok")
        if frame.action == .status {
            if failFirstStatus { failFirstStatus = false; throw RemindersTransportFault("transport_unavailable") }
            if let state = priorState {
                let raw = try RemindersProductController.mutationFrame("delete", taskID: id,
                    args: ["list_id":"synthetic-list", "reminder_id":"synthetic-item", "expected_revision":revision]).request_json!
                let op = RemindersProductContract.operationID(id)
                let receipt: [String:Any] = ["schema_version":3, "status":"ok", "operation_id":op, "persistence":"deleted_local",
                    "cloud_sync":"not_checked", "deletion":["id":"synthetic-item", "list_id":"synthetic-list", "expected_revision":revision]]
                reply.task = .init(task_id:id, operation_id:op, request_sha256:RemindersNativeIO.hash(Data(raw.utf8)),
                    request_json:raw, target:target, state:state, code:priorCode, result_json:nil)
                reply.result_json = String(decoding:try json(receipt), as:UTF8.self)
                reply.code = priorCode
            } else { reply.code = statusCode }
        } else if frame.action == .read {
            reply.target = target
            let item: [String:Any] = ["id":"synthetic-item", "list_id":badList ? "different-list":"synthetic-list",
                "title":"Synthetic reminder", "priority":0, "completed":false,
                "due_components":[:], "start_components":[:],
                "recurrence":["editable":true, "descriptors":recurring ? [["frequency":"weekly"]]:[]],
                "alerts":["editable":true, "descriptors":[]], "revision":badRevision ? String(repeating:"a", count:64):revision]
            reply.result_json = String(decoding:try json(["schema_version":3, "status":"ok", "reminder":item]), as:UTF8.self)
        } else if frame.action == .catalog {
            reply.catalog = .init(sources:[target.source], lists:[target.list!])
        } else if frame.action == .submit {
            submissions += 1
            precondition(frame.task_id == id)
            let raw = frame.request_json!
            let op = RemindersProductContract.operationID(id)
            let receipt: [String:Any] = ["schema_version":3, "status":"ok", "operation_id":op, "persistence":"deleted_local",
                "cloud_sync":"not_checked", "deletion":["id":"synthetic-item", "list_id":"synthetic-list", "expected_revision":revision]]
            priorState = "saved_local"
            reply.task = .init(task_id:id, operation_id:op, request_sha256:RemindersNativeIO.hash(Data(raw.utf8)),
                request_json:raw, target:target, state:"saved_local", code:"deleted_local", result_json:nil)
            reply.result_json = String(decoding:try json(receipt), as:UTF8.self)
            reply.code = "deleted_local"
        }
        return reply
    }
    func owner(home: URL) -> AppleProductOwnerExecutor {
        let controller = RemindersProductController(port:.init(begin:{_ in true}, end:{_ in},
            ensureService:{self.ensures += 1;if self.failEnsure { throw RemindersTransportFault("needs_permission") }},
            send:{try self.reply($0)}, record:{_,_,_,_ in self.records += 1}))
        let calendar = CalendarBusinessHandler(backend:OwnerDeleteUnusedCalendar(), port:.init(verify:{},
            lookup:{_ in nil},
            claim:{_ in preconditionFailure("no calendar claim")}, finish:{_ in preconditionFailure("no calendar finish")},
            record:{_,_ in preconditionFailure("no calendar record")}))
        return .init(home:home, events:AppleDirectExecutor(), reminders:controller, calendar:calendar,
            port:.init(begin:{_ in true},end:{_ in},verify:{
                self.verifications += 1
                if let fault=self.verificationFault {throw fault}
                if self.verifications == self.stopAfterVerification {throw AppleDirectFault("synthetic_stop")}
            },notesFolder:{self.notesFolder}, messagesAccount:{nil}, requireUserSession:{
                self.sessionChecks += 1
                if let fault=self.sessionFault {throw fault}
            }),
            confirmation:{_,_ in self.confirmations += 1;return false})
    }
}

@main enum AppleOwnerDeleteFlowTests {
    @MainActor static func main() async throws {
        precondition(CommandLine.arguments.count == 2)
        let home = URL(fileURLWithPath:CommandLine.arguments[1])
        var checks = 0
        func expect(_ value: Bool, _ label: String) { precondition(value,label); checks += 1 }
        func call(_ f: OwnerDeleteFlowFixture, tool: String = "mio_reminders_delete_item", args: [String:Any]? = nil) async throws -> [String:Any] {
            let bytes = try await f.owner(home:home).execute(tool:tool, argumentsJSON:f.json(args ?? f.args), callID:UUID())
            return try OwnerReadJSON.object(bytes, limit:262144)
        }
        for descriptor in AppleProductCapability.descriptors {
            let tool = descriptor["name"] as! String
            if AppleProductCapability.calendar.contains(tool) || AppleProductCapability.notes.contains(tool) || AppleProductCapability.reminders.contains(tool) {
                expect((descriptor["_meta"] as? [String:Any])?["arl/requiresConfirmation"] as? Bool == false, "published Apple operation does not require another confirmation")
            }
        }
        for descriptor in AppleCapability.descriptors {
            expect((descriptor["_meta"] as? [String:Any])?["arl/requiresConfirmation"] as? Bool == false, "legacy reminder metadata also permits direct execution")
        }
        var malformed:[[String:Any]]=[]
        let valid=OwnerDeleteFlowFixture().args
        for key in ["task_id","list_id","reminder_id","expected_revision"] {
            var value=valid;value.removeValue(forKey:key);malformed.append(value)
        }
        for key in ["task_id","list_id","reminder_id","expected_revision"] {
            for invalid:Any in [42,true,""] {var value=valid;value[key]=invalid;malformed.append(value)}
        }
        for key in ["list_id","reminder_id"] {
            for invalid in [String(repeating:"x",count:1025),"bad\nidentifier"] {var value=valid;value[key]=invalid;malformed.append(value)}
        }
        for revision in [String(repeating:"b",count:63),String(repeating:"g",count:64),String(repeating:"B",count:64),
                         String(repeating:"a",count:64)+"\n",String(repeating:"a",count:64)+"\r\n",
                         String(repeating:"a",count:64)+"\r",String(repeating:"a",count:64)+"\u{2028}",
                         String(repeating:"a",count:64)+"\u{2029}",String(repeating:"a",count:64)+"\0"] {
            var value=valid;value["expected_revision"]=revision;malformed.append(value)
        }
        var extra=valid;extra["approved"]=true;malformed.append(extra)
        for value in malformed {
            let f=OwnerDeleteFlowFixture();let result=try await call(f,args:value)
            expect(result["code"] as? String == "invalid_arguments" && result["state"] as? String == "unavailable", "malformed delete is a bounded error")
            expect(f.calls.isEmpty && f.ensures == 0 && f.confirmations == 0 && f.submissions == 0 && f.records == 0, "malformed input stops before status/read/log/confirmation/effect")
        }
        for state in ["saved_local","unknown","rejected","pending"] {
            let f = OwnerDeleteFlowFixture(); f.priorState = state
            f.priorCode = state == "saved_local" ? "deleted_local" : state == "rejected" ? "revision_conflict":"outcome_unknown"
            let value = try await call(f)
            expect(value["state"] as? String == state, "original terminal/unknown state is preserved")
            expect(f.calls == [.status] && f.ensures == 0 && f.confirmations == 0 && f.submissions == 0, "repeat only reads original task before permission or target")
            expect(value["task_id"] as? String == f.id && value["automatic_replay"] as? Bool == false, "repeat retains task and no replay")
            let admitted = try AppleProductCapability.admit(value, tool:"mio_reminders_delete_item", arguments:f.args)
            expect(admitted == (state == "saved_local"), "actual owner frozen receipt agrees with published admission")
        }
        let changed = OwnerDeleteFlowFixture();changed.priorState = "saved_local";changed.changedIntent = true
        let wrong = try await call(changed)
        expect(wrong["code"] as? String == "idempotency_conflict" && wrong["state"] as? String == "unavailable", "same task cannot change target")
        expect(changed.calls == [.status] && changed.confirmations == 0 && changed.submissions == 0, "changed intent never re-confirms or saves")
        for failure in ["revision","list","recurring","status"] {
            let f = OwnerDeleteFlowFixture()
            f.badRevision = failure == "revision";f.badList = failure == "list";f.recurring = failure == "recurring"
            if failure == "status" { f.statusCode = "product_journal_missing_or_replaced" }
            let value = try await call(f)
            let code = value["code"] as? String
            expect(code == (failure == "recurring" ? "recurring_delete_unsupported":failure == "status" ? f.statusCode:"revision_conflict"), "preflight rejects exact boundary")
            expect(f.confirmations == 0 && f.submissions == 0, "bad preflight stops before confirmation and effect")
        }
        let fresh = OwnerDeleteFlowFixture()
        let saved = try await call(fresh)
        expect(saved["code"] as? String == "deleted_local" && saved["state"] as? String == "saved_local", "fresh delete submits directly")
        expect(fresh.calls == [.status,.read,.submit] && fresh.submissions == 1 && fresh.confirmations == 0, "exact-item preflight and one submission without confirmation")
        expect(fresh.sessionChecks == 1, "direct execution retains active-session admission")
        _ = try await call(fresh)
        expect(fresh.calls == [.status,.read,.submit,.status] && fresh.submissions == 1 && fresh.confirmations == 0, "repeat only observes original deletion")
        let cold = OwnerDeleteFlowFixture();cold.failFirstStatus = true
        let coldResult = try await call(cold)
        expect(cold.calls == [.status,.catalog,.status,.read,.submit], "cold helper restores before original-task inspect and direct submit")
        expect(cold.submissions == 1 && cold.confirmations == 0 && coldResult["code"] as? String == "deleted_local", "cold start directly executes exact synthetic deletion")
        let locked = OwnerDeleteFlowFixture();locked.sessionFault = AppleDirectFault("user_session_unavailable", sessionIssue:.screenLocked)
        let blocked = try await call(locked)
        expect(blocked["code"] as? String == "user_session_unavailable" && locked.submissions == 0 && locked.confirmations == 0, "locked session cannot delete")
        let denied = OwnerDeleteFlowFixture();denied.failFirstStatus = true;denied.failEnsure = true
        let deniedResult = try await call(denied)
        expect(deniedResult["code"] as? String == "needs_permission", "cold read reports permission owner instead of requesting consent")
        expect(denied.calls == [.status] && denied.confirmations == 0 && denied.submissions == 0, "permission failure does not confirm or save")
        let notes = OwnerDeleteFlowFixture()
        notes.verificationFault = AppleDirectFault("user_session_unavailable", sessionIssue:.screenLocked)
        let noteArgs: [String:Any] = ["task_id":notes.id, "row":["id":"x-coredata://ABCD/ICNote/p3", "title":"Synthetic", "modified":0], "source_body_digest":notes.revision]
        let noteResult = try await call(notes, tool:"mio_notes_delete", args:noteArgs)
        expect(noteResult["code"] as? String == "user_session_unavailable" && noteResult["state"] as? String == "unavailable", "Notes blocked before native backend")
        expect((noteResult["recovery"] as? [String:Any])?["reason"] as? String == "screen_locked", "Owner preserves exact Notes blocked reason")
        expect(notes.calls.isEmpty && notes.confirmations == 0 && notes.submissions == 0, "Notes blocked path has no reminder or confirmation effects")
        for tool in ["mio_notes_create", "mio_notes_update", "mio_notes_delete"] {
            let f = OwnerDeleteFlowFixture()
            f.notesFolder = .init(accountID:"x-coredata://ABCD/ICAccount/p1", accountName:"Synthetic account", id:"x-coredata://ABCD/ICFolder/p2", name:"Synthetic folder")
            f.stopAfterVerification = 2
            var args: [String:Any] = ["task_id":f.id]
            if tool != "mio_notes_create" {
                args["row"] = ["id":"x-coredata://ABCD/ICNote/p3", "title":"Synthetic", "modified":0]
                args["source_body_digest"] = f.revision
            }
            if tool != "mio_notes_delete" {args["title"]="Synthetic";args["plaintext"]="Synthetic body"}
            let result = try await call(f,tool:tool,args:args)
            expect(result["code"] as? String == "synthetic_stop", "Notes request reaches target revalidation directly")
            expect(f.verifications == 2 && f.confirmations == 0 && f.sessionChecks == 1, "Notes mutation retains admission without a dialog")
        }
        print("PASS \(checks) actual Apple Owner delete-flow checks; real_Apple_events=0 permission_requests=0 synthetic_reminder_submissions=2")
    }
}
