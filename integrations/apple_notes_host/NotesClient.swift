import Foundation

@MainActor protocol NotesFrameTransport {
    // Exactly one attempt; throws on lost acknowledgement, never auto-replays.
    func exchange(_ frame: Data, deadline: Double) throws -> Data
}

@MainActor final class NotesCreateConsumer {
    private let transport: NotesFrameTransport
    private let targetHash: String
    init(transport: NotesFrameTransport, registeredTarget: NotesFolderBinding) throws {
        try registeredTarget.validate()
        self.transport = transport; targetHash = registeredTarget.hash
    }
    func create(_ reviewedRaw: Data, deadline: Double) throws -> [String: Any] {
        let proposal = try NotesCreateProposal(reviewedRaw)
        let response: Data
        do { response = try transport.exchange(NotesWire.create(reviewedRaw), deadline: deadline) }
        catch { throw ReviewFault("outcome_unknown") } // no second exchange
        return try NotesWire.receipt(response, proposal: proposal, targetHash: targetHash)
    }
    func cancel(operationID: String, requestHash: String, deadline: Double) throws {
        let response = try transport.exchange(NotesWire.cancel(operationID, requestHash: requestHash), deadline: deadline)
        let v = try flatObject(response, limit: NotesWire.maxResponseFrame - 1)
        guard Set(v.keys) == Set(["schema_version", "method", "status", "receipt_json", "error_code"]),
              integer(v["schema_version"]) == 1, v["method"] as? String == "cancel", v["status"] as? String == "ok",
              v["receipt_json"] is NSNull, v["error_code"] is NSNull else { throw ReviewFault("cancel_not_acknowledged") }
        // This ack changes the cancellation signal only. It is not evidence of
        // an upstream stop, rollback, or that Notes did not create a note.
    }
}
