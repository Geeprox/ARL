import Foundation
import ApplicationServices

// Fixed public Apple events, scoped to one selected folder. No database,
// arbitrary script, attachment export, bulk delete, or global search fallback.
final class NotesDirectBackend {
    private let send: (UInt32, [UInt32: NSAppleEventDescriptor]) throws -> NSAppleEventDescriptor
    private let check: () throws -> Void
    init(session: AppleDirectSession) {
        send = { try session.send(eventID: $0, parameters: $1) }; check = session.check
    }
    // Synthetic tests provide only an in-memory transport; production uses the
    // fixed-identity session above, never input configuration or launch flags.
    init(send: @escaping (UInt32, [UInt32: NSAppleEventDescriptor]) throws -> NSAppleEventDescriptor,
         check: @escaping () throws -> Void) { self.send = send; self.check = check }
    private let account: UInt32 = 0x61636374, folder: UInt32 = 0x63666f6c, note: UInt32 = 0x6e6f7465
    private let id: UInt32 = 0x49442020, name: UInt32 = 0x706e616d, container: UInt32 = 0x636e7472
    private func get(_ code: UInt32, _ object: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor {
        try check()
        return try send(0x67657464, [0x2d2d2d2d: AppleDirectDescriptor.property(code, of: object)])
    }
    private func text(_ code: UInt32, _ object: NSAppleEventDescriptor, maximum: Int = 1024) throws -> String {
        let result = try get(code, object)
        guard [typeUnicodeText, typeUTF8Text, typeChar].contains(result.descriptorType),
              let value = result.stringValue, value.utf8.count <= maximum else { throw AppleDirectFault("invalid_response") }
        return value
    }
    private func flag(_ code: UInt32, _ object: NSAppleEventDescriptor) throws -> Bool {
        let value = try get(code, object)
        guard value.descriptorType == typeBoolean else { throw AppleDirectFault("invalid_response") }
        return value.booleanValue
    }
    private func modified(_ object: NSAppleEventDescriptor) throws -> Date {
        guard let value = try get(0x61736d6f, object).dateValue else { throw AppleDirectFault("invalid_response") }
        return value
    }
    private func count(_ kind: UInt32, _ object: NSAppleEventDescriptor) throws -> Int {
        try check()
        let value = try send(0x636e7465, AppleDirectDescriptor.countParameters(kind, parent: object))
        guard value.descriptorType == typeSInt32, value.int32Value >= 0 else { throw AppleDirectFault("invalid_response") }
        return Int(value.int32Value)
    }
    func folders() throws -> [NotesDirectFolder] {
        let total = try count(account, .null())
        var result: [NotesDirectFolder] = []
        for index in 0..<total {
            let ref = try AppleDirectDescriptor.indexed(account, index: index + 1, parent: .null())
            let accountID = try text(id, ref), accountName = try text(name, ref)
            try NotesDirectContract.identifier(accountID, entity: "ICAccount")
            let stable = try AppleDirectDescriptor.object(account, id: accountID)
            guard try text(id, stable) == accountID else { throw AppleDirectFault("target_changed") }
            let folderCount = try count(folder, stable)
            for offset in 0..<folderCount {
                let item = try AppleDirectDescriptor.indexed(folder, index: offset + 1, parent: stable)
                let parent = try AppleDirectDescriptor.property(container, of: item)
                guard try text(id, parent) == accountID else { continue } // top-level only
                guard try !flag(0x73687264, item) else { continue }
                let value = try NotesDirectFolder(accountID: accountID, accountName: accountName,
                                                  id: text(id, item), name: text(name, item))
                try value.validate()
                guard !result.contains(where: { $0.id == value.id && $0.accountID == value.accountID }) else { throw AppleDirectFault("ambiguous_target") }
                result.append(value)
            }
        }
        try check()
        return result
    }
    private func folderRef(_ value: NotesDirectFolder) throws -> NSAppleEventDescriptor {
        try value.validate()
        let parent = try AppleDirectDescriptor.object(account, id: value.accountID)
        let ref = try AppleDirectDescriptor.object(folder, id: value.id, parent: parent)
        let owner = try AppleDirectDescriptor.property(container, of: ref)
        guard try text(id, parent) == value.accountID, try text(name, parent) == value.accountName,
              try text(id, ref) == value.id, try text(name, ref) == value.name,
              try text(id, owner) == value.accountID, try !flag(0x73687264, ref) else { throw AppleDirectFault("target_changed") }
        return ref
    }
    func verify(_ scope: NotesDirectScope) throws {
        try scope.validate(); _ = try folderRef(scope.folder); try check()
    }
    private func noteRef(_ noteID: String, _ scope: NotesDirectScope) throws -> NSAppleEventDescriptor {
        try scope.validate(); try NotesDirectContract.identifier(noteID, entity: "ICNote")
        let folder = try folderRef(scope.folder)
        let ref = try AppleDirectDescriptor.object(note, id: noteID, parent: folder)
        let parent = try AppleDirectDescriptor.property(container, of: ref)
        guard try text(id, ref) == noteID, try text(id, parent) == scope.folder.id,
              try !flag(0x70777072, ref), try !flag(0x73687264, ref) else { throw AppleDirectFault("note_moved_locked_or_shared") }
        return ref
    }
    func search(_ scope: NotesDirectScope, query: String, offset: Int = 0, limit: Int = 50) throws -> NotesDirectSearch {
        try scope.validate(); if !query.isEmpty { try NotesDirectContract.text(query, maximum: 1024) }
        let folder = try folderRef(scope.folder), total = try count(note, folder)
        guard offset>=0,(1...50).contains(limit) else {throw AppleDirectFault("invalid_arguments")}
        var rows: [NotesDirectRow] = [], scanned = 0
        let start=min(offset,total),end=min(offset,total)+min(200,total-min(offset,total))
        for index in start..<end {
            try scope.validate(); try check()
            let indexed = try AppleDirectDescriptor.indexed(note, index: index + 1, parent: folder)
            scanned += 1
            let noteID = try text(id, indexed)
            try NotesDirectContract.identifier(noteID, entity: "ICNote")
            let stable = try AppleDirectDescriptor.object(note, id: noteID, parent: folder)
            guard try !flag(0x70777072, stable), try !flag(0x73687264, stable) else { continue }
            _ = try noteRef(noteID, scope)
            let revision = try modified(stable)
            let title = try text(name, stable, maximum: 4096)
            var matches = query.isEmpty || title.localizedCaseInsensitiveContains(query)
            if !matches {
                // Read only the selected, unlocked, nonshared note. Search has
                // the same parser-memory bound as paged plain-text reading.
                matches = try text(0x74657874, stable, maximum: 32*1024*1024).localizedCaseInsensitiveContains(query)
            }
            guard try modified(stable) == revision, try text(name, stable, maximum: 4096) == title else {
                throw AppleDirectFault("revision_changed")
            }
            _ = try noteRef(noteID, scope)
            guard matches else { continue }
            rows.append(try NotesDirectRow(id: noteID, title: title, modified: revision))
            if rows.count == limit { break }
        }
        try verify(scope)
        return .init(notes: rows, scanned: scanned, total: total,offset:offset,next_offset:offset+scanned<total ? offset+scanned:nil)
    }
    func read(_ scope: NotesDirectScope, row: NotesDirectRow, offset: Int = 0, maxBytes: Int = 65536) throws -> NotesDirectRead {
        let ref = try noteRef(row.id, scope)
        guard try modified(ref) == row.modified, try text(name, ref, maximum: 4096) == row.title else { throw AppleDirectFault("revision_changed") }
        let plaintext = try text(0x74657874, ref, maximum: 32*1024*1024)
        let html = try text(0x626f6479, ref, maximum: 32*1024*1024)
        let attachments = try count(0x61747473, ref)
        guard try modified(ref) == row.modified, try text(name, ref, maximum: 4096) == row.title else { throw AppleDirectFault("revision_changed") }
        _ = try noteRef(row.id, scope); try verify(scope)
        let editable = NotesDirectContract.editableBody(html: html, title: row.title, plaintext: plaintext, attachments: attachments)
        let raw=Data(plaintext.utf8)
        guard offset>=0,offset<=raw.count,(4...65536).contains(maxBytes),String(data:raw.dropFirst(offset),encoding:.utf8) != nil else{throw AppleDirectFault("invalid_arguments")}
        var end=min(raw.count,offset+maxBytes)
        while String(data:raw.subdata(in:offset..<end),encoding:.utf8)==nil && end>offset {end-=1}
        let page=String(data:raw.subdata(in:offset..<end),encoding:.utf8)!
        var result = NotesDirectRead(row: row, plaintext: page, bodyDigest: NotesDirectContract.digest(Data(html.utf8)),
            editableText: offset==0 && end==raw.count ? editable:nil, editRestriction: offset==0 && end==raw.count ? (editable == nil ? (attachments > 0 ? "attachments_read_only" : "rich_text_read_only") : nil):"paged_read")
        result.offset=offset;result.next_offset=end<raw.count ? end:nil;result.total_bytes=raw.count
        return result
    }
    func verifyEdit(_ proposal: NotesDirectEditProposal) throws {
        try proposal.validate()
        let current = try read(proposal.scope, row: proposal.row)
        guard current.editableText != nil else { throw AppleDirectFault(current.editRestriction ?? "rich_text_read_only") }
        guard current.bodyDigest == proposal.sourceBodyDigest else { throw AppleDirectFault("revision_changed") }
    }
    func update(_ proposal: NotesDirectEditProposal, beforeEffect: () throws -> Void) throws -> String {
        try verifyEdit(proposal)
        let ref = try noteRef(proposal.row.id, proposal.scope)
        try beforeEffect(); try check(); try proposal.validate()
        // Last provider revision/body/attachment witness after the durable claim.
        try verifyEdit(proposal); try check()
        _ = try send(0x73657464, [0x2d2d2d2d: AppleDirectDescriptor.property(0x626f6479, of: ref),
                                0x64617461: .init(string: proposal.html)])
        let revision = try modified(ref)
        let row = NotesDirectRow(id: proposal.row.id, title: proposal.title, modified: revision)
        let result = try read(proposal.scope, row: row)
        guard result.editableText == proposal.plaintext.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n") else {
            throw AppleDirectFault("update_unconfirmed")
        }
        return row.id
    }
    func verifyDelete(_ proposal: NotesDirectDeleteProposal) throws {
        try proposal.validate()
        let current = try read(proposal.scope, row: proposal.row)
        // Exact deletion does not reconstruct content in the plain-text editor.
        // noteRef still rejects shared/locked targets; revision/body and the
        // selected folder bind the precise object being removed.
        guard current.bodyDigest == proposal.sourceBodyDigest else { throw AppleDirectFault("revision_changed") }
    }
    func delete(_ proposal: NotesDirectDeleteProposal, beforeEffect: () throws -> Void) throws -> String {
        try verifyDelete(proposal)
        try beforeEffect(); try check(); try proposal.validate()
        // The final revision/body/folder witnesses follow the durable claim.
        try verifyDelete(proposal)
        let ref = try noteRef(proposal.row.id, proposal.scope)
        try check()
        _ = try send(0x64656c6f, [0x2d2d2d2d: ref]) // CocoaStandard.sdef: core/delo.
        try check(); try proposal.validate()
        let remaining = try send(0x646f6578, [0x2d2d2d2d: ref]) // core/doex, exact object only.
        guard remaining.descriptorType == typeBoolean, !remaining.booleanValue else { throw AppleDirectFault("delete_unconfirmed") }
        try verify(proposal.scope)
        return proposal.row.id // Local deletion/absence only; cloud sync is not checked.
    }
    func create(_ proposal: NotesDirectProposal, beforeEffect: () throws -> Void) throws -> String {
        try proposal.validate()
        let folder = try folderRef(proposal.scope.folder)
        let properties = NSAppleEventDescriptor.record()
        properties.setDescriptor(.init(string: proposal.title), forKeyword: name)
        properties.setDescriptor(.init(string: proposal.html), forKeyword: 0x626f6479)
        try check(); try proposal.validate(); try beforeEffect(); try check()
        // Exactly one effect call. Any failure after beforeEffect is consumed.
        let created = try send(0x6372656c, [0x6b6f636c: .init(typeCode: note), 0x696e7368: folder, 0x70726474: properties])
        guard created.descriptorType == typeObjectSpecifier else { throw AppleDirectFault("invalid_response") }
        let noteID = try text(id, created)
        let ref = try noteRef(noteID, proposal.scope)
        let title = try text(name, ref, maximum: 4096), revision = try modified(ref)
        guard title == proposal.title else { throw AppleDirectFault("create_unconfirmed") }
        let read = try read(proposal.scope, row: .init(id: noteID, title: title, modified: revision))
        func normalized(_ value: String) -> String { value.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n") }
        let body = normalized(proposal.plaintext)
        let allowed = [proposal.title + "\n" + body, proposal.title + "\n\n" + body].flatMap { [$0, $0 + "\n"] }
        guard allowed.contains(normalized(read.plaintext)) else { throw AppleDirectFault("create_unconfirmed") }
        return noteID
    }
}

struct NotesDirectCreateFault: Error, Sendable { let code: String; let consumed: Bool; var businessLogAvailable:Bool? = nil }

enum NotesDirectCreate {
    static func perform(proposal: NotesDirectProposal, expectedDigest: String,
                        validate: () throws -> Void, claim: () throws -> Void,
                        effect: (@escaping () throws -> Void) throws -> String,
                        confirmed: () throws -> Void) throws -> String {
        var consumed = false
        do {
            try proposal.validate()
            guard proposal.digest == expectedDigest else { throw AppleDirectFault("proposal_changed") }
            try validate()
            // A claim error may itself be a partial durable write. Never replay.
            consumed = true; try claim()
            let value = try effect { try proposal.validate() }
            try confirmed()
            return value
        } catch { throw NotesDirectCreateFault(code: (error as? AppleDirectFault)?.code ?? "create_unconfirmed", consumed: consumed) }
    }
}

// This is the sole production create/update/delete transaction for UI and owner callers.
final class NotesDirectHandler {
    private let home: URL
    private let backend: NotesDirectBackend
    private let selectedFolder: NotesDirectFolder?
    private(set) var businessLogAvailable = true
    init(home: URL, backend: NotesDirectBackend, selectedFolder: NotesDirectFolder? = nil) {
        self.home = home; self.backend = backend; self.selectedFolder = selectedFolder
    }
    private func requireSelection(_ scope: NotesDirectScope) throws {
        guard let selectedFolder else { throw AppleDirectFault("target_required") }
        guard scope.folder == selectedFolder else { throw AppleDirectFault("target_changed") }
    }
    func handle(_ request: NotesDirectRequest) throws -> NotesDirectReply {
        let callID = UUID()
        record(callID, request: request, response: Optional<NotesDirectResult>.none, fault: nil)
        do {
            let result: NotesDirectResult
            switch request {
            case .folders: result = .folders(try backend.folders())
            case let .list(scope):
                try requireSelection(scope)
                result = .search(try backend.search(scope, query: ""))
            case let .search(scope, query):
                try requireSelection(scope)
                try NotesDirectContract.text(query, maximum: 1024)
                result = .search(try backend.search(scope, query: query))
            case let .page(scope,query,offset,limit):
                try requireSelection(scope)
                result = .search(try backend.search(scope,query:query,offset:offset,limit:limit))
            case let .readPage(scope, row, offset, maxBytes):
                try requireSelection(scope)
                result = .read(try backend.read(scope, row: row, offset: offset, maxBytes: maxBytes))
            case let .read(scope, row):
                try requireSelection(scope)
                result = .read(try backend.read(scope, row: row))
            case let .create(proposal, expected):
                try requireSelection(proposal.scope)
                let journal = try AppleDirectJournal(home: home)
                let id = try NotesDirectCreate.perform(proposal: proposal, expectedDigest: expected,
                    validate: { try self.backend.verify(proposal.scope) },
                    claim: { try journal.claim(id: proposal.id, digest: proposal.digest) },
                    effect: { try self.backend.create(proposal, beforeEffect: $0) },
                    confirmed: { try journal.confirmed(id: proposal.id, digest: proposal.digest) })
                result = .mutation(itemID: id, outcome: "verified_local")
            case let .update(proposal, expected):
                try requireSelection(proposal.scope)
                try proposal.validate()
                guard proposal.digest == expected else { throw AppleDirectFault("proposal_changed") }
                try backend.verifyEdit(proposal)
                let journal = try AppleDirectJournal(home: home)
                var consumed = false
                do {
                    consumed = true; try journal.claim(id: proposal.id, digest: expected)
                    let id = try backend.update(proposal, beforeEffect: { try proposal.validate() })
                    try journal.confirmed(id: proposal.id, digest: expected)
                    result = .mutation(itemID: id, outcome: "verified_local")
                } catch { throw NotesDirectCreateFault(code: (error as? AppleDirectFault)?.code ?? "update_unconfirmed", consumed: consumed) }
            case let .delete(proposal, expected):
                try requireSelection(proposal.scope)
                try proposal.validate()
                guard proposal.digest == expected else { throw AppleDirectFault("proposal_changed") }
                try backend.verifyDelete(proposal)
                let journal = try AppleDirectJournal(home: home)
                var consumed = false
                do {
                    // A partial durable claim is uncertain and never replayed.
                    consumed = true; try journal.claim(id: proposal.id, digest: expected)
                    let id = try backend.delete(proposal, beforeEffect: { try proposal.validate() })
                    try journal.confirmed(id: proposal.id, digest: expected)
                    result = .mutation(itemID: id, outcome: "deleted_local")
                } catch { throw NotesDirectCreateFault(code: (error as? AppleDirectFault)?.code ?? "delete_unconfirmed", consumed: consumed) }
            }
            record(callID, request: request, response: result, fault: nil)
            return .init(result: result, businessLogAvailable: businessLogAvailable)
        } catch {
            let code = (error as? AppleDirectFault)?.code ?? (error as? NotesDirectCreateFault)?.code ?? "operation_unconfirmed"
            record(callID, request: request, response: Optional<NotesDirectResult>.none, fault: code)
            if var fault=error as? AppleDirectFault {fault.businessLogAvailable=businessLogAvailable;throw fault}
            if var fault=error as? NotesDirectCreateFault {fault.businessLogAvailable=businessLogAvailable;throw fault}
            if !businessLogAvailable {var fault=AppleDirectFault("operation_unconfirmed");fault.businessLogAvailable=false;throw fault}
            throw error
        }
    }
    private func record(_ id: UUID, request: NotesDirectRequest, response: NotesDirectResult?, fault: String?) {
        if !AppleDirectBusinessLog.record(home: home, domain: "notes", callID: id, request: request, response: response, fault: fault) { businessLogAvailable = false }
    }
}
