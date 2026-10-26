import Foundation

// Private source contract; not registered/published on any transport.
struct NotesCreateProposal {
    static let tool = "apple.notes.create.v1"
    let operationID: String
    let callerID: String
    let targetAlias: String
    let title: String
    let text: String
    let issuedAtMS: Int64
    let expiresAtMS: Int64
    let rawHash: String

    init(_ data: Data) throws {
        let p = try flatObject(data, limit: 16384)
        guard Set(p.keys) == Set(["schema_version", "tool", "operation_id", "caller_id", "target_alias", "title", "text", "issued_at_ms", "expires_at_ms"]),
              integer(p["schema_version"]) == 1, p["tool"] as? String == Self.tool,
              let op = p["operation_id"] as? String, uuid(op),
              let caller = p["caller_id"] as? String, identifier(caller),
              let alias = p["target_alias"] as? String, identifier(alias),
              let title = p["title"] as? String, safeText(title, limit: 300), title.utf8.count <= 1024,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let text = p["text"] as? String, text.utf8.count <= 8192,
              !text.unicodeScalars.contains(where: { ($0.value < 32 && ![9, 10, 13].contains($0.value)) || (127...159).contains($0.value) }),
              let issued = integer(p["issued_at_ms"]), let expiry = integer(p["expires_at_ms"]),
              issued >= 0, expiry > issued, expiry - issued <= 60000 else { throw ReviewFault("invalid_arguments") }
        operationID = op; callerID = caller; targetAlias = alias
        self.title = title; self.text = text; issuedAtMS = issued; expiresAtMS = expiry
        rawHash = digest(data)
    }

    // Notes receives HTML only for the NEW note. Never expose arbitrary HTML,
    // file/attachment/URL parameters, or read/write an existing note body.
    var html: String {
        let plain = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return "<div><b>" + Self.escape(title) + "</b></div><div>" + Self.escape(plain).replacingOccurrences(of: "\n", with: "<br>") + "</div>"
    }
    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;").replacingOccurrences(of: "\t", with: "&#9;")
    }
}

// Trusted registration, never decoded from request. V1 deliberately supports
// only one explicitly chosen TOP-LEVEL, non-shared folder in one account.
struct NotesFolderBinding {
    let alias: String
    let accountID: String
    let folderID: String
    let expectedName: String
    func validate() throws {
        guard identifier(alias), safeText(accountID, limit: 1024), accountID.utf8.count <= 2048,
              safeText(folderID, limit: 1024), folderID.utf8.count <= 2048,
              safeText(expectedName, limit: 200) else { throw ReviewFault("invalid_target_registration") }
    }
    var hash: String {
        digest(Data([NotesCreateProposal.tool, alias, accountID, folderID, expectedName, "top_level_non_shared"].joined(separator: "\u{0}").utf8))
    }
}
struct NotesTargetMetadata {
    let accountID: String
    let folderID: String
    let name: String
    let shared: Bool
}
struct NotesClock {
    let nowMS: () -> Int64
    let monotonic: () -> Double
    static var system: NotesClock { NotesClock(nowMS: { Int64(Date().timeIntervalSince1970 * 1000) }, monotonic: { ProcessInfo.processInfo.systemUptime }) }
}
