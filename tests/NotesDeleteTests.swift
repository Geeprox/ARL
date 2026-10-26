import Foundation
import ApplicationServices
import Darwin

@MainActor @main enum NotesDeleteTests {
    enum Failure: Error { case assertion(String) }
    static var checks = 0
    static func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try value() else { throw Failure.assertion(message) }; checks += 1
    }
    static func rejects(_ code: String, consumed: Bool? = nil, _ body: () throws -> Void) throws {
        do { try body() } catch let fault as NotesDirectCreateFault {
            try expect(fault.code == code, "fault code " + code + ", got " + fault.code)
            if let consumed { try expect(fault.consumed == consumed, "durable consumption classification") }
            return
        } catch let fault as AppleDirectFault {
            try expect(fault.code == code, "fault code " + code + ", got " + fault.code)
            if let consumed { try expect(!consumed, "precondition remains unconsumed") }
            return
        }
        throw Failure.assertion("expected rejection: " + code)
    }
    @MainActor final class Fixture {
        let folder = NotesDirectFolder(accountID: "x-coredata://ABCD/ICAccount/p1", accountName: "Synthetic account",
            id: "x-coredata://ABCD/ICFolder/p2", name: "Synthetic folder")
        let noteID = "x-coredata://ABCD/ICNote/p3"
        var title = "Synthetic", plaintext = "Synthetic\nBody\n", html = "<div><b>Synthetic</b></div><div>Body</div>"
        var modified = Date(timeIntervalSince1970: 1_700_000_000)
        var attachments = 0, calls = 0, deleteAttempts = 0, deletes = 0, existsCalls = 0
        var exists = true, locked = false, shared = false, moved = false, cancelled = false
        var throwAfterDelete = false, keepAfterDelete = false, invalidExistsReply = false
        lazy var backend = NotesDirectBackend(send: { event, params in try self.send(event, params) },
            check: { if self.cancelled { throw AppleDirectFault("cancelled") } })
        func scope() -> NotesDirectScope { .init(folder: folder, expires: Date().addingTimeInterval(500)) }
        func row() -> NotesDirectRow { .init(id: noteID, title: title, modified: modified) }
        func proposal(id: UUID = UUID()) -> NotesDirectDeleteProposal {
            .init(id: id, scope: scope(), row: row(), sourceBodyDigest: NotesDirectContract.digest(Data(html.utf8)),
                expires: Date().addingTimeInterval(100))
        }
        func kind(_ object: NSAppleEventDescriptor) -> UInt32 {
            let want = object.forKeyword(0x77616e74)?.typeCodeValue ?? 0
            if want == 0x70726f70, object.forKeyword(0x73656c64)?.typeCodeValue == 0x636e7472,
               let parent = object.forKeyword(0x66726f6d) { return kind(parent) == 0x6e6f7465 ? 0x63666f6c : 0x61636374 }
            return want
        }
        func exactTarget(_ params: [UInt32: NSAppleEventDescriptor]) throws {
            try expect(Set(params.keys) == [0x2d2d2d2d], "only exact direct object, no selectors or bulk arguments")
            let ref = params[0x2d2d2d2d]!
            try expect(ref.forKeyword(0x77616e74)?.typeCodeValue == 0x6e6f7465
                && ref.forKeyword(0x73656c64)?.stringValue == noteID, "exact stable note ID")
            try expect(ref.forKeyword(0x66726f6d)?.forKeyword(0x73656c64)?.stringValue == folder.id, "delete and exists remain in selected folder")
        }
        func send(_ event: UInt32, _ params: [UInt32: NSAppleEventDescriptor]) throws -> NSAppleEventDescriptor {
            calls += 1
            if event == 0x64656c6f {
                try exactTarget(params); deleteAttempts += 1; deletes += 1
                if !keepAfterDelete { exists = false }
                if throwAfterDelete { throw AppleDirectFault("automation_unconfirmed") }
                return .null()
            }
            if event == 0x646f6578 {
                try exactTarget(params); existsCalls += 1
                return invalidExistsReply ? .null() : .init(boolean: exists)
            }
            if event == 0x636e7465 {
                try expect(params[0x6b6f636c]?.typeCodeValue == 0x61747473, "never enumerate notes, folders or accounts during delete")
                return .init(int32: Int32(attachments))
            }
            guard event == 0x67657464, let property = params[0x2d2d2d2d],
                  let ref = property.forKeyword(0x66726f6d),
                  let code = property.forKeyword(0x73656c64)?.typeCodeValue else { throw Failure.assertion("nonpublic or forbidden event") }
            let type = kind(ref)
            if type == 0x6e6f7465 && !exists { throw AppleDirectFault("target_not_found", nativeStatus: -1728) }
            switch code {
            case 0x49442020:
                if type == 0x61636374 { return .init(string: folder.accountID) }
                if type == 0x63666f6c { return .init(string: moved ? "x-coredata://ABCD/ICFolder/p99" : folder.id) }
                return .init(string: noteID)
            case 0x706e616d: return .init(string: type == 0x61636374 ? folder.accountName : type == 0x63666f6c ? folder.name : title)
            case 0x73687264: return .init(boolean: type == 0x6e6f7465 && shared)
            case 0x70777072: return .init(boolean: locked)
            case 0x61736d6f: return .init(date: modified)
            case 0x74657874: return .init(string: plaintext)
            case 0x626f6479: return .init(string: html)
            default: throw Failure.assertion("unexpected property")
            }
        }
    }
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { throw Failure.assertion("owned fixture root required") }
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        func home(_ name: String) throws -> URL {
            let value = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: value, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            return value
        }
        let good = Fixture(), goodHome = try home("good"), p = good.proposal()
        let handler = NotesDirectHandler(home: goodHome, backend: good.backend, selectedFolder: good.folder)
        try p.validate()
        let wire = try JSONEncoder().encode(NotesDirectRequest.delete(proposal: p, expectedDigest: p.digest))
        let request = try JSONDecoder().decode(NotesDirectRequest.self, from: wire)
        let result = try handler.handle(request)
        guard case let .mutation(itemID, outcome) = result.result else { throw Failure.assertion("delete receipt") }
        try expect(itemID == p.row.id && outcome == "deleted_local" && good.deletes == 1 && !good.exists, "single locally verified deletion")
        try expect(good.existsCalls == 1 && result.businessLogAvailable, "exact existence readback and existing audit log")
        let marker = goodHome.appendingPathComponent("apple-direct-once-v1/notes_" + p.id.uuidString.lowercased() + ".verified")
        try expect(FileManager.default.fileExists(atPath: marker.path), "successful delete confirms original consumed operation")
        good.exists = true
        try rejects("operation_consumed", consumed: true) { _ = try handler.handle(request) }
        try expect(good.deletes == 1, "same UUID never replays even if original ID becomes visible again")

        let unknown = Fixture(), unknownHome = try home("unknown"), u = unknown.proposal()
        unknown.throwAfterDelete = true
        let uh = NotesDirectHandler(home: unknownHome, backend: unknown.backend, selectedFolder: unknown.folder)
        try rejects("automation_unconfirmed", consumed: true) { _ = try uh.handle(.delete(proposal: u, expectedDigest: u.digest)) }
        try expect(unknown.deletes == 1 && !unknown.exists, "post-effect failure stays uncertain")
        unknown.exists = true; unknown.throwAfterDelete = false
        try rejects("operation_consumed", consumed: true) { _ = try uh.handle(.delete(proposal: u, expectedDigest: u.digest)) }
        try expect(unknown.deletes == 1, "uncertain delete never repeats")
        try expect(!FileManager.default.fileExists(atPath: unknownHome.appendingPathComponent("apple-direct-once-v1/notes_" + u.id.uuidString.lowercased() + ".verified").path), "uncertain result has no confirmed marker")

        for invalidReply in [false, true] {
            let f = Fixture(), q = f.proposal(), h = try home(invalidReply ? "bad-exists" : "still-present")
            f.keepAfterDelete = true; f.invalidExistsReply = invalidReply
            let hh = NotesDirectHandler(home: h, backend: f.backend, selectedFolder: f.folder)
            try rejects("delete_unconfirmed", consumed: true) { _ = try hh.handle(.delete(proposal: q, expectedDigest: q.digest)) }
            try expect(f.deletes == 1, "readback uncertainty does not retry effect")
        }
        for (name, change, code) in [
            ("revision", { (f: Fixture) in f.modified = f.modified.addingTimeInterval(1) }, "revision_changed"),
            ("locked", { (f: Fixture) in f.locked = true }, "note_moved_locked_or_shared"),
            ("shared", { (f: Fixture) in f.shared = true }, "note_moved_locked_or_shared"),
            ("moved", { (f: Fixture) in f.moved = true }, "target_changed"),
            ("cancelled", { (f: Fixture) in f.cancelled = true }, "cancelled")
        ] {
            let f = Fixture(), q = f.proposal(), h = try home(name)
            change(f)
            let hh = NotesDirectHandler(home: h, backend: f.backend, selectedFolder: f.folder)
            try rejects(code, consumed: false) { _ = try hh.handle(.delete(proposal: q, expectedDigest: q.digest)) }
            try expect(f.deletes == 0 && !FileManager.default.fileExists(atPath: h.appendingPathComponent("apple-direct-once-v1").path), "precondition fails before durable consumption and effect")
        }
        for rich in [false,true] {
            let f=Fixture(),h=try home(rich ? "rich-delete":"attachment-delete")
            if rich {f.html="<div><b>Rich</b></div>"} else {f.attachments=1}
            let q=f.proposal()
            _ = try NotesDirectHandler(home:h,backend:f.backend,selectedFolder:f.folder).handle(.delete(proposal:q,expectedDigest:q.digest))
            try expect(f.deletes==1,"confirmed exact-target deletion does not require editable plain text")
        }
        let long=Fixture();long.plaintext=String(repeating:"中😀",count:18000)
        var offset=0,reconstructed=""
        repeat {
            let page=try long.backend.read(long.scope(),row:long.row(),offset:offset,maxBytes:8192)
            reconstructed+=page.plaintext
            try expect(page.editableText==nil,"partial long body is never an editable prefix")
            guard let next=page.next_offset else{break}
            try expect(next>offset,"UTF8 body continuation advances");offset=next
        } while true
        try expect(reconstructed==long.plaintext,"long UTF8 note is losslessly readable")
        _ = try AppleDirectDescriptor.indexed(0x6e6f7465,index:201,parent:.null())
        let changedBody = Fixture(), q = changedBody.proposal(), bodyHome = try home("body")
        changedBody.html = "<div><b>Synthetic</b></div><div>Changed</div>"; changedBody.plaintext = "Synthetic\nChanged\n"
        try rejects("revision_changed", consumed: false) {
            _ = try NotesDirectHandler(home: bodyHome, backend: changedBody.backend, selectedFolder: changedBody.folder).handle(.delete(proposal: q, expectedDigest: q.digest))
        }
        try expect(changedBody.deletes == 0, "body digest catches unchanged modification timestamp")

        let late = Fixture(), lateProposal = late.proposal()
        try rejects("revision_changed") {
            _ = try late.backend.delete(lateProposal, beforeEffect: { late.modified = late.modified.addingTimeInterval(1) })
        }
        try expect(late.deletes == 0, "final witness after claim callback prevents raced revision")

        let noScope = Fixture(), ns = noScope.proposal(), nsHome = try home("no-selection")
        try rejects("target_required") {
            _ = try NotesDirectHandler(home: nsHome, backend: noScope.backend).handle(.delete(proposal: ns, expectedDigest: ns.digest))
        }
        try expect(noScope.calls == 0, "no selected scope performs zero native reads or effects")
        try rejects("proposal_changed") {
            _ = try NotesDirectHandler(home: nsHome, backend: noScope.backend, selectedFolder: noScope.folder).handle(.delete(proposal: ns, expectedDigest: String(repeating: "f", count: 64)))
        }
        try expect(noScope.calls == 0, "wrong approval digest performs zero native calls")
        let expired = NotesDirectDeleteProposal(id: ns.id, scope: ns.scope, row: ns.row, sourceBodyDigest: ns.sourceBodyDigest, expires: Date().addingTimeInterval(-1))
        try rejects("proposal_expired") { try expired.validate() }
        let edited = NotesDirectEditProposal(id: ns.id, scope: ns.scope, row: ns.row, sourceBodyDigest: ns.sourceBodyDigest, title: ns.row.title, plaintext: "Body", expires: ns.expires)
        try expect(edited.digest != ns.digest, "edit approval cannot authorize delete")
        print("PASS \(checks) Notes deletion checks; real_Notes=0 permission_requests=0 user_data_effects=0")
    }
}
