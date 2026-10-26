
import Foundation
import ApplicationServices
import Darwin

@main enum ApplePreconditionDiagnosticsTests {
    static func main() throws {
        var checks = 0
        func expect(_ value: Bool, _ label: String) {
            precondition(value, label); checks += 1
        }
        let uid = getuid()
        let active: [String: Any] = [
            kCGSessionUserIDKey as String: NSNumber(value: uid),
            kCGSessionOnConsoleKey as String: true,
            kCGSessionLoginDoneKey as String: true,
            "CGSSessionScreenIsLocked": false
        ]
        func issue(_ value: [String: Any]?) -> AppleDirectSessionIssue? {
            AppleDirectAuthority.sessionIssue(value, uid: uid)
        }
        expect(issue(active) == nil && AppleDirectAuthority.sessionIsAvailable(active, uid: uid), "existing valid session stays admitted")
        expect(issue(nil) == .dictionaryUnavailable, "missing dictionary is not reported as a lock")
        var changed = active
        changed.removeValue(forKey: kCGSessionUserIDKey as String)
        expect(issue(changed) == .userIdentityUnavailable, "missing UID is explicit")
        changed = active; changed[kCGSessionUserIDKey as String] = NSNumber(value: uid + 1)
        expect(issue(changed) == .differentUser, "another UID never admitted")
        changed = active; changed[kCGSessionOnConsoleKey as String] = false
        expect(issue(changed) == .notOnConsole, "off-console is explicit")
        changed = active; changed[kCGSessionLoginDoneKey as String] = false
        expect(issue(changed) == .loginIncomplete, "login incomplete is explicit")
        changed = active; changed.removeValue(forKey: kCGSessionLoginDoneKey as String)
        changed["kCGSSessionLoginDoneKey"] = true
        expect(issue(changed) == .loginIncomplete, "wrong SDK key spelling does not grant")
        changed = active; changed["CGSSessionScreenIsLocked"] = true
        expect(issue(changed) == .screenLocked && !AppleDirectAuthority.sessionIsAvailable(changed, uid: uid), "lock continues to deny")
        let fault = AppleDirectFault("user_session_unavailable", sessionIssue: .screenLocked).at(.notesFolderName)
        expect(fault.sessionIssue == .screenLocked && fault.code == "user_session_unavailable", "context preserves stable code and session reason")
        let roundTrip = try JSONDecoder().decode(AppleDirectFault.self, from: JSONEncoder().encode(fault))
        expect(roundTrip.sessionIssue == .screenLocked, "reason survives typed transport")
        let legacy = try JSONDecoder().decode(AppleDirectFault.self, from: Data(#"{"code":"user_session_unavailable"}"#.utf8))
        expect(legacy.sessionIssue == nil, "old faults remain decodable")
        let locked = ApplePublicPrecondition.recovery(tool: "mio_notes_folders", code: fault.code, sessionIssue: fault.sessionIssue)!
        expect(locked["reason"] as? String == "screen_locked", "public result explains exact lock")
        expect(locked["required_action"] as? String == "unlock_existing_user_session", "unlock is left to user")
        expect(locked["automatic_retry"] as? Bool == false && locked["requires_user_action"] as? Bool == true, "no retry or implicit approval")
        let unknownSession = ApplePublicPrecondition.recovery(tool: "mio_notes_folders", code: fault.code)!
        expect(unknownSession["reason"] as? String == fault.code && unknownSession["required_action"] as? String == "restore_existing_console_session", "legacy errors never invent lock evidence")
        let reminders = ApplePublicPrecondition.recovery(tool: "mio_reminders_catalog", code: "needs_permission")!
        expect(reminders["permission_owner_bundle_id"] as? String == "local.arl.remindersbridge", "Reminders identifies real permission owner")
        expect(reminders["required_permission"] as? String == "reminders_full_access", "full read-write permission is named truthfully")
        let notes = ApplePublicPrecondition.recovery(tool: "mio_notes_folders", code: "needs_permission")!
        expect(notes["permission_owner_bundle_id"] as? String == "local.arl.control" && notes["target_bundle_id"] as? String == "com.apple.Notes", "Notes names Automation source and target")
        let calendar = ApplePublicPrecondition.recovery(tool: "mio_calendar_calendars", code: "needs_full_access")!
        expect(calendar["permission_owner_bundle_id"] as? String == "local.arl.control", "Calendar retains main owner identity")
        expect(ApplePublicPrecondition.recovery(tool: "mio_notes_update", code: "outcome_unknown") == nil, "unknown write has no resubmit guidance")
        expect(ApplePublicPrecondition.recovery(tool: "mio_nas_list", code: "needs_permission") == nil, "no cross-domain NAS advice")
        expect(ApplePublicPrecondition.recovery(tool: "mio_messages_accounts", code: fault.code, sessionIssue: .screenLocked) == nil, "paused Messages scope unchanged")
        var dispatched = 0
        do {
            _ = try AppleDirectDispatch.perform(check: {
                if let reason = issue(changed) { throw AppleDirectFault("user_session_unavailable", sessionIssue: reason) }
            }, preflight: { dispatched += 1; return .authorized }, deliver: { dispatched += 1; return true })
            preconditionFailure("locked dispatch allowed")
        } catch let error as AppleDirectFault {
            expect(error.sessionIssue == .screenLocked && dispatched == 0, "locked session stops before permission and business calls")
        }
        #if APPLE_PUBLICATION
        for (tool, recovery) in [("mio_notes_folders", locked), ("mio_reminders_catalog", reminders)] {
            let code = tool == "mio_notes_folders" ? "user_session_unavailable" : "needs_permission"
            let envelope: [String: Any] = ["schema_version": 1, "capability": "apple.product.v1", "tool": tool,
                "state": "unavailable", "code": code, "automatic_replay": false, "recovery": recovery]
            let bytes = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
            var calls = 0
            let response = try MioReadOwnerAdapter.respond(["jsonrpc":"2.0", "id":1, "method":"tools/call",
                "params":["name":tool, "arguments":[:]]], ownerCall: { name, args in
                    expect(name == tool && args == Data("{}".utf8), "public call keeps exact tool and empty read arguments")
                    calls += 1; return bytes
                })
            let result = response["result"] as! [String: Any]
            let structured = result["structuredContent"] as! [String: Any]
            let text = (result["content"] as! [[String: Any]])[0]["text"] as! String
            let textual = try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
            expect(calls == 1 && result["isError"] as? Bool == true, "public precondition is a single failed read, never retried")
            expect((structured["recovery"] as! NSDictionary).isEqual(to: recovery), "real public adapter preserves actionable recovery")
            expect((textual as NSDictionary).isEqual(to: structured), "text and structured result agree")
            expect(structured["code"] as? String == code && structured["state"] as? String == "unavailable", "blocked result never becomes success")
        }
        #endif
        print("PASS \(checks) Apple precondition checks; real_Apple=0 permission_requests=0 business_effects=0")
    }
}
