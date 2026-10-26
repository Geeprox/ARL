import Foundation

struct NotesV2Profile {
    static let signedControlRequirement = "identifier \"local.arl.control\" and certificate root = H\"859332b7fffbbbb33b80c7b78d30c27d2d81583f\""
    let rawSHA256: String
    let callerSubject: String
    let callerRequirement: String
    let epoch: UInt64
    let permitID: String
    let sessionKind: String
    let expiresAtMS: Int64
    let plan: NotesFirstUsePlan?
    let permissionPlan: NotesPermissionRequestPlan?
    let syntheticJournal: String
    let journalDevice: UInt64
    let journalInode: UInt64

    static var synthetic: Bool {
        #if NOTES_SYNTHETIC
        return true
        #else
        return false
        #endif
    }
    static func parse(_ raw: Data, expectedSHA256: String, now: Int64, expectedKind: String = "notes_first_use") throws -> Self {
        guard ["notes_first_use", "permission_setup"].contains(expectedKind), raw.count <= 16 * 1024,
              digest(raw) == expectedSHA256 else { throw NativeFault("profile_invalid") }
        let p = try flatObject(raw, limit: 16 * 1024)
        let common: Set<String> = ["schema_version", "enabled", "mode", "session_kind", "caller_subject", "caller_requirement", "epoch", "permit_id",
            "expires_at_ms", "source_closure_sha256", "journal_device", "journal_inode"]
        let notes: Set<String> = ["operation_id", "account_id", "folder_id", "expected_name", "title", "content", "max_attempts"]
        let permission: Set<String> = ["request_id", "capability_id", "request_origin", "max_requests"]
        guard Set(p.keys) == common.union(expectedKind == "notes_first_use" ? notes : permission).union(synthetic ? ["synthetic_journal"] : []),
              integer(p["schema_version"]) == 2, p["mode"] as? String == (synthetic ? "synthetic" : "notes"),
              p["session_kind"] as? String == expectedKind,
              p["source_closure_sha256"] as? String == NotesV2BuildSeal.sourceHash else { throw NativeFault("profile_invalid") }
        // Both shipped profiles stop here. Selecting the manual entry point
        // never bypasses authentication, enables Notes or creates a grant.
        guard integer(p["enabled"]) == 1 else { throw NativeFault("host_disabled") }
        func unsigned(_ value: Any?) -> UInt64? {
            guard let text = value as? String, let number = UInt64(text), number > 0, String(number) == text else { return nil }
            return number
        }
        guard let subject = p["caller_subject"] as? String, identifier(subject),
              let requirement = p["caller_requirement"] as? String,
              (synthetic ? requirement.range(of: "^cdhash H\"[a-f0-9]{40}\"$", options: .regularExpression) != nil
                         : requirement == signedControlRequirement),
              let epoch = integer(p["epoch"]), epoch > 0, let expiry = integer(p["expires_at_ms"]), expiry > now, expiry - now <= 120000,
              let journalDevice = unsigned(p["journal_device"]), let journalInode = unsigned(p["journal_inode"]),
              let permit = p["permit_id"] as? String, uuid(permit) else { throw NativeFault("profile_invalid") }
        let plan: NotesFirstUsePlan?, permissionPlan: NotesPermissionRequestPlan?
        if expectedKind == "notes_first_use" {
            guard integer(p["max_attempts"]) == 1, let operation = p["operation_id"] as? String,
                  let account = p["account_id"] as? String, let folder = p["folder_id"] as? String,
                  let name = p["expected_name"] as? String, let title = p["title"] as? String, let content = p["content"] as? String else { throw NativeFault("profile_invalid") }
            let value = NotesFirstUsePlan(binding: NativeBinding(account_id: account, folder_id: folder, expected_name: name),
                operationID: operation, title: title, plaintext: content, expiresAtMS: expiry)
            try value.validate(now: now); plan = value; permissionPlan = nil
        } else {
            guard p["request_origin"] as? String == "manual_user_action", integer(p["max_requests"]) == 1,
                  let requestID = p["request_id"] as? String, let cap = p["capability_id"] as? String,
                  let capability = NotesPermissionCapability(rawValue: cap) else { throw NativeFault("profile_invalid") }
            let value = NotesPermissionRequestPlan(requestID: requestID, capability: capability, expiresAtMS: expiry)
            try value.validate(now: now); permissionPlan = value; plan = nil
        }
        let syntheticJournal = p["synthetic_journal"] as? String ?? ""
        if synthetic { guard syntheticJournal.hasPrefix("/"), !syntheticJournal.contains("\0") else { throw NativeFault("profile_invalid") } }
        return .init(rawSHA256: expectedSHA256, callerSubject: subject, callerRequirement: requirement, epoch: UInt64(epoch), permitID: permit,
            sessionKind: expectedKind, expiresAtMS: expiry, plan: plan, permissionPlan: permissionPlan,
            syntheticJournal: syntheticJournal, journalDevice: journalDevice, journalInode: journalInode)
    }
}
