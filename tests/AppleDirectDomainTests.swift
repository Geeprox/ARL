import Foundation
import ApplicationServices
import Darwin

@MainActor @main enum AppleDirectDomainTests {
    enum Failure: Error { case assertion(String) }
    static var checks = 0
    static func expect(_ condition: @autoclosure () throws -> Bool, _ name: String) throws {
        guard try condition() else { throw Failure.assertion(name) }; checks += 1
    }
    static func reject(_ name: String, _ body: () throws -> Void) throws {
        do { try body() } catch { checks += 1; return }; throw Failure.assertion(name)
    }
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        #if ARL_NOTES_REVIEW_FIXES_TEST
        try notesReviewFixes(root: root)
        return
        #endif
        #if ARL_REVIEW_DELTA_TEST
        try reviewDelta(root: root)
        return
        #endif
        let folder = NotesDirectFolder(accountID: "x-coredata://ABCD/ICAccount/p1", accountName: "Fixture", id: "x-coredata://ABCD/ICFolder/p2", name: "Chosen")
        let scope = NotesDirectScope(folder: folder, expires: Date().addingTimeInterval(500))
        let noteID = "x-coredata://ABCD/ICNote/p3"
        var title = "Original", text = "Original\nUntouched & safe\n", html = "<div><b>Original</b></div><div>Untouched &amp; safe</div>"
        var revision = Date(timeIntervalSince1970: 1700000000), attachments = 0, effects = 0, failEffect = false
        var listedKinds: [UInt32] = []
        func kind(_ object: NSAppleEventDescriptor) -> UInt32 {
            let want = object.forKeyword(0x77616e74)?.typeCodeValue ?? 0
            if want == 0x70726f70, let selector = object.forKeyword(0x73656c64)?.typeCodeValue, let parent = object.forKeyword(0x66726f6d) {
                if selector == 0x636e7472 { return kind(parent) == 0x6e6f7465 ? 0x63666f6c : 0x61636374 }
            }
            return want
        }
        let backend = NotesDirectBackend(send: { event, params in
            if event == 0x636e7465 {
                let wanted = params[0x6b6f636c]!.typeCodeValue
                listedKinds.append(wanted)
                return .init(int32: wanted == 0x61747473 ? Int32(attachments) : 1)
            }
            if event == 0x73657464 {
                try expect(Set(params.keys) == [0x2d2d2d2d, 0x64617461], "one fixed body setter")
                effects += 1
                if failEffect { throw AppleDirectFault("automation_unconfirmed") }
                html = params[0x64617461]!.stringValue!
                title = "Edited"; text = "Edited\nChanged text\n"; revision = revision.addingTimeInterval(1)
                return .null()
            }
            guard event == 0x67657464, let property = params[0x2d2d2d2d], let ref = property.forKeyword(0x66726f6d), let code = property.forKeyword(0x73656c64)?.typeCodeValue else { throw Failure.assertion("forbidden Notes event") }
            switch code {
            case 0x49442020: return .init(string: kind(ref) == 0x61636374 ? folder.accountID : kind(ref) == 0x63666f6c ? folder.id : noteID)
            case 0x706e616d: return .init(string: kind(ref) == 0x61636374 ? folder.accountName : kind(ref) == 0x63666f6c ? folder.name : title)
            case 0x73687264, 0x70777072: return .init(boolean: false)
            case 0x61736d6f: return .init(date: revision)
            case 0x74657874: return .init(string: text)
            case 0x626f6479: return .init(string: html)
            default: throw Failure.assertion("forbidden Notes property")
            }
        }, check: {})
        let handler = NotesDirectHandler(home: root, backend: backend, selectedFolder: folder)
        let unselected = NotesDirectHandler(home: root, backend: backend)
        do { _ = try unselected.handle(.list(scope: scope)); throw Failure.assertion("target selection required") }
        catch let error as AppleDirectFault { try expect(error.code == "target_required", "no chosen folder is selection, not authorization") }
        let otherFolder = NotesDirectFolder(accountID: folder.accountID, accountName: folder.accountName, id: "x-coredata://ABCD/ICFolder/p99", name: "Unselected")
        try reject("caller cannot supply another folder") { _ = try handler.handle(.list(scope: .init(folder: otherFolder, expires: scope.expires))) }
        let listing = try handler.handle(.list(scope: scope))
        guard case let .search(page) = listing.result else { throw Failure.assertion("list reply") }
        try expect(page.notes.count == 1 && page.notes[0].id == noteID, "list stays inside chosen folder")
        try expect(!listedKinds.contains(0x61636374), "no global account enumeration for list")
        let row = page.notes[0]
        guard case let .read(snapshot) = try handler.handle(.read(scope: scope, row: row)).result else { throw Failure.assertion("read reply") }
        try expect(snapshot.editableText == "Untouched & safe", "plain text lossless edit snapshot")
        try expect(NotesDirectContract.editableBody(html: "<div>Title</div><div></div>", title: "Title", plaintext: "Title\n\n", attachments: 0) == "", "empty body remains safely editable")
        let edit = NotesDirectEditProposal(id: UUID(), scope: scope, row: row, sourceBodyDigest: snapshot.bodyDigest!, title: "Edited", plaintext: "Changed text", expires: Date().addingTimeInterval(100))
        try expect(edit.digest == edit.digest, "digest stable across independent encodes")
        let wire = try JSONEncoder().encode(NotesDirectRequest.update(proposal: edit, expectedDigest: edit.digest))
        let decoded = try JSONDecoder().decode(NotesDirectRequest.self, from: wire)
        try expect(wire.count > 0, "typed wire encodes")
        _ = try handler.handle(decoded)
        try expect(effects == 1 && html == edit.html, "one update exact approved body")
        try reject("stale row cannot overwrite new revision") { _ = try handler.handle(decoded) }
        try expect(effects == 1, "stale update has no additional effect")
        var currentRow = NotesDirectRow(id: noteID, title: title, modified: revision)
        html = "<div>Edited</div><div><b>Keep bold</b></div>"; text = "Edited\nKeep bold\n"
        let rich = try backend.read(scope, row: currentRow)
        try expect(rich.editableText == nil && rich.editRestriction == "rich_text_read_only", "rich formatting protected")
        let forged = NotesDirectEditProposal(id: UUID(), scope: scope, row: currentRow, sourceBodyDigest: rich.bodyDigest!, title: "Edited", plaintext: "Changed text", expires: edit.expires)
        try reject("forged writable rich snapshot refused") { _ = try handler.handle(.update(proposal: forged, expectedDigest: forged.digest)) }
        html = edit.html; text = "Edited\nChanged text\n"; attachments = 1
        try expect(try backend.read(scope, row: currentRow).editRestriction == "attachments_read_only", "attachments protected")
        attachments = 0
        let ready = try backend.read(scope, row: currentRow)
        let unknown = NotesDirectEditProposal(id: UUID(), scope: scope, row: currentRow, sourceBodyDigest: ready.bodyDigest!, title: "Edited", plaintext: "Changed text", expires: edit.expires)
        failEffect = true
        try reject("unknown edit recorded") { _ = try handler.handle(.update(proposal: unknown, expectedDigest: unknown.digest)) }
        failEffect = false
        try reject("unknown operation cannot replay") { _ = try handler.handle(.update(proposal: unknown, expectedDigest: unknown.digest)) }
        try expect(effects == 2, "unknown effect attempted once")
        let independent = NotesDirectEditProposal(id: UUID(), scope: scope, row: currentRow, sourceBodyDigest: ready.bodyDigest!, title: "Edited", plaintext: "Changed text", expires: edit.expires)
        _ = try handler.handle(.update(proposal: independent, expectedDigest: independent.digest))
        try expect(effects == 3, "unrelated new operation remains available")
        currentRow = NotesDirectRow(id: noteID, title: title, modified: revision)
        let log = root.appendingPathComponent("apple-direct-business-v1.noindex")
        let logs = try FileManager.default.contentsOfDirectory(at: log, includingPropertiesForKeys: nil)
        let logged = try logs.map { try String(contentsOf: $0, encoding: .utf8) }.joined()
        try expect(logged.contains("Untouched & safe") && logged.contains("Changed text") && logged.contains("revision_changed"), "full request response and failure audit")
        let blockedRoot = root.appendingPathComponent("audit-failure")
        try FileManager.default.createDirectory(at: blockedRoot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try Data().write(to: blockedRoot.appendingPathComponent("apple-direct-business-v1.noindex"))
        let degraded = NotesDirectHandler(home: blockedRoot, backend: backend, selectedFolder: folder)
        try expect(try degraded.handle(.read(scope: scope, row: currentRow)).businessLogAvailable == false, "audit failure does not block work")
        let latest = try backend.read(scope, row: currentRow)
        let withoutAudit = NotesDirectEditProposal(id: UUID(), scope: scope, row: currentRow, sourceBodyDigest: latest.bodyDigest!, title: "Edited", plaintext: "Changed text", expires: edit.expires)
        try expect(try degraded.handle(.update(proposal: withoutAudit, expectedDigest: withoutAudit.digest)).businessLogAvailable == false && effects == 4, "audit failure does not block a new mutation with intact effect journal")
        let account = MessagesDirectAccount(id: "fixture-account", label: "Fixture")
        var messageCalls = 0
        let messages = MessagesDirectBackend(send: { _,_,_ in messageCalls += 1; throw Failure.assertion("read must not dispatch") }, check: {})
        let messagesHandler = MessagesDirectHandler(home: root, backend: messages, selectedAccount: account)
        let noAccount = MessagesDirectHandler(home: root, backend: messages)
        do { _ = try noAccount.handle(.chats(account: account, query: "")); throw Failure.assertion("account selection required") }
        catch let error as AppleDirectFault { try expect(error.code == "target_required" && messageCalls == 0, "no chosen account does not request authorization") }
        let unavailable = try messagesHandler.handle(.read(account: account, chatID: "fixture-chat"))
        guard case let .unsupported(code, _) = unavailable.result else { throw Failure.assertion("truthful unsupported result") }
        try expect(code == "unsupported_public_api" && messageCalls == 0, "receive unavailable without invented body or database")
        try MessagesDirectContract.address("+8613800000000")
        try MessagesDirectContract.address("person@example.test")
        try reject("no implicit country code") { try MessagesDirectContract.address("13800000000") }
        try reject("no display name recipients") { try MessagesDirectContract.address("Alice") }
        try reject("no multiple recipients") { try MessagesDirectContract.address("a@example.test,b@example.test") }
        let address = "+8613800000000", participantID = "fixture-participant"
        var sends = 0, changedChat = false, accountCounts = 0
        func accountRecord() -> NSAppleEventDescriptor {
            let record = NSAppleEventDescriptor.record()
            record.setDescriptor(.init(string: account.id), forKeyword: 0x49442020)
            record.setDescriptor(.init(string: account.label), forKeyword: 0x6d73646e)
            record.setDescriptor(.init(enumCode: 0x73696d73), forKeyword: 0x73747970)
            record.setDescriptor(.init(boolean: true), forKeyword: 0x656e626c)
            record.setDescriptor(.init(enumCode: 0x636f6e6e), forKeyword: 0x73737461)
            return record
        }
        let nativeMessages = MessagesDirectBackend(send: { cls, event, params in
            if cls == 0x69636874 && event == 0x73656e64 {
                sends += 1
                try expect(params[0x2d2d2d2d]?.stringValue == "Exact message", "handler sends frozen exact body")
                try expect(params[0x544f2020]?.forKeyword(0x73656c64)?.stringValue == participantID, "handler sends actual unique participant")
                return .null()
            }
            guard cls == 0x636f7265 else { throw Failure.assertion("forbidden event class") }
            if event == 0x636e7465 {
                if params[0x6b6f636c]?.typeCodeValue == 0x696d6374 {
                    try expect(params[0x2d2d2d2d]?.forKeyword(0x73656c64)?.stringValue == account.id, "chats constrained to exact selected account")
                } else { accountCounts += 1 }
                return .init(int32: 1)
            }
            guard event == 0x67657464, let prop = params[0x2d2d2d2d], let object = prop.forKeyword(0x66726f6d), let code = prop.forKeyword(0x73656c64)?.typeCodeValue else { throw Failure.assertion("fixed metadata requests") }
            let wanted = object.forKeyword(0x77616e74)?.typeCodeValue
            if code == 0x70414c4c {
                if wanted == 0x69637376 { return accountRecord() }
                guard wanted == 0x696d6374 else { throw Failure.assertion("only account and chat metadata") }
                let chat = NSAppleEventDescriptor.record()
                let stable = object.forKeyword(0x666f726d)?.enumCodeValue == 0x49442020
                chat.setDescriptor(.init(string: "fixture-chat"), forKeyword: 0x49442020)
                chat.setDescriptor(.init(string: changedChat && stable ? "Changed" : "Fixture chat"), forKeyword: 0x706e616d)
                chat.setDescriptor(try AppleDirectDescriptor.object(0x69637376, id: account.id), forKeyword: 0x69637376)
                return chat
            }
            if code == 0x49442020 {
                if object.forKeyword(0x666f726d)?.enumCodeValue == 0x74657374 {
                    let found = NSAppleEventDescriptor.list(); found.insert(.init(string: participantID), at: 1); return found
                }
                return .init(string: wanted == 0x70726573 ? participantID : account.id)
            }
            if code == 0x686e646c { return .init(string: address) }
            throw Failure.assertion("no history or participant name reads")
        }, check: {})
        let domain = MessagesDirectHandler(home: root, backend: nativeMessages, selectedAccount: account)
        guard case let .accounts(accountPage) = try domain.handle(.accounts).result else { throw Failure.assertion("account reply") }
        try expect(accountPage.accounts == [account] && accountCounts == 2, "handler account production path")
        guard case let .chats(chatPage) = try domain.handle(.chats(account: account, query: "Fixture")).result else { throw Failure.assertion("chat reply") }
        try expect(chatPage.chats.count == 1 && chatPage.chats[0].account == account, "typed discovered chat and account")
        changedChat = true
        try reject("changed stable chat observation refused") { _ = try domain.handle(.chats(account: account, query: "")) }
        changedChat = false
        guard case let .prepared(sendProposal) = try domain.handle(.prepareSend(id: UUID(), account: account, address: address, plaintext: "Exact message")).result else { throw Failure.assertion("prepared reply") }
        try expect(sends == 0 && sendProposal.recipient.handle == address, "prepare freezes actual target without send")
        try reject("changed digest cannot send") { _ = try domain.handle(.send(proposal: sendProposal, expectedDigest: String(repeating: "0", count: 64))) }
        try expect(sends == 0, "digest mismatch zero sends")
        let encodedSend = try JSONEncoder().encode(MessagesDirectRequest.send(proposal: sendProposal, expectedDigest: sendProposal.digest))
        _ = try domain.handle(JSONDecoder().decode(MessagesDirectRequest.self, from: encodedSend))
        try reject("same frozen proposal cannot send twice") { _ = try domain.handle(.send(proposal: sendProposal, expectedDigest: sendProposal.digest)) }
        try expect(sends == 1, "UI owner handler shares once-only send journal")
        print("{\"status\":\"PASS\",\"checks\":\(checks),\"actual_notes_messages_calls\":false}")
    }
    #if ARL_REVIEW_DELTA_TEST
    static func reviewDelta(root: URL) throws {
        #if ARL_REVIEW_SHARED_JSON_TEST
        // Exercise the actual shared pre-decode boundary; do not replace it.
        for json in [#"{"row":{},"row":{}}"#, #"{"row":{"id":"a","\u0069d":"b"}}"#] {
            try reject("duplicate or escaped nested key is rejected before domain decode") {
                _ = try AppleProductCapability.arguments(tool: "mio_notes_read", data: Data(json.utf8))
            }
        }
        let valid = try AppleProductCapability.arguments(tool: "mio_notes_list", data: Data("{}".utf8))
        try expect(valid.isEmpty, "strict shared decoder preserves a valid request")
        print("{\"status\":\"PASS\",\"suite\":\"shared_duplicate_keys_only\",\"checks\":\(checks),\"actual_notes_messages_calls\":false}")
        return
        #endif
        var diagnostic = AppleDirectFault("synthetic_failure", nativeStatus: -1708)
        diagnostic.businessLogAvailable = false
        let staged = diagnostic.at(.messagesHandle)
        try expect(staged.businessLogAvailable == false && staged.nativeStatus == -1708 && staged.code == diagnostic.code,
                   "stage annotation preserves audit failure and native diagnosis")

        let degradedHome = root.appendingPathComponent("degraded")
        try FileManager.default.createDirectory(at: degradedHome, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try Data().write(to: degradedHome.appendingPathComponent("apple-direct-business-v1.noindex"))
        let folder = NotesDirectFolder(accountID: "x-coredata://ABCD/ICAccount/p1", accountName: "Fixture", id: "x-coredata://ABCD/ICFolder/p2", name: "Chosen")
        let scope = NotesDirectScope(folder: folder, expires: Date().addingTimeInterval(500))
        var notesEffects = 0
        let notes = NotesDirectBackend(send: { event, parameters in
            if event == 0x6372656c { notesEffects += 1; throw AppleDirectFault("automation_unconfirmed") }
            guard event == 0x67657464, let property = parameters[0x2d2d2d2d], let object = property.forKeyword(0x66726f6d),
                  let code = property.forKeyword(0x73656c64)?.typeCodeValue else { throw Failure.assertion("metadata or single create only") }
            let kind = object.forKeyword(0x77616e74)?.typeCodeValue
            let account = kind == 0x61636374 || kind == 0x70726f70
            switch code {
            case 0x49442020: return .init(string: account ? folder.accountID : folder.id)
            case 0x706e616d: return .init(string: account ? folder.accountName : folder.name)
            case 0x73687264: return .init(boolean: false)
            default: throw Failure.assertion("no body reads")
            }
        }, check: {})
        do {
            _ = try NotesDirectHandler(home: degradedHome, backend: notes).handle(.list(scope: scope))
            throw Failure.assertion("missing target accepted")
        } catch let fault as AppleDirectFault {
            try expect(fault.code == "target_required" && fault.businessLogAvailable == false && notesEffects == 0,
                       "generic Notes rejection preserves degraded audit without an effect")
        }
        let create = NotesDirectProposal(id: UUID(), scope: scope, title: "Synthetic", plaintext: "No real Notes use", expires: Date().addingTimeInterval(100))
        do {
            _ = try NotesDirectHandler(home: degradedHome, backend: notes, selectedFolder: folder).handle(.create(proposal: create, expectedDigest: create.digest))
            throw Failure.assertion("uncertain create reported saved")
        } catch let fault as NotesDirectCreateFault {
            try expect(fault.consumed && fault.code == "automation_unconfirmed" && fault.businessLogAvailable == false && notesEffects == 1,
                       "typed consumed Notes outcome retains audit failure")
        }

        let account = MessagesDirectAccount(id: "synthetic-account", label: "Synthetic")
        let address = "receiver@example.test", participantID = "synthetic-participant"
        var resolutions = 0, ambiguousAt: Int?, sends = 0, failSend = false, sentText = ""
        let messages = MessagesDirectBackend(send: { cls, event, parameters in
            if cls == 0x69636874 && event == 0x73656e64 {
                sends += 1; sentText = parameters[0x2d2d2d2d]?.stringValue ?? ""
                if failSend { throw AppleDirectFault("automation_unconfirmed") }
                return .null()
            }
            guard cls == 0x636f7265, event == 0x67657464, let property = parameters[0x2d2d2d2d],
                  let object = property.forKeyword(0x66726f6d), let code = property.forKeyword(0x73656c64)?.typeCodeValue else {
                throw Failure.assertion("no history, login, permission or other event")
            }
            if code == 0x70414c4c {
                let result = NSAppleEventDescriptor.record()
                result.setDescriptor(.init(string: account.id), forKeyword: 0x49442020)
                result.setDescriptor(.init(string: account.label), forKeyword: 0x6d73646e)
                result.setDescriptor(.init(enumCode: 0x73696d73), forKeyword: 0x73747970)
                result.setDescriptor(.init(boolean: true), forKeyword: 0x656e626c)
                result.setDescriptor(.init(enumCode: 0x636f6e6e), forKeyword: 0x73737461)
                return result
            }
            if code == 0x49442020 {
                if object.forKeyword(0x666f726d)?.enumCodeValue == 0x74657374 {
                    resolutions += 1
                    let result = NSAppleEventDescriptor.list(); result.insert(.init(string: participantID), at: 1)
                    if ambiguousAt == resolutions { result.insert(.init(string: "another-participant"), at: 2) }
                    return result
                }
                return .init(string: object.forKeyword(0x77616e74)?.typeCodeValue == 0x70726573 ? participantID : account.id)
            }
            if code == 0x686e646c { return .init(string: address) }
            throw Failure.assertion("no private message property")
        }, check: {})
        func proposal(_ text: String) -> MessagesDirectProposal {
            .init(id: UUID(), recipient: .init(account: account, id: participantID, handle: address, expires: Date().addingTimeInterval(250)),
                  plaintext: text, expires: Date().addingTimeInterval(100))
        }
        let preflight = proposal("Never sent")
        ambiguousAt = 1
        do {
            _ = try MessagesDirectHandler(home: degradedHome, backend: messages, selectedAccount: account).handle(.send(proposal: preflight, expectedDigest: preflight.digest))
            throw Failure.assertion("ambiguous preflight sent")
        } catch let fault as MessagesDirectSendFault {
            try expect(!fault.consumed && fault.code == "recipient_not_unique" && fault.businessLogAvailable == false && sends == 0,
                       "early ambiguity is typed, audit-degraded and unconsumed")
        }
        let late = proposal("Late ambiguity")
        resolutions = 0; ambiguousAt = 2
        do {
            _ = try MessagesDirectHandler(home: degradedHome, backend: messages, selectedAccount: account).handle(.send(proposal: late, expectedDigest: late.digest))
            throw Failure.assertion("final ambiguity sent")
        } catch let fault as MessagesDirectSendFault {
            try expect(fault.consumed && fault.code == "recipient_not_unique" && fault.businessLogAvailable == false && sends == 0 && resolutions == 2,
                       "post-claim final unique-recipient recheck prevents the send")
        }
        resolutions = 0; ambiguousAt = nil
        do {
            _ = try MessagesDirectHandler(home: degradedHome, backend: messages, selectedAccount: account).handle(.send(proposal: late, expectedDigest: late.digest))
            throw Failure.assertion("original late claim replayed")
        } catch let fault as MessagesDirectSendFault {
            try expect(fault.consumed && fault.code == "operation_consumed" && sends == 0, "original claim remains consumed after a final rejection")
        }
        let unknown = proposal("Unknown dispatch")
        failSend = true
        do {
            _ = try MessagesDirectHandler(home: degradedHome, backend: messages, selectedAccount: account).handle(.send(proposal: unknown, expectedDigest: unknown.digest))
            throw Failure.assertion("lost send reply became accepted")
        } catch let fault as MessagesDirectSendFault {
            try expect(fault.consumed && fault.code == "automation_unconfirmed" && fault.businessLogAvailable == false && sends == 1,
                       "unknown dispatch and audit failure keep the original typed outcome")
        }
        failSend = false
        let independent = proposal("Explicit independent new message")
        let accepted = try MessagesDirectHandler(home: degradedHome, backend: messages, selectedAccount: account).handle(.send(proposal: independent, expectedDigest: independent.digest))
        guard case .accepted = accepted.result else { throw Failure.assertion("new message unavailable") }
        try expect(!accepted.businessLogAvailable && sends == 2 && sentText == independent.plaintext,
                   "original unknown and audit failure do not globally lock a genuinely new message")
        do {
            _ = try MessagesDirectHandler(home: degradedHome, backend: messages, selectedAccount: account).handle(.send(proposal: unknown, expectedDigest: unknown.digest))
            throw Failure.assertion("original unknown retried")
        } catch let fault as MessagesDirectSendFault {
            try expect(fault.consumed && fault.code == "operation_consumed" && sends == 2, "unknown original UUID never replays")
        }
        print("{\"status\":\"PASS\",\"suite\":\"review_delta_only\",\"checks\":\(checks),\"actual_notes_messages_calls\":false}")
    }
    #endif

    #if ARL_NOTES_REVIEW_FIXES_TEST
    static func notesReviewFixes(root: URL) throws {
        let folder = NotesDirectFolder(accountID: "x-coredata://ABCD/ICAccount/p1", accountName: "Fixture", id: "x-coredata://ABCD/ICFolder/p2", name: "Chosen")
        let scope = NotesDirectScope(folder: folder, expires: Date().addingTimeInterval(500))
        let row = NotesDirectRow(id: "x-coredata://ABCD/ICNote/p3", title: "A", modified: Date(timeIntervalSince1970: 1700000000))
        let original = NotesDirectRead(row: row, plaintext: "A\nOld", bodyDigest: String(repeating: "a", count: 64), editableText: "Old")
        let source = original.editorSource(folder: folder)!
        func rejectSource(_ current: NotesDirectEditorSource?, _ label: String) throws {
            do {
                _ = try NotesDirectEditProposal.fromEditor(scope: scope, source: source, currentSource: current,
                    title: "Edited A", plaintext: "Edited old A text", expires: Date().addingTimeInterval(100))
                throw Failure.assertion(label)
            } catch let fault as AppleDirectFault { try expect(fault.code == "editor_source_changed", label) }
        }
        let different = NotesDirectEditorSource(folder: folder,
            row: .init(id: "x-coredata://ABCD/ICNote/p4", title: "B", modified: row.modified), bodyDigest: source.bodyDigest)
        try rejectSource(different, "queued A editor cannot save its values to newly read B")
        let sameRowNewBody = NotesDirectRead(row: row, plaintext: "A\nNew", bodyDigest: String(repeating: "b", count: 64), editableText: "New")
        try rejectSource(sameRowNewBody.editorSource(folder: folder), "same row and timestamp with new HTML digest cannot rebind old editor")
        let revised = NotesDirectEditorSource(folder: folder,
            row: .init(id: row.id, title: row.title, modified: row.modified.addingTimeInterval(1)), bodyDigest: source.bodyDigest)
        try rejectSource(revised, "new revision cannot replace clicked editor source")
        try rejectSource(nil, "cleared current read only rejects this old save")
        let approved = try NotesDirectEditProposal.fromEditor(scope: scope, source: source, currentSource: source,
            title: "Edited A", plaintext: "Edited old A text", expires: Date().addingTimeInterval(100))
        try expect(approved.row == row && approved.sourceBodyDigest == source.bodyDigest && approved.plaintext == "Edited old A text",
                   "matching editor creates an immutable proposal from clicked source, without a global lock")

        let directory = root.appendingPathComponent("apple-direct-business-v1.noindex")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let legacy = directory.appendingPathComponent("notes-legacy.jsonl"), legacyBytes = Data("retained legacy diagnostic\n".utf8)
        try legacyBytes.write(to: legacy)
        signal(SIGXFSZ, SIG_IGN)
        var prior = rlimit(); guard getrlimit(RLIMIT_FSIZE, &prior) == 0 else { throw Failure.assertion("get fixture file limit") }
        defer { _ = setrlimit(RLIMIT_FSIZE, &prior) }
        var bounded = prior; bounded.rlim_cur = 512
        guard setrlimit(RLIMIT_FSIZE, &bounded) == 0 else { throw Failure.assertion("set fixture file limit") }
        let first = AppleDirectBusinessLog.record(home: root, domain: "notes", callID: UUID(),
            request: ["input": String(repeating: "x", count: 4096)], response: Optional<[String: String]>.none, fault: nil)
        guard setrlimit(RLIMIT_FSIZE, &prior) == 0 else { throw Failure.assertion("restore fixture file limit") }
        try expect(!first, "actual partial write plus EFBIG reports audit failure")
        let incomplete = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("v2-notes-") && $0.pathExtension == "partial" }
        try expect(incomplete.count == 1 && incomplete[0].lastPathComponent.contains(".write-" + String(EFBIG)),
                   "failed segment remains separately diagnosed with native write error")
        let failedPrefix = try Data(contentsOf: incomplete[0])
        try expect(failedPrefix.count == 512, "actual failed prefix bytes are retained")
        let secondID = UUID()
        let second = AppleDirectBusinessLog.record(home: root, domain: "notes", callID: secondID,
            request: ["input": "second"], response: ["result": "ok"], fault: nil)
        let complete = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("v2-notes-") && $0.pathExtension == "jsonl" }
        try expect(second && complete.count == 1, "next call succeeds in its independent committed record")
        let bytes = try Data(contentsOf: complete[0]), lines = bytes.split(separator: 10)
        let value = try JSONSerialization.jsonObject(with: Data(lines[0])) as! [String: Any]
        try expect(lines.count == 1 && bytes.last == 10 && value["callID"] as? String == secondID.uuidString &&
                   (value["request"] as? [String: String])?["input"] == "second" &&
                   (value["response"] as? [String: String])?["result"] == "ok",
                   "successful JSONL contains the complete exact next request and response")
        try expect(try Data(contentsOf: incomplete[0]) == failedPrefix && Data(contentsOf: legacy) == legacyBytes,
                   "recovery preserves failed prefix and all older diagnostic bytes")
        print("{\"status\":\"PASS\",\"suite\":\"notes_review_N1_N2_only\",\"checks\":\(checks),\"parseable_next_records\":1,\"retained_failed_prefix_bytes\":512,\"actual_UI_race_executed\":false,\"actual_notes_messages_calls\":false}")
    }
    #endif

}
