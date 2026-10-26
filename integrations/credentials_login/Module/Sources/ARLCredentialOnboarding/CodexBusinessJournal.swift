import Foundation

/// Exact user text and original task replies stay in the existing local,
/// owner-only eight-day fsynced journal implementation. No auth material.
public final class CodexBusinessJournal: @unchecked Sendable {
    private let journal: MusicBusinessJournal
    public init(directory: URL) { journal = MusicBusinessJournal(directory: directory) }
    public func record(action: String, operationID: UUID, argumentsJSON: Data, responseJSON: Data?) throws {
        guard ["submit", "get", "cancel"].contains(action) else { throw CredentialError.invalidInput }
        _ = try MusicStrictJSON.object(argumentsJSON, limit: 16384)
        if let responseJSON { _ = try MusicStrictJSON.object(responseJSON, limit: 65536, maximumDepth: 32) }
        var row: [String: Any] = ["event": responseJSON == nil ? "codex_request" : "codex_response",
            "tool": "codex.text.plan.v1", "action": action, "arguments_text": String(decoding: argumentsJSON, as: UTF8.self)]
        if let responseJSON { row["response_text"] = String(decoding: responseJSON, as: UTF8.self) }
        try journal.append(row, requestID: operationID, callID: operationID)
    }
}
