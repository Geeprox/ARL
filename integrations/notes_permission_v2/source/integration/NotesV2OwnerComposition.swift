import Foundation
import Security

// Compiled in the permission owner's ARLNotesBridge, with its Proposal,
// PeerAuthentication and ConsumptionJournal. No @main or install action.
// Expected pins originate in trusted bootstrap/supervisor registration, not RPC.
struct NotesV2CodePin {
    static var signingIdentifier: String {
        #if NOTES_SYNTHETIC
        return "local.arl.notessynthetic"
        #else
        return "local.arl.notesbridge"
        #endif
    }
    let executableSHA256: String
    let designatedRequirementSHA256: String
    func verifyResponsibleSelf() throws {
        guard [executableSHA256, designatedRequirementSHA256].allSatisfy({ $0.count == 64 && $0.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil }) else { throw NativeFault("helper_modified") }
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess else { throw NativeFault("helper_modified") }
        var info: CFDictionary?
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecStaticCodeCheckValidity(staticCode, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess,
              SecCodeCopySigningInformation(staticCode, [], &info) == errSecSuccess, let info = info as? [String: Any],
              info[kSecCodeInfoIdentifier as String] as? String == Self.signingIdentifier,
              let executable = info[kSecCodeInfoMainExecutable as String] as? URL,
              digest(try Data(contentsOf: executable)) == executableSHA256 else { throw NativeFault("helper_modified") }
        var rule: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(staticCode, [], &rule) == errSecSuccess, let rule else { throw NativeFault("helper_modified") }
        var raw: CFData?
        guard SecRequirementCopyData(rule, [], &raw) == errSecSuccess, let raw,
              digest(raw as Data) == designatedRequirementSHA256 else { throw NativeFault("helper_modified") }
    }
}

// Separate flat wire v2; never routed through NotesWire's ID-less v1 receipt.
// Owner flatObject rejects duplicate/escaped-duplicate fields. Booleans in this
// private flat envelope use fixed integers; the internal session receives Bool.
enum NotesV2Wire {
    static let requestLimit = 12 * 1024
    static let responseLimit = 64 * 1024
    static func unpack(_ frame: Data) throws -> (String, [String: Any]) {
        var raw = try flatObject(frame, limit: requestLimit - 1)
        guard integer(raw.removeValue(forKey: "schema_version")) == 2,
              let method = raw.removeValue(forKey: "method") as? String,
              ["create", "read", "search"].contains(method) else { throw NativeFault("unsupported_operation") }
        if method == "search" {
            guard integer(raw["search_body"]) == 0 else { throw NativeFault("proposal_mismatch") }
            raw["search_body"] = false
        }
        return (method, raw)
    }
    static func response(method: String, result: [String: Any]? = nil, error: NotesFirstUseOutcomeFault? = nil) throws -> Data {
        let text: Any = try result.map { String(decoding: try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self) } ?? NSNull()
        let object: [String: Any] = ["schema_version": 2, "method": method, "status": error == nil ? "ok" : "error",
            "result_json": text, "error_code": error?.code as Any? ?? NSNull(), "indeterminate": error?.indeterminate == true ? 1 : 0]
        let frame = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        guard frame.count + 1 <= responseLimit else { throw NativeFault("notes_payload_too_large") }
        return frame
    }
}

enum NotesV2Admission {
    static func check(pin: () throws -> Void, current: () -> Bool, cancelled: () -> Bool) throws {
        guard current(), !cancelled() else { throw NativeFault("caller_unverified") }
        try pin() // Security and executable reads can outlast revocation.
        guard current(), !cancelled() else { throw NativeFault("caller_unverified") }
    }
}

final class NotesV2OwnerSession {
    private let firstUse: NotesFirstUseSession
    private init(_ firstUse: NotesFirstUseSession) { self.firstUse = firstUse }
    // The owner's actual fixed inherited socket and registration epoch are
    // verified by kernel audit token and Security, then rechecked on each call.
    static func fromRegisteredSocket(fd: Int32, subject: String, expectedPID: Int32,
        peerRequirement: String, epoch: UInt64, currentEpoch: @escaping () -> UInt64?,
        plan: NotesFirstUsePlan, codePin: NotesV2CodePin, journal: ConsumptionJournal,
        journalCheck: @escaping () throws -> Void, permitID: String, cancelled: @escaping () -> Bool) throws -> NotesV2OwnerSession {
        guard epoch <= UInt64(Int64.max), uuid(permitID) else { throw NativeFault("invalid_first_use_plan") }
        let caller = try AuthenticatedCaller.fromRegisteredSocket(fd, subject: subject, expectedPID: expectedPID,
            requirement: peerRequirement, registrationEpoch: epoch, currentRegistrationEpoch: currentEpoch)
        try codePin.verifyResponsibleSelf()
        let proposalDigest = try plan.digest
        #if NOTES_SYNTHETIC
        let syntheticStore = NotesSyntheticStore(plan: plan)
        let surface: (() throws -> NotesFirstUseSurface)? = { NotesSyntheticSurface(store: syntheticStore) }
        #else
        let surface: (() throws -> NotesFirstUseSurface)? = nil
        #endif
        let session = try NotesFirstUseSession(plan: plan, verifyHostAndPeer: {
            try journalCheck()
            try NotesV2Admission.check(pin: { try codePin.verifyResponsibleSelf(); try journalCheck() },
                current: { caller.isCurrent() && currentEpoch() == epoch }, cancelled: cancelled)
        }, consumeAttempt: { op, frozenHash in
            guard frozenHash == proposalDigest else { throw NativeFault("proposal_mismatch") }
            try journalCheck()
            do { try journal.consume(operationID: op, permitID: permitID, subject: subject, epoch: Int64(epoch), budget: 1) }
            catch let fault as ReviewFault { throw NativeFault(fault.code) }
            try journalCheck()
        }, surface: surface)
        return NotesV2OwnerSession(session)
    }
    #if APPLE_REVIEW_FIXTURE
    static func fixture(_ session: NotesFirstUseSession) -> NotesV2OwnerSession { NotesV2OwnerSession(session) }
    #endif
    func handle(_ frame: Data) throws -> Data {
        let (method, args) = try NotesV2Wire.unpack(frame)
        do { return try NotesV2Wire.response(method: method, result: firstUse.handle(method: method, args: args)) }
        catch let error as NotesFirstUseOutcomeFault { return try NotesV2Wire.response(method: method, error: error) }
        // Encoding/lost transport after an effect must be surfaced as uncertain
        // by the owner gateway. It must never replay this consumed request.
    }
}
