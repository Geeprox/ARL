import Foundation
import ApplicationServices
import Darwin

@MainActor @main enum NotesDirectTests {
    enum Failure: Error { case assertion(String) }
    static var checks = 0
    static func expect(_ condition: Bool, _ name: String) throws {
        guard condition else { throw Failure.assertion(name) }; checks += 1
    }
    static func rejected(_ name: String, _ body: () throws -> Void) throws {
        do { try body() } catch { checks += 1; return }
        throw Failure.assertion(name)
    }
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { throw Failure.assertion("owned fixture root required") }
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        guard root.path == root.resolvingSymlinksInPath().path else { throw Failure.assertion("canonical root required") }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let folder = NotesDirectFolder(accountID: "x-coredata://ABCD/ICAccount/p1", accountName: "Synthetic account",
            id: "x-coredata://ABCD/ICFolder/p2", name: "Synthetic folder")
        let scope = NotesDirectScope(folder: folder, expires: Date().addingTimeInterval(500))
        let proposal = NotesDirectProposal(id: UUID(), scope: scope, title: "<Synthetic>", plaintext: "No live Notes access & no send.\nSecond line.", expires: Date().addingTimeInterval(100))
        try proposal.validate()
        try expect(proposal.html.contains("&lt;Synthetic&gt;") && proposal.html.contains("&amp;") && proposal.html.contains("<br>"), "HTML is escaped text")
        let altered = NotesDirectProposal(id: proposal.id, scope: scope, title: proposal.title,
            plaintext: proposal.plaintext + "changed", expires: proposal.expires)
        try expect(altered.digest != proposal.digest, "content belongs to digest")
        let moved = NotesDirectFolder(accountID: folder.accountID, accountName: folder.accountName,
            id: "x-coredata://ABCD/ICFolder/p3", name: folder.name)
        let other = NotesDirectProposal(id: proposal.id, scope: .init(folder: moved, expires: scope.expires),
            title: proposal.title, plaintext: proposal.plaintext, expires: proposal.expires)
        try expect(other.digest != proposal.digest, "target belongs to digest")
        try rejected("expired scope") { try NotesDirectScope(folder: folder, expires: Date().addingTimeInterval(-1)).validate() }
        try rejected("control characters") { try NotesDirectContract.text("a\0b", maximum: 100) }
        let emptyAccount = NotesDirectFolder(accountID: folder.accountID, accountName: "", id: folder.id, name: folder.name)
        try emptyAccount.validate()
        try expect(emptyAccount.accountName.isEmpty && emptyAccount.label.hasPrefix("未命名 / "),
                   "missing provider name gets a display placeholder without changing metadata")
        let providerName = "Synthetic\nfolder\0" + String(UnicodeScalar(0x202E)!)
        let metadataFolder = NotesDirectFolder(accountID: folder.accountID, accountName: folder.accountName, id: folder.id, name: providerName)
        try metadataFolder.validate()
        try expect(metadataFolder.name == providerName && metadataFolder.label.contains("\\u{A}") &&
                   metadataFolder.label.contains("\\u{0}") && metadataFolder.label.contains("\\u{202E}") &&
                   !metadataFolder.label.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                   "provider controls are preserved for identity but rendered as visible escapes")
        try expect(NotesDirectContract.metadataLabel("Synthetic\nfolder") != NotesDirectContract.metadataLabel("Synthetic\\u{A}folder"),
                   "literal backslashes cannot imitate escaped controls")
        let oversizedFolder = NotesDirectFolder(accountID: folder.accountID, accountName: folder.accountName, id: folder.id, name: String(repeating: "x", count: 1025))
        do { try oversizedFolder.validate(); throw Failure.assertion("oversized metadata admitted") }
        catch let error as AppleDirectFault {
            try expect(error.code == "invalid_text" && error.step == .notesFolderName && error.valueIssue == .tooLong &&
                       !error.diagnostic.contains(String(repeating: "x", count: 8)), "metadata remains bounded without logging provider values")
        }
        var actualProviderName = providerName, metadataCalls = 0
        let metadataBackend = NotesDirectBackend(send: { event, params in
            metadataCalls += 1
            guard let direct = params[UInt32(keyDirectObject)] else { throw Failure.assertion("metadata direct object") }
            if event == 0x636e7465 { return .init(int32: 1) }
            guard event == 0x67657464, let code = direct.forKeyword(0x73656c64)?.typeCodeValue,
                  let owner = direct.forKeyword(0x66726f6d), let kind = owner.forKeyword(0x77616e74)?.typeCodeValue else {
                throw Failure.assertion("metadata-only event expected")
            }
            if code == 0x49442020 { return .init(string: kind == 0x63666f6c ? folder.id : folder.accountID) }
            if code == 0x706e616d { return .init(string: kind == 0x61636374 ? folder.accountName : actualProviderName) }
            if code == 0x73687264 { return .init(boolean: false) }
            throw Failure.assertion("no note or mutation event allowed")
        }, check: {})
        let listed = try metadataBackend.folders()
        try expect(listed == [metadataFolder], "folder enumeration accepts bounded provider metadata")
        let metadataScope = NotesDirectScope(folder: metadataFolder, expires: Date().addingTimeInterval(500))
        try metadataBackend.verify(metadataScope)
        actualProviderName = providerName + "changed"
        try rejected("raw provider rename invalidates the selected target") { try metadataBackend.verify(metadataScope) }
        try expect(metadataCalls > 0, "synthetic metadata flow contains no live Notes access")
        var claims = 0, effects = 0, confirmations = 0
        let result = try NotesDirectCreate.perform(proposal: proposal, expectedDigest: proposal.digest,
            validate: {}, claim: { claims += 1 }, effect: { check in try check(); effects += 1; return "synthetic-id" }, confirmed: { confirmations += 1 })
        try expect(result == "synthetic-id" && claims == 1 && effects == 1 && confirmations == 1, "single effect after claim")
        try rejected("digest mismatch before claim") {
            _ = try NotesDirectCreate.perform(proposal: altered, expectedDigest: proposal.digest,
                validate: {}, claim: { claims += 1 }, effect: { _ in effects += 1; return "bad" }, confirmed: {})
        }
        try expect(claims == 1 && effects == 1, "changed proposal causes zero new effect")
        try rejected("cancel before claim") {
            _ = try NotesDirectCreate.perform(proposal: proposal, expectedDigest: proposal.digest,
                validate: { throw AppleDirectFault("cancelled") }, claim: { claims += 1 }, effect: { _ in effects += 1; return "bad" }, confirmed: {})
        }
        try expect(claims == 1 && effects == 1, "cancel causes zero new effect")
        do {
            _ = try NotesDirectCreate.perform(proposal: proposal, expectedDigest: proposal.digest,
                validate: {}, claim: { throw AppleDirectFault("journal_uncertain") }, effect: { _ in effects += 1; return "bad" }, confirmed: {})
            throw Failure.assertion("partial claim accepted")
        } catch let error as NotesDirectCreateFault { try expect(error.consumed && effects == 1, "partial journal failure never effects") }
        do {
            _ = try NotesDirectCreate.perform(proposal: proposal, expectedDigest: proposal.digest,
                validate: {}, claim: {}, effect: { _ in effects += 1; throw AppleDirectFault("automation_unconfirmed") }, confirmed: { confirmations += 1 })
            throw Failure.assertion("timeout accepted")
        } catch let error as NotesDirectCreateFault { try expect(error.consumed && effects == 2 && confirmations == 1, "timeout is consumed and not retried") }
        let id = UUID(), digest = proposal.digest
        do {
            let journal = try AppleDirectJournal(home: root)
            try journal.claim(id: id, digest: digest)
            try rejected("duplicate claim") { try journal.claim(id: id, digest: digest) }
            try journal.claim(id: UUID(), digest: digest)
            checks += 1
            try journal.confirmed(id: id, digest: digest)
            try rejected("completed ID still not replayed") { try journal.claim(id: id, digest: digest) }
        }
        do {
            let reopened = try AppleDirectJournal(home: root)
            try rejected("reopened duplicate") { try reopened.claim(id: id, digest: digest) }
            let fresh = UUID(); try reopened.claim(id: fresh, digest: digest)
            try reopened.claim(id: UUID(), digest: digest)
            checks += 1
        }
        do {
            let reopened = try AppleDirectJournal(home: root)
            try reopened.claim(id: UUID(), digest: digest)
            try rejected("original unknown ID remains consumed after restart") { try reopened.claim(id: id, digest: digest) }
        }
        let journalPath = root.appendingPathComponent("apple-direct-once-v1")
        try FileManager.default.moveItem(at: journalPath, to: root.appendingPathComponent("retained-journal"))
        try rejected("missing anchored directory must not recreate") { _ = try AppleDirectJournal(home: root) }
        try FileManager.default.createDirectory(at: journalPath, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try rejected("replacement inode rejected") { _ = try AppleDirectJournal(home: root) }
        let scopedContainer = try AppleDirectDescriptor.object(0x61636374, id: folder.accountID)
        let scopedCount = AppleDirectDescriptor.countParameters(0x63666f6c, parent: scopedContainer)
        try expect(Set(scopedCount.keys) == [UInt32(keyDirectObject), UInt32(keyAEObjectClass)] &&
                   scopedCount[UInt32(keyDirectObject)]?.data == scopedContainer.data &&
                   scopedCount[UInt32(keyAEObjectClass)]?.typeCodeValue == 0x63666f6c,
                   "folder count keeps selected container and class as separate wire parameters")
        var accountCountCalls = 0
        let emptyAccounts = NotesDirectBackend(send: { eventID, parameters in
            guard eventID == 0x636e7465,
                  Set(parameters.keys) == [UInt32(keyDirectObject), UInt32(keyAEObjectClass)],
                  parameters[UInt32(keyDirectObject)]?.descriptorType == typeNull,
                  parameters[UInt32(keyAEObjectClass)]?.descriptorType == typeType,
                  parameters[UInt32(keyAEObjectClass)]?.typeCodeValue == 0x61636374 else {
                throw AppleDirectFault("automation_failed", nativeStatus: -1700)
            }
            accountCountCalls += 1; return .init(int32: 0)
        }, check: {})
        try expect(try emptyAccounts.folders().isEmpty && accountCountCalls == 1,
                   "real folder consumer sends compiler-compatible account count without extra reads")
        let all = try AppleDirectDescriptor.all(0x61636374)
        let ordinal = all.forKeyword(0x73656c64)
        try expect(ordinal?.descriptorType == typeAbsoluteOrdinal && ordinal?.data == Data([0x61, 0x6c, 0x6c, 0x20]),
                   "all-account selector uses the Apple Event absolute ordinal wire type")
        let systemFault = AppleDirectFault("automation_failed", nativeStatus: -1708)
        try expect(systemFault.code == "automation_failed" && systemFault.diagnostic.contains("-1708"),
                   "finite native error survives without changing semantic code")
        let object = try AppleDirectDescriptor.object(0x63666f6c, id: folder.id,
            parent: AppleDirectDescriptor.object(0x61636374, id: folder.accountID))
        try expect(object.descriptorType == typeObjectSpecifier, "folder descriptor type")
        let parent = object.forKeyword(0x66726f6d)
        try expect(parent?.forKeyword(0x73656c64)?.stringValue == folder.accountID && object.forKeyword(0x73656c64)?.stringValue == folder.id,
                   "account-folder ID chain")
        let stop = AppleDirectCancellation()
        var dispatches = 0
        try rejected("cancel during permission preflight") {
            _ = try AppleDirectDispatch.perform(check: stop.check, preflight: { stop.cancel(); return .authorized },
                deliver: { dispatches += 1; return true })
        }
        try expect(dispatches == 0, "late permission success does not send")
        var page = NotesDirectPageState()
        page.appear()
        let ticket = page.ticket(folder: folder)!
        try page.validate(ticket, currentFolder: folder)
        page.disappear()
        try rejected("queued click after disappear") { try page.validate(ticket, currentFolder: folder) }
        page.appear()
        try rejected("old click after reopening page") { try page.validate(ticket, currentFolder: folder) }
        let currentTicket = page.ticket(folder: folder)!
        try rejected("target changed after click") { try page.validate(currentTicket, currentFolder: moved) }
        page.cancel()
        try rejected("cancel invalidates queued click") { try page.validate(currentTicket, currentFolder: folder) }
        var session: [String: Any] = [kCGSessionUserIDKey as String: NSNumber(value: getuid()),
            kCGSessionOnConsoleKey as String: true, kCGSessionLoginDoneKey as String: true, "CGSSessionScreenIsLocked": false]
        try expect(AppleDirectAuthority.sessionIsAvailable(session, uid: getuid()), "SDK-defined session keys accepted")
        session.removeValue(forKey: kCGSessionLoginDoneKey as String)
        session["kCGSSessionLoginDoneKey"] = true
        try expect(!AppleDirectAuthority.sessionIsAvailable(session, uid: getuid()), "wrong login-key spelling never grants")
        session[kCGSessionLoginDoneKey as String] = true; session["CGSSessionScreenIsLocked"] = true
        try expect(!AppleDirectAuthority.sessionIsAvailable(session, uid: getuid()), "locked session rejected")
        session["CGSSessionScreenIsLocked"] = false
        try expect(!AppleDirectAuthority.sessionIsAvailable(session, uid: getuid() + 1), "different uid rejected")
        session[kCGSessionOnConsoleKey as String] = false
        try expect(!AppleDirectAuthority.sessionIsAvailable(session, uid: getuid()), "off-console session rejected")
        var nativeRequests = 0
        let backend = NotesDirectBackend(send: { _,_ in nativeRequests += 1; throw Failure.assertion("unexpected native request") }, check: {})
        try rejected("expired backend before event") { try backend.verify(.init(folder: folder, expires: Date().addingTimeInterval(-1))) }
        try expect(nativeRequests == 0, "no live or synthetic dispatch on invalid scope")
        print("{\"status\":\"PASS\",\"checks\":\(checks),\"actual_os_or_notes_calls\":false}")
    }
}
