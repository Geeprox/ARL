// Test executable only. NativeNotesEffects methods are NEVER invoked here.
import Foundation
import CryptoKit

final class NotesFixtureState {
    var now: Int64 = 1000; var mono: Double = 0
    var registered = true; var cancelled = false; var policy: NotesPolicy?
}
final class NotesFixtureEffects: NotesEffects {
    var auth = "authorized"; var lock = "unlocked"; var shared = false
    var account = "synthetic-account"; var folder = "synthetic-folder"; var name = "Synthetic Folder"
    var checks = 0; var reads = 0; var creates = 0; var html = ""
    var onPermission: (() -> Void)?; var onResolve: (() -> Void)?; var onCreate: (() -> Void)?
    var result = "created_local"; var throwsCreate = false
    func permission() -> String { checks += 1; onPermission?(); return auth }
    func lockState() -> String { lock }
    func resolve(_ b: NotesFolderBinding, deadline: Double) throws -> NotesTargetMetadata {
        reads += 1; onResolve?()
        return NotesTargetMetadata(accountID: account, folderID: folder, name: name, shared: shared)
    }
    func create(_ p: NotesCreateProposal, binding: NotesFolderBinding, deadline: Double) throws -> String {
        creates += 1; html = p.html; onCreate?()
        if throwsCreate { throw ReviewFault("synthetic_reply_lost") }
        return result
    }
}
@MainActor final class NotesFixtureReviewer: NotesReviewer {
    var confirms = 0; var text = ""; var deadline: Double = -1; var remaining: Double = -1
    var polls = 0; var dismissed = false
    var decision: (NotesReviewContext) -> Bool = { _ in true }
    func confirm(_ p: NotesCreateProposal, target: NotesTargetMetadata, context: NotesReviewContext) -> Bool {
        confirms += 1; text = target.name + "\n" + p.title + "\n" + p.text
        deadline = context.deadline; remaining = context.remainingSeconds
        guard !context.shouldDismiss else { dismissed = true; return false }
        let accepted = decision(context)
        dismissed = context.shouldDismiss
        return accepted && !dismissed
    }
}
func notesJSON(_ d: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: d, options: [.sortedKeys, .withoutEscapingSlashes]) }
@MainActor func notesFixture(_ scenario: String, home: String) throws -> [String: Any] {
    let state = NotesFixtureState(); let effects = NotesFixtureEffects(); let reviewer = NotesFixtureReviewer()
    let binding = NotesFolderBinding(alias: "notes_inbox", accountID: effects.account, folderID: effects.folder, expectedName: effects.name)
    let key = Curve25519.Signing.PrivateKey() // Ephemeral fixture only, never exported.
    func policy(budget: Int = 16, epoch: Int64 = 1, binding b: NotesFolderBinding? = nil, issuers: Set<String> = ["fixture_issuer"]) -> NotesPolicy {
        NotesPolicy(epoch: epoch, callers: ["fixture_app": NotesCallerGrant(targets: [binding.alias], nativeReview: true, workflowIssuers: issuers, maxAttempts: budget)],
                    targets: [binding.alias: b ?? binding], issuerPublicKeys: ["fixture_issuer": key.publicKey.rawRepresentation])
    }
    state.policy = policy()
    func engine() throws -> NotesApprovalEngine {
        NotesApprovalEngine(journal: try ConsumptionJournal(home: home), policy: { state.policy }, clock: NotesClock(nowMS: { state.now }, monotonic: { state.mono }))
    }
    let gate = try engine(); let caller = AuthenticatedCaller.fixture("fixture_app", check: { state.registered })
    var body: [String: Any] = ["schema_version": 1, "tool": NotesCreateProposal.tool, "operation_id": "11111111-1111-4111-8111-111111111111",
                              "caller_id": "fixture_app", "target_alias": binding.alias, "title": "Synthetic \"title\" <&>",
                              "text": "Plain <script>\"'&\nend tell\r\n\t下一行", "issued_at_ms": 1000, "expires_at_ms": 61000]
    func permit(_ raw: Data, wrongKey: Bool = false, patch: [String: Any] = [:]) throws -> NotesWorkflowPermit {
        let p = try NotesCreateProposal(raw)
        var fields: [String: Any] = ["schema_version": 1, "issuer_id": "fixture_issuer", "permit_id": UUID().uuidString.lowercased(),
                                    "caller_id": p.callerID, "operation_id": p.operationID, "tool": NotesCreateProposal.tool,
                                    "request_sha256": p.rawHash, "target_binding_sha256": binding.hash, "policy_epoch": 1,
                                    "issued_at_ms": p.issuedAtMS, "expires_at_ms": p.expiresAtMS, "max_effects": 1]
        for (k, v) in patch { fields[k] = v }
        let payload = notesJSON(fields)
        return NotesWorkflowPermit(issuer: "fixture_issuer", payload: payload, signature: try (wrongKey ? Curve25519.Signing.PrivateKey() : key).signature(for: payload))
    }
    func run(_ raw: Data, _ signed: NotesWorkflowPermit? = nil, using g: NotesApprovalEngine? = nil) throws -> [String: Any] {
        try (g ?? gate).performWorkflow(raw, permit: signed ?? permit(raw), caller: caller, effects: effects, cancelled: { state.cancelled })
    }
    var output: [String: Any] = [:]
    do {
        switch scenario {
        case "default_disabled": state.policy = nil
        case "forged_caller": body["caller_id"] = "settings"
        case "invalid_peer":
            _ = try AuthenticatedCaller.fromRegisteredSocket(-1, subject: "fixture_app", expectedPID: 1, requirement: "identifier local.test", registrationEpoch: 1, currentRegistrationEpoch: { 1 })
        case "arbitrary_target": body["target_alias"] = "another_folder"
        case "raw_html": body["html"] = "<img src=file:///private/test>"
        case "approved_flag": body["approved"] = 1
        case "attachment": body["attachment_path"] = "/tmp/never-read"
        case "control": body["text"] = "unsafe\u{0}"
        case "oversize": body["text"] = String(repeating: "x", count: 8193)
        case "duplicate_key":
            let raw = Data((String(decoding: notesJSON(body), as: UTF8.self).dropLast() + ",\"t\\u0069tle\":\"duplicate\"}").utf8)
            _ = try NotesCreateProposal(raw)
        case "expired": state.now = 61000
        case "monotonic_expired": effects.onResolve = { state.mono = 20 }
        case "permission_denied": effects.auth = "denied"
        case "permission_unknown": effects.auth = "unknown"
        case "locked": effects.lock = "locked"
        case "unknown_lock": effects.lock = "unknown"
        case "shared_target": effects.shared = true
        case "renamed_target": effects.name = "Changed"
        case "moved_target": effects.account = "other-account"
        case "deleted_target": effects.folder = "another-folder"
        case "cancel_before": state.cancelled = true
        case "cancel_during_metadata": effects.onResolve = { state.cancelled = true }
        case "revoke_during_metadata": effects.onResolve = { state.registered = false }
        case "cancel_during_readiness": effects.onPermission = { if effects.checks == 2 { state.cancelled = true } }
        case "revoke_during_readiness": effects.onPermission = { if effects.checks == 2 { state.registered = false } }
        case "expire_during_readiness": effects.onPermission = { if effects.checks == 2 { state.now = 61000 } }
        case "policy_during_readiness": effects.onPermission = { if effects.checks == 2 { state.policy = policy(epoch: 2) } }
        case "budget_during_readiness": effects.onPermission = { if effects.checks == 2 { state.policy = policy(budget: 1) } }
        case "target_policy_during_readiness": effects.onPermission = {
            if effects.checks == 2 { state.policy = policy(binding: NotesFolderBinding(alias: binding.alias, accountID: binding.accountID, folderID: "changed", expectedName: binding.expectedName)) }
        }
        case "issuer_during_readiness": effects.onPermission = { if effects.checks == 2 { state.policy = policy(issuers: []) } }
        case "late_cancel": effects.onCreate = { state.cancelled = true }
        case "uncertain": effects.throwsCreate = true
        case "replay_restart":
            let raw = notesJSON(body); _ = try run(raw); output = try run(raw, using: engine())
        case "uncertain_restart":
            let raw = notesJSON(body)
            effects.throwsCreate = true; do { _ = try run(raw) } catch {}
            effects.throwsCreate = false; output = try run(raw, using: engine())
        case "budget":
            state.policy = policy(budget: 1); _ = try run(notesJSON(body))
            body["operation_id"] = "33333333-3333-4333-8333-333333333333"
        case "bad_signature": output = try run(notesJSON(body), permit(notesJSON(body), wrongKey: true))
        case "tamper":
            let signed = try permit(notesJSON(body)); body["text"] = "Changed body"; output = try run(notesJSON(body), signed)
        case "wrong_binding": output = try run(notesJSON(body), permit(notesJSON(body), patch: ["target_binding_sha256": String(repeating: "a", count: 64)]))
        case "native_review", "native_cancel", "native_expiry", "native_slow_review", "native_cancel_review", "native_cancel_before_review", "native_expire_before_review", "native_remaining_review":
            if scenario == "native_cancel" { reviewer.decision = { _ in false } }
            if scenario == "native_expiry" { reviewer.decision = { _ in state.mono = 20; return true } }
            if scenario == "native_cancel_before_review" { effects.onResolve = { state.cancelled = true } }
            if scenario == "native_expire_before_review" { effects.onResolve = { state.mono = 20 } }
            if scenario == "native_remaining_review" { effects.onResolve = { state.mono = 7 } }
            if scenario == "native_slow_review" || scenario == "native_cancel_review" {
                // Synthetic modal poll loop. Virtual time avoids a real20s wait
                // and never instantiates AppKit or invokes a Notes effect.
                reviewer.decision = { context in
                    for tick in 1...30 {
                        state.mono = Double(tick); reviewer.polls += 1
                        if scenario == "native_cancel_review" && tick == 2 { state.cancelled = true }
                        if context.shouldDismiss { return false }
                    }
                    return true
                }
            }
            output = try gate.performNative(notesJSON(body), caller: caller, reviewer: reviewer, effects: effects, cancelled: { state.cancelled })
        case "descriptors":
            let p = try NotesCreateProposal(notesJSON(body)); let event = try NotesAppleEvents.createEvent(p, binding: binding)
            guard event.eventClass == NotesAppleEvents.core, event.eventID == NotesAppleEvents.make,
                  event.paramDescriptor(forKeyword: 0x6b6f636c)?.typeCodeValue == NotesAppleEvents.note,
                  let location = event.paramDescriptor(forKeyword: 0x696e7368), location.descriptorType == NotesAppleEvents.objectSpecifier,
                  location.forKeyword( NotesAppleEvents.selector)?.stringValue == binding.folderID,
                  let props = event.paramDescriptor(forKeyword: 0x70726474), props.numberOfItems == 2,
                  props.forKeyword( NotesAppleEvents.name)?.stringValue == p.title,
                  props.forKeyword( NotesAppleEvents.body)?.stringValue == p.html else { throw ReviewFault("descriptor_test_failed") }
            output = ["typed_descriptors": true, "escaped_html": p.html, "status": "ok"]
        case "reply_error":
            let reply = NotesAppleEvents.event(0x616e7372)
            reply.setParam(NSAppleEventDescriptor(int32: -1743), forKeyword: NotesAppleEvents.errorNumber)
            _ = try NotesAppleEvents.decodeReply(reply)
        case "success": break
        default: throw ReviewFault("unknown_fixture")
        }
        if output.isEmpty { output = try run(notesJSON(body)) }
        output["status"] = "ok"
    } catch let error as ReviewFault { output = ["status": error.code] }
    output["create_calls"] = effects.creates; output["metadata_calls"] = effects.reads
    output["permission_checks"] = effects.checks; output["native_confirmations"] = reviewer.confirms
    output["review_deadline"] = reviewer.deadline; output["review_remaining_seconds"] = reviewer.remaining
    output["review_polls"] = reviewer.polls; output["review_dismissed"] = reviewer.dismissed
    output["review_text"] = reviewer.text; output["html"] = effects.html
    return output
}
@main struct NotesFixtureMain {
    @MainActor static func main() throws {
        guard CommandLine.arguments.count == 3 else { throw ReviewFault("fixture_arguments") }
        let result = try notesFixture(CommandLine.arguments[1], home: CommandLine.arguments[2])
        print(String(decoding: notesJSON(result), as: UTF8.self))
    }
}
