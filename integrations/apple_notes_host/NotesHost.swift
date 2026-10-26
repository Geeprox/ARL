import Foundation

struct NotesPeerRegistration {
    let subject: String
    let pid: Int32
    let requirement: String
    let epoch: UInt64
    let currentEpoch: () -> UInt64?
}

// One fixed private session/registered peer, not a general server. No listener,
// arbitrary executable/path, enrollment RPC or client-supplied grant.
@MainActor final class NotesHostSession {
    nonisolated static let errors: Set<String> = ["invalid_arguments", "duplicate_key", "frame_too_large", "invalid_transport_request", "caller_unverified", "capability_not_granted", "native_review_not_granted", "needs_permission", "needs_unlock", "lock_state_unknown", "target_changed", "target_unavailable", "approval_expired", "user_cancelled", "cancelled_before_effect", "effect_budget_exceeded", "operation_consumed", "journal_uncertain", "outcome_unknown", "busy", "operation_not_active", "transport_disconnected", "automation_timeout", "automation_failed", "invalid_automation_reply"]
    private let caller: AuthenticatedCaller
    private let engine: NotesApprovalEngine
    private let reviewer: NotesReviewer
    private let effects: NotesEffects
    private let externallyCancelled: () -> Bool
    private var active: (String, String)?
    private var cancelled = false
    private var disconnected = false

    private init(caller: AuthenticatedCaller, engine: NotesApprovalEngine, reviewer: NotesReviewer, effects: NotesEffects, externallyCancelled: @escaping () -> Bool) {
        self.caller = caller; self.engine = engine; self.reviewer = reviewer; self.effects = effects
        self.externallyCancelled = externallyCancelled
    }
    static func fromRegisteredSocket(_ fd: Int32, registration: NotesPeerRegistration, engine: NotesApprovalEngine, reviewer: NotesReviewer = NativeNotesReviewer(), effects: NotesEffects = NativeNotesEffects(), externallyCancelled: @escaping () -> Bool = { false }) throws -> NotesHostSession {
        let caller = try AuthenticatedCaller.fromRegisteredSocket(fd, subject: registration.subject, expectedPID: registration.pid,
            requirement: registration.requirement, registrationEpoch: registration.epoch, currentRegistrationEpoch: registration.currentEpoch)
        return NotesHostSession(caller: caller, engine: engine, reviewer: reviewer, effects: effects, externallyCancelled: externallyCancelled)
    }
    #if APPLE_REVIEW_FIXTURE
    static func fixture(caller: AuthenticatedCaller, engine: NotesApprovalEngine, reviewer: NotesReviewer, effects: NotesEffects, externallyCancelled: @escaping () -> Bool = { false }) -> NotesHostSession {
        NotesHostSession(caller: caller, engine: engine, reviewer: reviewer, effects: effects, externallyCancelled: externallyCancelled)
    }
    #endif
    func disconnect() { disconnected = true; cancelled = true }
    func handle(_ frame: Data) throws -> Data {
        var method = "create"
        do {
            guard !disconnected else { throw ReviewFault("transport_disconnected") }
            guard caller.isCurrent() else { throw ReviewFault("caller_unverified") }
            let v = try flatObject(frame, limit: NotesWire.maxRequestFrame - 1)
            guard let m = v["method"] as? String else { throw ReviewFault("invalid_transport_request") }; method = m
            if method == "cancel" {
                guard Set(v.keys) == Set(["schema_version", "method", "operation_id", "request_sha256"]), integer(v["schema_version"]) == 1,
                      let op = v["operation_id"] as? String, let hash = v["request_sha256"] as? String,
                      let active, active.0 == op, active.1 == hash else { throw ReviewFault("operation_not_active") }
                cancelled = true
                return try NotesWire.response("cancel") // acknowledgement, not effect stop
            }
            guard method == "create" else { throw ReviewFault("invalid_transport_request") }
            guard active == nil else { throw ReviewFault("busy") }
            let raw = try NotesWire.unpackCreate(frame), p = try NotesCreateProposal(raw)
            active = (p.operationID, p.rawHash); cancelled = false
            defer { active = nil }
            let receipt = try engine.performNative(raw, caller: caller, reviewer: reviewer, effects: effects,
                cancelled: { self.cancelled || self.disconnected || self.externallyCancelled() })
            return try NotesWire.response("create", receipt: receipt)
        } catch let fault as ReviewFault {
            return try NotesWire.response(method == "cancel" ? "cancel" : "create", error: Self.errors.contains(fault.code) ? fault.code : "outcome_unknown")
        } catch { return try NotesWire.response(method == "cancel" ? "cancel" : "create", error: "outcome_unknown") }
    }
}
