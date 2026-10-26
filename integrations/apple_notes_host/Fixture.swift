// All stores/transport/presentation are doubles. No NSAlert, Notes or TCC call.
import Foundation
import AppKit

final class HostFixtureState { var now: Int64 = 1000; var mono: Double = 0; var registered = true }
final class HostFixtureEffects: NotesEffects {
    var creates = 0; var reads = 0; var onRead: (() -> Void)?
    func permission() -> String { "authorized" }
    func lockState() -> String { "unlocked" }
    func resolve(_ b: NotesFolderBinding, deadline: Double) throws -> NotesTargetMetadata {
        reads += 1; onRead?()
        return NotesTargetMetadata(accountID: b.accountID, folderID: b.folderID, name: b.expectedName, shared: false)
    }
    func create(_ p: NotesCreateProposal, binding: NotesFolderBinding, deadline: Double) throws -> String { creates += 1; return "created_local" }
}
@MainActor final class HostFixturePanel: NotesReviewPresentation {
    var display = ""; var runs = 0; var dismissed = false; var accepted = true; var pump = false
    var onPrepare: (() -> Void)?; var onRun: (() -> Void)?
    func prepare(_ p: NotesCreateProposal, target: NotesTargetMetadata) { display = target.name + "\n" + p.title + "\n" + p.text; onPrepare?() }
    func runModal() -> Bool {
        runs += 1; onRun?()
        if pump {
            let cap = Date().addingTimeInterval(0.5)
            while !dismissed && Date() < cap { _ = RunLoop.main.run(mode: .modalPanel, before: Date().addingTimeInterval(0.02)) }
        }
        return accepted
    }
    func dismiss() { dismissed = true }
}
@MainActor final class HostFixtureTransport: NotesFrameTransport {
    let host: NotesHostSession
    var exchanges = 0; var lose = false; var corrupt = false; var lastFrame = Data()
    init(_ host: NotesHostSession) { self.host = host }
    func exchange(_ frame: Data, deadline: Double) throws -> Data {
        exchanges += 1; lastFrame = frame
        let reply = try host.handle(frame)
        if lose { throw ReviewFault("fixture_reply_lost") }
        if corrupt {
            var v = try flatObject(reply); var receipt = try flatObject(Data((v["receipt_json"] as! String).utf8))
            receipt["operation_id"] = "33333333-3333-4333-8333-333333333333"
            v["receipt_json"] = String(decoding: try JSONSerialization.data(withJSONObject: receipt), as: UTF8.self)
            return try JSONSerialization.data(withJSONObject: v)
        }
        return reply
    }
}
@MainActor func hostFixture(_ scenario: String, home: String) throws -> [String: Any] {
    let state = HostFixtureState(), effects = HostFixtureEffects(), panel = HostFixturePanel()
    let binding = NotesFolderBinding(alias: "notes_inbox", accountID: "synthetic-account", folderID: "synthetic-folder", expectedName: "Synthetic Folder")
    let policy = NotesPolicy(epoch: 1, callers: ["fixture_app": NotesCallerGrant(targets: [binding.alias], nativeReview: true, workflowIssuers: [], maxAttempts: 1)], targets: [binding.alias: binding], issuerPublicKeys: [:])
    func engine() throws -> NotesApprovalEngine {
        NotesApprovalEngine(journal: try ConsumptionJournal(home: home), policy: { policy }, clock: NotesClock(nowMS: { state.now }, monotonic: { state.mono }))
    }
    let caller = AuthenticatedCaller.fixture("fixture_app", check: { state.registered })
    let reviewer = NativeNotesReviewer(presentation: { panel }, pollInterval: 0.005)
    let host = NotesHostSession.fixture(caller: caller, engine: try engine(), reviewer: reviewer, effects: effects)
    let transport = HostFixtureTransport(host)
    let consumer = try NotesCreateConsumer(transport: transport, registeredTarget: binding)
    var fields: [String: Any] = ["schema_version": 1, "tool": NotesCreateProposal.tool, "operation_id": "11111111-1111-4111-8111-111111111111", "caller_id": "fixture_app", "target_alias": "notes_inbox", "title": "完整标题 <&>", "text": "Plain <script>\n\t下一行", "issued_at_ms": 1000, "expires_at_ms": 61000]
    func raw() throws -> Data { try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]) }
    let original = try raw(), p = try NotesCreateProposal(original)
    switch scenario {
    case "decline": panel.accepted = false
    case "timer_expiry": panel.pump = true; panel.onRun = { state.mono = 21 }
    case "cancel":
        panel.pump = true; panel.onRun = { try! consumer.cancel(operationID: p.operationID, requestHash: p.rawHash, deadline: 25) }
    case "disconnect": panel.pump = true; panel.onRun = { host.disconnect() }
    case "revoke": panel.onRun = { state.registered = false }
    case "prepare_expiry": panel.onPrepare = { state.mono = 21 }
    case "metadata_expiry": effects.onRead = { state.now = 62000 }
    case "caller_spoof": fields["caller_id"] = "settings"
    case "target_spoof": fields["target_alias"] = "other_folder"
    case "lost_receipt": transport.lose = true
    case "wrong_receipt": transport.corrupt = true
    case "wrong_cancel":
        panel.onRun = {
            let wrong = try! NotesWire.cancel("22222222-2222-4222-8222-222222222222", requestHash: p.rawHash)
            let ack = try! flatObject(host.handle(wrong))
            precondition(ack["error_code"] as? String == "operation_not_active")
        }
    default: break
    }
    var output: [String: Any] = [:]
    do {
        let bytes = try raw()
        if scenario == "invalid_fd" {
            _ = try NotesHostSession.fromRegisteredSocket(-1, registration: NotesPeerRegistration(subject: "fixture_app", pid: 1, requirement: "cdhash H\"0000000000000000000000000000000000000000\"", epoch: 1, currentEpoch: { 1 }), engine: engine(), reviewer: reviewer, effects: effects)
        } else if scenario == "bad_hash" {
            var v = try flatObject(NotesWire.create(bytes)); v["request_sha256"] = String(repeating: "0", count: 64)
            output = try flatObject(host.handle(JSONSerialization.data(withJSONObject: v)))
            output["status"] = output["error_code"]
        } else {
            output = try consumer.create(bytes, deadline: 25)
            output["status"] = "ok"
            if scenario == "duplicate_restart" {
                let restarted = NotesHostSession.fixture(caller: caller, engine: try engine(), reviewer: reviewer, effects: effects)
                let next = try NotesCreateConsumer(transport: HostFixtureTransport(restarted), registeredTarget: binding)
                _ = try next.create(bytes, deadline: 25)
            }
            if scenario == "budget" {
                fields["operation_id"] = "22222222-2222-4222-8222-222222222222"
                _ = try consumer.create(raw(), deadline: 25)
            }
        }
    } catch let error as ReviewFault { output["status"] = error.code }
    output["creates"] = effects.creates; output["reads"] = effects.reads
    output["modal_runs"] = panel.runs; output["dismissed"] = panel.dismissed
    output["display"] = panel.display; output["exchanges"] = transport.exchanges
    output["wire_bytes"] = transport.lastFrame.count + 1
    output["notes_calls"] = 0
    return output
}
@main struct NotesHostFixtureMain {
    @MainActor static func main() throws {
        let result = try hostFixture(CommandLine.arguments[1], home: CommandLine.arguments[2])
        print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
    }
}
