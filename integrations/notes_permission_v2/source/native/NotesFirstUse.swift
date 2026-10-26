import Foundation
import CryptoKit

// Trusted native composition only. None of these policy/identity fields are
// accepted from an operation request or a claimed approved=true value.
struct NotesFirstUsePlan {
    let binding: NativeBinding
    let operationID: String
    let title: String
    let plaintext: String
    let expiresAtMS: Int64

    func validate(now: Int64) throws {
        try binding.validate()
        guard UUID(uuidString: operationID)?.uuidString.lowercased() == operationID,
              title.contains(operationID), !title.contains("\n"), !title.contains("\r"),
              !title.isEmpty, title.count <= 300, title.utf8.count <= 1024,
              !plaintext.isEmpty, plaintext.count <= 4096, plaintext.utf8.count <= 8192,
              !title.contains("\0"), !plaintext.contains("\0"),
              expiresAtMS > now, expiresAtMS - now <= 120000 else { throw NativeFault("invalid_first_use_plan") }
        guard title.unicodeScalars.allSatisfy({ $0.value >= 32 && !((127...159).contains($0.value)) }),
              plaintext.unicodeScalars.allSatisfy({ $0.value >= 32 && !((127...159).contains($0.value)) || [9, 10, 13].contains($0.value) }) else { throw NativeFault("invalid_first_use_plan") }
    }
    var html: String {
        func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
                .replacingOccurrences(of: "'", with: "&#x27;")
        }
        let body = escape(plaintext.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n"))
            .replacingOccurrences(of: "\t", with: "&#9;").replacingOccurrences(of: "\n", with: "<br>")
        return "<div><b>" + escape(title) + "</b></div><div>" + body + "</div>"
    }
    var digest: String { get throws {
        let value: [String: Any] = ["account_id": binding.account_id, "folder_id": binding.folder_id,
            "expected_name": binding.expected_name, "operation_id": operationID, "title": title,
            "plaintext": plaintext, "expires_at_ms": expiresAtMS, "limit": 1, "scan_limit": 1, "search_body": false]
        return try notesFirstUseHash(value)
    } }
}

func notesFirstUseHash(_ value: [String: Any]) throws -> String {
    let raw = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
    return "sha256:" + SHA256.hash(data: raw).map { String(format: "%02x", $0) }.joined()
}

func notesFirstUseFalse(_ value: Any?) -> Bool {
    guard let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return false }
    return !n.boolValue
}

protocol NotesFirstUseSurface: AnyObject {
    var effectStarted: Bool { get }
    func preflight(create: Bool) throws
    func emptyFolder() throws -> Bool
    func create(title: String, html: String, beforeEffect: () throws -> Void) throws -> String
    func snapshot(_ id: String) throws -> [String: Any]
    func search(title: String) throws -> [String: Any]
}

final class NativeNotesFirstUseSurface: NotesFirstUseSurface {
    private let native: NativeNotes
    var effectStarted: Bool { native.effectStarted }
    init(plan: NotesFirstUsePlan) throws {
        native = try NativeNotes(binding: plan.binding, grantExpiresAtMS: plan.expiresAtMS)
    }
    func preflight(create: Bool) throws {
        try native.ready(create ? [NotesEvents.get, NotesEvents.count, NotesEvents.make] : [NotesEvents.get, NotesEvents.count])
        _ = try native.folderMetadata()
    }
    func emptyFolder() throws -> Bool { try native.count(NotesEvents.note, in: native.binding.folder) == 0 }
    func create(title: String, html: String, beforeEffect: () throws -> Void) throws -> String {
        // Recheck directly before make; creates a new object only. A competing
        // new note may invalidate search acceptance but cannot be overwritten.
        guard try emptyFolder() else { throw NativeFault("test_folder_not_empty") }
        guard let id = try native.create(title: title, html: html, finalAdmission: beforeEffect)["id"] else { throw NativeFault("invalid_native_response") }
        return id
    }
    func snapshot(_ id: String) throws -> [String: Any] { try native.snapshot(id) }
    func search(title: String) throws -> [String: Any] { try native.search(query: title, body: false, limit: 1, scan: 1) }
}

struct NotesFirstUseOutcomeFault: Error {
    let code: String
    let indeterminate: Bool
}

// A host-authenticated, short-lived, single-proposal state machine. The owner
// supplies its kernel/signature/epoch/profile verification and durable journal.
// There is no listener, caller enrollment, persistent grant or permission prompt.
final class NotesFirstUseSession {
    let plan: NotesFirstUsePlan
    private let surface: () throws -> NotesFirstUseSurface
    private let verifyHostAndPeer: () throws -> Void
    private let consumeAttempt: (String, String) throws -> Void
    private let clock: () -> Int64
    private let lock = NSLock()
    private var attempted = false
    private var uncertain = false
    private(set) var createdID: String?

    init(plan: NotesFirstUsePlan, verifyHostAndPeer: @escaping () throws -> Void,
         consumeAttempt: @escaping (String, String) throws -> Void,
         clock: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
         surface: (() throws -> NotesFirstUseSurface)? = nil) throws {
        try plan.validate(now: clock())
        self.plan = plan; self.verifyHostAndPeer = verifyHostAndPeer
        self.consumeAttempt = consumeAttempt; self.clock = clock
        self.surface = surface ?? { try NativeNotesFirstUseSurface(plan: plan) }
    }
    private func admitted() throws {
        guard clock() < plan.expiresAtMS else { throw NativeFault("grant_expired") }
        try verifyHostAndPeer() // actual responsible code/peer/profile; no RPC identity assertion
        guard clock() < plan.expiresAtMS else { throw NativeFault("grant_expired") }
    }
    private func checkedSnapshot(_ raw: [String: Any], id: String) throws -> [String: Any] {
        func normalize(_ text: String) -> String { text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n") }
        let literal = normalize(plan.plaintext)
        let allowed = [plan.title + "\n" + literal, plan.title + "\n\n" + literal]
            .flatMap { [$0, $0 + "\n"] }
        guard Set(raw.keys) == Set(["id", "account_id", "folder_id", "title", "html", "plaintext", "modified", "password_protected", "shared", "attachments"]),
              raw["id"] as? String == id, raw["account_id"] as? String == plan.binding.account_id,
              raw["folder_id"] as? String == plan.binding.folder_id, raw["title"] as? String == plan.title,
              notesFirstUseFalse(raw["password_protected"]), notesFirstUseFalse(raw["shared"]),
              let attachments = raw["attachments"] as? [Any], attachments.isEmpty,
              let plaintext = raw["plaintext"] as? String, let html = raw["html"] as? String,
              let modified = raw["modified"] as? String, !modified.isEmpty,
              html.utf8.count <= 32768, plaintext.utf8.count <= 16384,
              allowed.contains(normalize(plaintext)) else { throw NativeFault("verification_failed") }
        return raw
    }
    func handle(method: String, args: [String: Any]) throws -> [String: Any] {
        guard lock.try() else { throw NotesFirstUseOutcomeFault(code: "busy", indeterminate: false) }
        defer { lock.unlock() }
        var api: NotesFirstUseSurface?
        do {
            guard !uncertain else { throw NativeFault("needs_review") }
            guard ["create", "read", "search"].contains(method) else { throw NativeFault("unsupported_operation") }
            switch method {
            case "create":
                guard Set(args.keys) == Set(["operation_id", "title", "content", "format"]),
                      args["operation_id"] as? String == plan.operationID, args["title"] as? String == plan.title,
                      args["content"] as? String == plan.plaintext, args["format"] as? String == "plaintext" else { throw NativeFault("proposal_mismatch") }
                guard !attempted else { throw NativeFault("operation_consumed") }
            case "read":
                guard Set(args.keys) == Set(["id"]), let id = createdID, args["id"] as? String == id else { throw NativeFault("target_not_granted") }
            case "search":
                guard Set(args.keys) == Set(["query", "search_body", "limit", "scan_limit"]), createdID != nil,
                      args["query"] as? String == plan.title,
                      let body = args["search_body"] as? NSNumber, CFGetTypeID(body) == CFBooleanGetTypeID(), !body.boolValue,
                      let limit = args["limit"] as? NSNumber, CFGetTypeID(limit) != CFBooleanGetTypeID(), limit.intValue == 1, limit.doubleValue == 1,
                      let scan = args["scan_limit"] as? NSNumber, CFGetTypeID(scan) != CFBooleanGetTypeID(), scan.intValue == 1, scan.doubleValue == 1 else { throw NativeFault("proposal_mismatch") }
            default: throw NativeFault("unsupported_operation")
            }
            try admitted()
            let backend = try surface(); api = backend
            try backend.preflight(create: method == "create") // ask=false only, after identity/proposal/expiry
            try admitted()
            if method == "create" {
                guard try backend.emptyFolder() else { throw NativeFault("test_folder_not_empty") }
                try admitted()
                attempted = true // Even a partial/failed journal claim is never automatically replayed.
                try consumeAttempt(plan.operationID, plan.digest)
                try admitted()
                let id = try backend.create(title: plan.title, html: plan.html, beforeEffect: admitted)
                try canonicalID(id, entity: "ICNote")
                createdID = id
                let snapshot = try checkedSnapshot(backend.snapshot(id), id: id)
                try admitted()
                return ["operation_id": plan.operationID, "id": id, "previous_revision": NSNull(),
                    "revision": try notesFirstUseHash(snapshot), "persistence": "verified_local",
                    "cloud_sync": "not_checked", "preservation": "new_note_only", "attachment_id": NSNull()]
            }
            let id = createdID!
            if method == "read" {
                let result = try checkedSnapshot(backend.snapshot(id), id: id)
                try admitted()
                return result
            }
            let result = try backend.search(title: plan.title)
            func exactInteger(_ value: Any?, _ expected: Int) -> Bool {
                guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return false }
                return n.intValue == expected && n.doubleValue == Double(expected)
            }
            guard Set(result.keys) == Set(["notes", "scanned", "scan_truncated", "unreadable"]),
                  exactInteger(result["scanned"], 1), exactInteger(result["unreadable"], 0),
                  let partial = result["scan_truncated"] as? NSNumber, CFGetTypeID(partial) == CFBooleanGetTypeID(), !partial.boolValue,
                  let notes = result["notes"] as? [[String: Any]], notes.count == 1,
                  Set(notes[0].keys) == Set(["id", "title", "account_id", "folder_id", "modified", "password_protected", "shared"]),
                  let modified = notes[0]["modified"] as? String, !modified.isEmpty, modified.utf8.count <= 4096,
                  notes[0]["id"] as? String == id, notes[0]["title"] as? String == plan.title,
                  notes[0]["account_id"] as? String == plan.binding.account_id, notes[0]["folder_id"] as? String == plan.binding.folder_id,
                  notesFirstUseFalse(notes[0]["password_protected"]), notesFirstUseFalse(notes[0]["shared"]) else { throw NativeFault("verification_failed") }
            try admitted()
            return result
        } catch {
            let effect = api?.effectStarted == true
            if effect { uncertain = true }
            throw NotesFirstUseOutcomeFault(code: effect ? "needs_review" : (error as? NativeFault)?.code ?? "host_admission_failed", indeterminate: effect || uncertain)
        }
    }
}
