import Foundation
import CryptoKit

struct NotesDirectFolder: Identifiable, Equatable, Sendable, Codable {
    let accountID: String
    let accountName: String
    let id: String
    let name: String
    func validate() throws {
        try NotesDirectContract.identifier(accountID, entity: "ICAccount")
        try NotesDirectContract.identifier(id, entity: "ICFolder")
        try NotesDirectContract.metadataText(accountName, maximum: 1024, step: .notesAccountName)
        try NotesDirectContract.metadataText(name, maximum: 1024, step: .notesFolderName)
    }
    var label: String { NotesDirectContract.metadataLabel(accountName) + " / " + NotesDirectContract.metadataLabel(name) }
}

struct NotesDirectScope: Equatable, Sendable, Codable {
    let folder: NotesDirectFolder
    let expires: Date
    func validate(now: Date = Date()) throws {
        try folder.validate()
        guard expires > now, expires.timeIntervalSince(now) <= 600 else { throw AppleDirectFault("scope_expired") }
    }
}

struct NotesDirectRow: Identifiable, Equatable, Sendable, Codable {
    let id: String
    let title: String
    let modified: Date
}
struct NotesDirectSearch: Sendable, Codable {
    let notes: [NotesDirectRow]
    let scanned: Int
    let total: Int
    var offset: Int? = nil
    var next_offset: Int? = nil
}
struct NotesDirectRead: Sendable, Codable {
    let row: NotesDirectRow
    let plaintext: String
    let bodyDigest: String?
    let editableText: String?
    let editRestriction: String?
    var offset: Int? = nil
    var next_offset: Int? = nil
    var total_bytes: Int? = nil
    init(row: NotesDirectRow, plaintext: String, bodyDigest: String? = nil, editableText: String? = nil, editRestriction: String? = nil) {
        self.row = row; self.plaintext = plaintext; self.bodyDigest = bodyDigest
        self.editableText = editableText; self.editRestriction = editRestriction
    }
}

// The editor carries its displayed source, independent of later controller reads.
struct NotesDirectEditorSource: Equatable, Codable, Sendable {
    let folder: NotesDirectFolder
    let row: NotesDirectRow
    let bodyDigest: String
}
extension NotesDirectRead {
    func editorSource(folder: NotesDirectFolder) -> NotesDirectEditorSource? {
        guard editableText != nil, let bodyDigest else { return nil }
        return .init(folder: folder, row: row, bodyDigest: bodyDigest)
    }
}

struct NotesDirectProposal: Identifiable, Equatable, Sendable, Codable {
    let id: UUID
    let scope: NotesDirectScope
    let title: String
    let plaintext: String
    let expires: Date
    func validate(now: Date = Date()) throws {
        try scope.validate(now: now)
        try NotesDirectContract.text(title, maximum: 1024, multiline: false)
        try NotesDirectContract.text(plaintext, maximum: 8192, multiline: true)
        guard expires > now, expires <= scope.expires, expires.timeIntervalSince(now) <= 120 else {
            throw AppleDirectFault("proposal_expired")
        }
    }
    var digest: String {
        // Array encodes field boundaries; different text/target is never the
        // same approval. No content or target is stored in the journal.
        let fields = [id.uuidString.lowercased(), scope.folder.accountID, scope.folder.accountName,
                      scope.folder.id, scope.folder.name, title, plaintext,
                      String(scope.expires.timeIntervalSince1970), String(expires.timeIntervalSince1970)]
        let data = try! JSONEncoder().encode(fields)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    var html: String {
        "<div><b>" + NotesDirectContract.escape(title) + "</b></div><div>" +
        NotesDirectContract.escape(plaintext.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n"))
            .replacingOccurrences(of: "\n", with: "<br>").replacingOccurrences(of: "\t", with: "&#9;") + "</div>"
    }
}

enum NotesDirectContract {
    static func identifier(_ value: String, entity: String) throws {
        guard value.utf8.count <= 1024,
              value.range(of: "^x-coredata://[0-9a-fA-F-]+/" + entity + "/p[1-9][0-9]*$", options: .regularExpression) == value.startIndex..<value.endIndex else {
            throw AppleDirectFault("invalid_target")
        }
    }
    static func text(_ value: String, maximum: Int, multiline: Bool = false) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.unicodeScalars.count <= maximum,
              value.unicodeScalars.allSatisfy({ $0.value >= 32 && !((127...159).contains($0.value)) || (multiline && [9,10,13].contains($0.value)) }) else {
            throw AppleDirectFault("invalid_text")
        }
    }
    // Provider metadata is not user-authored content. Preserve its exact value
    // for ID/name revalidation and proposal binding; only its display is escaped.
    static func metadataText(_ value: String, maximum: Int, step: AppleDirectStep) throws {
        guard value.utf8.count <= maximum else {
            throw AppleDirectFault("invalid_text", step: step, valueIssue: .tooLong)
        }
    }
    static func metadataLabel(_ value: String) -> String {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "未命名" }
        return value.unicodeScalars.map { scalar in
            if scalar.value == 92 { return "\\\\" }
            if CharacterSet.controlCharacters.contains(scalar) || CharacterSet.newlines.contains(scalar) {
                return "\\u{" + String(scalar.value, radix: 16, uppercase: true) + "}"
            }
            return String(scalar)
        }.joined()
    }
    static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#x27;")
    }
}

struct NotesDirectActionTicket: Sendable {
    let epoch: UUID
    let folder: NotesDirectFolder?
}
struct NotesDirectPageState {
    private(set) var epoch = UUID()
    private(set) var visible = false
    mutating func appear() { epoch = UUID(); visible = true }
    mutating func disappear() { epoch = UUID(); visible = false }
    mutating func cancel() { epoch = UUID() }
    func ticket(folder: NotesDirectFolder?) -> NotesDirectActionTicket? {
        visible ? .init(epoch: epoch, folder: folder) : nil
    }
    func validate(_ ticket: NotesDirectActionTicket, currentFolder: NotesDirectFolder?) throws {
        guard visible, ticket.epoch == epoch, ticket.folder == currentFolder else { throw AppleDirectFault("user_action_expired") }
    }
}

// Frozen domain wire. UI and owner adapters submit these same typed operations.
enum NotesDirectRequest: Codable, Sendable {
    case folders
    case list(scope: NotesDirectScope)
    case search(scope: NotesDirectScope, query: String)
    case page(scope: NotesDirectScope, query: String, offset: Int, limit: Int)
    case read(scope: NotesDirectScope, row: NotesDirectRow)
    case readPage(scope: NotesDirectScope, row: NotesDirectRow, offset: Int, maxBytes: Int)
    case create(proposal: NotesDirectProposal, expectedDigest: String)
    case update(proposal: NotesDirectEditProposal, expectedDigest: String)
    case delete(proposal: NotesDirectDeleteProposal, expectedDigest: String)
}
enum NotesDirectResult: Codable, Sendable {
    case folders([NotesDirectFolder])
    case search(NotesDirectSearch)
    case read(NotesDirectRead)
    case mutation(itemID: String, outcome: String)
}
struct NotesDirectReply: Codable, Sendable {
    let result: NotesDirectResult
    let businessLogAvailable: Bool
}
struct NotesDirectEditProposal: Codable, Equatable, Sendable {
    let id: UUID
    let scope: NotesDirectScope
    let row: NotesDirectRow
    let sourceBodyDigest: String
    let title: String
    let plaintext: String
    let expires: Date
    func validate(now: Date = Date()) throws {
        try scope.validate(now: now)
        try NotesDirectContract.identifier(row.id, entity: "ICNote")
        try NotesDirectContract.text(title, maximum: 1024)
        if !plaintext.isEmpty { try NotesDirectContract.text(plaintext, maximum: 8192, multiline: true) }
        guard sourceBodyDigest.count == 64, sourceBodyDigest.allSatisfy({ "0123456789abcdef".contains($0) }),
              row.modified.timeIntervalSince1970.isFinite,
              expires > now, expires <= scope.expires, expires.timeIntervalSince(now) <= 120 else {
            throw AppleDirectFault("proposal_expired")
        }
    }
    var html: String { NotesDirectProposal(id: id, scope: scope, title: title, plaintext: plaintext, expires: expires).html }
    var digest: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return NotesDirectContract.digest(try! encoder.encode(self))
    }
}
extension NotesDirectEditProposal {
    static func fromEditor(id: UUID = UUID(), scope: NotesDirectScope, source: NotesDirectEditorSource,
        currentSource: NotesDirectEditorSource?, title: String, plaintext: String, expires: Date) throws -> Self {
        guard source == currentSource, source.folder == scope.folder else { throw AppleDirectFault("editor_source_changed") }
        let proposal = Self(id: id, scope: scope, row: source.row, sourceBodyDigest: source.bodyDigest,
                            title: title, plaintext: plaintext, expires: expires)
        try proposal.validate()
        return proposal
    }
}

extension NotesDirectContract {
    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    // A narrow lossless grammar: plain div/br text, with optional bold title.
    // Any attributes, links, lists, tables, images, or other formatting stays read-only.
    static func editableBody(html: String, title: String, plaintext: String, attachments: Int) -> String? {
        guard attachments == 0 else { return nil }
        let heading = "<div><b>" + escape(title) + "</b></div>"
        var body = html
        if body.hasPrefix(heading) { body = "<div>" + escape(title) + "</div>" + body.dropFirst(heading.count) }
        let pattern = #"^(?:<div>(?:[^<&]|&(?:amp|lt|gt|quot|#x27|#9);|<br>|<br/>|<br />)*</div>\s*)+$"#
        guard body.range(of: pattern, options: .regularExpression) == body.startIndex..<body.endIndex else { return nil }
        var decoded = body.replacingOccurrences(of: "</div>\n", with: "</div>")
            .replacingOccurrences(of: "<div>", with: "").replacingOccurrences(of: "</div>", with: "\n")
        for tag in ["<br>", "<br/>", "<br />"] { decoded = decoded.replacingOccurrences(of: tag, with: "\n") }
        for pair in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#x27;", "'"), ("&#9;", "\t"), ("&amp;", "&")] {
            decoded = decoded.replacingOccurrences(of: pair.0, with: pair.1)
        }
        let normalized = plaintext.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        guard decoded == normalized || decoded == normalized + "\n", decoded.hasPrefix(title + "\n") else { return nil }
        var content = String(decoded.dropFirst(title.count + 1))
        if content.hasSuffix("\n") { content.removeLast() }
        return content
    }
}

// A single plain-text, attachment-free note in the already selected folder.
// Deletion is a separate frozen intent; it never inherits an edit approval.
struct NotesDirectDeleteProposal: Codable, Equatable, Sendable {
    let id: UUID
    let scope: NotesDirectScope
    let row: NotesDirectRow
    let sourceBodyDigest: String
    let expires: Date
    func validate(now: Date = Date()) throws {
        try scope.validate(now: now)
        try NotesDirectContract.identifier(row.id, entity: "ICNote")
        guard row.title.utf8.count <= 4096, row.modified.timeIntervalSince1970.isFinite,
              sourceBodyDigest.count == 64, sourceBodyDigest.allSatisfy({ "0123456789abcdef".contains($0) }),
              expires > now, expires <= scope.expires, expires.timeIntervalSince(now) <= 120 else {
            throw AppleDirectFault("proposal_expired")
        }
    }
    var digest: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return NotesDirectContract.digest(Data("notes.delete.v1\n".utf8) + (try! encoder.encode(self)))
    }
}
