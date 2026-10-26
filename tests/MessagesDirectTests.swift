import Foundation
import ApplicationServices
import Darwin

@MainActor @main enum MessagesDirectTests {
    enum Failure: Error { case assertion(String) }
    static var checks = 0
    static func expect(_ condition: Bool, _ name: String) throws {
        guard condition else { throw Failure.assertion(name) }; checks += 1
    }
    static func rejected(_ name: String, _ body: () throws -> Void) throws {
        do { try body() } catch { checks += 1; return }; throw Failure.assertion(name)
    }
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { throw Failure.assertion("owned fixture root required") }
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        guard root.path == root.resolvingSymlinksInPath().path else { throw Failure.assertion("canonical root required") }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let account = MessagesDirectAccount(id: "synthetic-account", label: "Synthetic iMessage")
        let recipient = MessagesDirectRecipient(account: account, id: "actual-synthetic-id", handle: "recipient@example.test", expires: Date().addingTimeInterval(290))
        let proposal = MessagesDirectProposal(id: UUID(), recipient: recipient, plaintext: "Synthetic text only.\nNo real messages.", expires: Date().addingTimeInterval(100))
        try proposal.validate(); try expect(true, "explicit synthetic email accepted")
        for address in ["+12345678900", "Name <recipient@example.test>", "mailto:recipient@example.test", "a@b.test,c@d.test", "a\n@b.test", "人@example.test"] {
            try rejected("non-explicit email rejected") { try MessagesDirectContract.email(address) }
        }
        let altered = MessagesDirectProposal(id: proposal.id, recipient: recipient, plaintext: proposal.plaintext + " changed", expires: proposal.expires)
        try expect(altered.digest != proposal.digest, "full text bound to digest")
        let other = MessagesDirectRecipient(account: account, id: "other-id", handle: recipient.handle, expires: recipient.expires)
        try expect(MessagesDirectProposal(id: proposal.id, recipient: other, plaintext: proposal.plaintext, expires: proposal.expires).digest != proposal.digest, "actual target bound to digest")
        try rejected("expired recipient") { try MessagesDirectRecipient(account: account, id: recipient.id, handle: recipient.handle, expires: Date().addingTimeInterval(-1)).validate() }
        try rejected("bounded text") { try MessagesDirectContract.text(String(repeating: "x", count: 8193), maximum: 8192, multiline: true) }
        let query = try MessagesDirectBackend.filteredParticipantIDs(accountID: account.id, email: recipient.handle)
        let matched = query.forKeyword(0x66726f6d), comparison = matched?.forKeyword(0x73656c64)
        try expect(query.descriptorType == typeObjectSpecifier && query.forKeyword(0x73656c64)?.typeCodeValue == 0x49442020, "only participant ID projected")
        try expect(matched?.forKeyword(0x666f726d)?.enumCodeValue == 0x74657374 && matched?.forKeyword(0x77616e74)?.typeCodeValue == 0x70726573, "fixed participant formTest")
        try expect(comparison?.descriptorType == typeCompDescriptor && comparison?.forKeyword(0x72656c6f)?.enumCodeValue == 0x3d202020, "comparison uses equals code")
        try expect(comparison?.forKeyword(0x6f626a31)?.forKeyword(0x66726f6d)?.descriptorType == typeObjectBeingExamined && comparison?.forKeyword(0x6f626a32)?.stringValue == recipient.handle, "exact hndl predicate")
        try expect(matched?.forKeyword(0x66726f6d)?.forKeyword(0x73656c64)?.stringValue == account.id, "query scoped to selected actual account")
        let one = NSAppleEventDescriptor.list(); one.insert(.init(string: recipient.id), at: 1)
        try expect(try MessagesDirectBackend.uniqueParticipantID(one) == recipient.id, "strict unique list accepted")
        try rejected("scalar cannot become singleton") { _ = try MessagesDirectBackend.uniqueParticipantID(.init(string: recipient.id)) }
        try rejected("empty list rejected") { _ = try MessagesDirectBackend.uniqueParticipantID(.list()) }
        let two = NSAppleEventDescriptor.list(); two.insert(.init(string: recipient.id), at: 1); two.insert(.init(string: "second"), at: 2)
        try rejected("multiple matches rejected") { _ = try MessagesDirectBackend.uniqueParticipantID(two) }
        let number = NSAppleEventDescriptor.list(); number.insert(.init(int32: 1), at: 1)
        try rejected("numeric ID not coerced") { _ = try MessagesDirectBackend.uniqueParticipantID(number) }
        var accountCountCalls = 0
        let emptyAccounts = MessagesDirectBackend(send: { eventClass, eventID, parameters in
            guard eventClass == 0x636f7265, eventID == 0x636e7465,
                  Set(parameters.keys) == [UInt32(keyDirectObject), UInt32(keyAEObjectClass)],
                  parameters[UInt32(keyDirectObject)]?.descriptorType == typeNull,
                  parameters[UInt32(keyAEObjectClass)]?.descriptorType == typeType,
                  parameters[UInt32(keyAEObjectClass)]?.typeCodeValue == 0x69637376 else {
                throw AppleDirectFault("automation_failed", nativeStatus: -1700)
            }
            accountCountCalls += 1; return .init(int32: 0)
        }, check: {})
        try expect(try emptyAccounts.accounts().accounts.isEmpty && accountCountCalls == 2,
                   "real account consumer uses compiler-compatible count and never reads participants")
        let failedCount = MessagesDirectBackend(send: { _,_,_ in throw AppleDirectFault("automation_failed", nativeStatus: -10000) }, check: {})
        do { _ = try failedCount.accounts(); throw Failure.assertion("failed count accepted") }
        catch let error as AppleDirectFault {
            try expect(error.code == "automation_failed" && error.nativeStatus == -10000 && error.step == .messagesCount,
                       "actual account consumer preserves native error and closed count stage")
        }
        func properties(_ id: String, label: String = "Synthetic iMessage", service: UInt32 = 0x73696d73,
                        malformedType: Bool = false) -> NSAppleEventDescriptor {
            let record = NSAppleEventDescriptor.record()
            record.setDescriptor(.init(string: id), forKeyword: 0x49442020)
            record.setDescriptor(.init(string: label), forKeyword: 0x6d73646e)
            record.setDescriptor(malformedType ? .init(string: "RCS") : .init(enumCode: service), forKeyword: 0x73747970)
            record.setDescriptor(.init(boolean: true), forKeyword: 0x656e626c)
            record.setDescriptor(.init(enumCode: 0x636f6e6e), forKeyword: 0x73737461)
            return record
        }
        var wrongStableID = false, malformedType = false, countDrift = false, mixedCounts = 0
        let mixedAccounts = MessagesDirectBackend(send: { cls, event, params in
            guard cls == 0x636f7265 else { throw Failure.assertion("no effects in account scan") }
            if event == 0x636e7465 { mixedCounts += 1; return .init(int32: countDrift && mixedCounts > 1 ? 5 : 4) }
            guard event == 0x67657464, let prop = params[0x2d2d2d2d], let ref = prop.forKeyword(0x66726f6d),
                  prop.forKeyword(0x73656c64)?.typeCodeValue == 0x70414c4c else { throw Failure.assertion("one complete properties response required") }
            let indexed = ref.forKeyword(0x666f726d)?.enumCodeValue == 0x696e6478
            let index = indexed ? Int(ref.forKeyword(0x73656c64)!.int32Value) : Int(ref.forKeyword(0x73656c64)!.stringValue!.suffix(1))!
            if index == 1 { throw AppleDirectFault("automation_failed", nativeStatus: -10000) }
            let service: UInt32 = index == 2 ? 0x73736d73 : index == 4 ? 0x73726373 : 0x73696d73
            return properties("synthetic-" + String(wrongStableID && !indexed ? 8 : index), service: service, malformedType: malformedType && index == 4)
        }, check: {})
        let scan = try mixedAccounts.accounts()
        try expect(scan.total == 4 && scan.accounts.map(\.id) == ["synthetic-3"] && scan.excluded == 2,
                   "failed account cannot block independently verified iMessage or admit SMS/RCS")
        try expect(scan.failures.count == 1 && scan.failures[0].index == 1 && scan.failures[0].fault.nativeStatus == -10000 &&
                   scan.failures[0].fault.step == .messagesIndexedMetadata && !scan.failures[0].fault.diagnostic.contains("synthetic"),
                   "failed whole-account observation retains selector stage and native status without provider values")
        try expect(scan.services[.iMessage] == 1 && scan.services[.sms] == 1 && scan.services[.rcs] == 1,
                   "service counts require actual typed provider values")
        malformedType = true
        let malformedScan = try mixedAccounts.accounts()
        try expect(malformedScan.accounts.count == 1 && malformedScan.failures.count == 2 &&
                   malformedScan.failures.last?.fault.code == "invalid_response" && malformedScan.failures.last?.fault.step == .messagesServiceType,
                   "malformed service field is an explicit failure without a fabricated enum")
        malformedType = false; wrongStableID = true
        try rejected("stable observation cannot return another account ID") { _ = try mixedAccounts.accounts() }
        wrongStableID = false; countDrift = true; mixedCounts = 0
        try rejected("account count drift discards partial scan") { _ = try mixedAccounts.accounts() }
        var cancelledScan = false
        let cancelledAccounts = MessagesDirectBackend(send: { _, event, _ in
            if event == 0x636e7465 { return .init(int32: 2) }
            cancelledScan = true; throw AppleDirectFault("automation_failed", nativeStatus: -10000)
        }, check: { if cancelledScan { throw AppleDirectFault("cancelled") } })
        try rejected("cancellation never becomes isolated provider failure") { _ = try cancelledAccounts.accounts() }
        var optionalSourceDrift = false
        let optionalDescriptions = MessagesDirectBackend(send: { cls, event, params in
            if event == 0x636e7465 { return .init(int32: 8) }
            guard cls == 0x636f7265, event == 0x67657464,
                  let property = params[0x2d2d2d2d], property.forKeyword(0x73656c64)?.typeCodeValue == 0x70414c4c,
                  let ref = property.forKeyword(0x66726f6d) else { throw Failure.assertion("optional labels use whole-account metadata only") }
            let indexed = ref.forKeyword(0x666f726d)?.enumCodeValue == 0x696e6478
            let index = indexed ? Int(ref.forKeyword(0x73656c64)!.int32Value) : Int(ref.forKeyword(0x73656c64)!.stringValue!.suffix(1))!
            if index == 8 { throw AppleDirectFault("automation_failed", nativeStatus: -10000) }
            let record = NSAppleEventDescriptor.record()
            record.setDescriptor(.init(string: "synthetic-optional-" + String(index)), forKeyword: 0x49442020)
            switch index {
            case 1: if optionalSourceDrift && !indexed { record.setDescriptor(.null(), forKeyword: 0x6d73646e) }
            case 2: record.setDescriptor(.null(), forKeyword: 0x6d73646e)
            case 3: record.setDescriptor(.init(typeCode: 0x6d736e67), forKeyword: 0x6d73646e)
            case 4: record.setDescriptor(.init(string: ""), forKeyword: 0x6d73646e)
            case 5: record.setDescriptor(.init(string: "   "), forKeyword: 0x6d73646e)
            default: record.setDescriptor(.init(int32: 1), forKeyword: 0x6d73646e)
            }
            record.setDescriptor(.init(enumCode: index == 7 ? 0x73736d73 : 0x73696d73), forKeyword: 0x73747970)
            record.setDescriptor(.init(boolean: true), forKeyword: 0x656e626c)
            record.setDescriptor(.init(enumCode: 0x636f6e6e), forKeyword: 0x73737461)
            return record
        }, check: {})
        let optionalScan = try optionalDescriptions.accounts()
        try expect(optionalScan.accounts.map(\.id) == (1...5).map { "synthetic-optional-" + String($0) },
                   "missing, null, missing-value and empty descriptions preserve real stable account IDs")
        try expect(optionalScan.accounts.allSatisfy { $0.label.contains("未提供名称") }, "fallback labels explicitly disclose unavailable provider names")
        try expect(optionalScan.excluded == 1 && optionalScan.services[.sms] == 1,
                   "inapplicable account is classified before irrelevant display field decoding")
        try expect(optionalScan.failures.count == 2 && optionalScan.failures[0].index == 6 &&
                   optionalScan.failures[0].fault.step == .messagesDescription && optionalScan.failures[1].fault.nativeStatus == -10000,
                   "malformed active description and provider errors remain per-account failures alongside success")
        optionalSourceDrift = true
        try rejected("optional source changes between indexed and stable records are not silently collapsed") { _ = try optionalDescriptions.accounts() }
        var effectCalls = 0, observedText: String?, observedRecipientID: String?
        var serviceType: UInt32 = 0x73696d73, actualHandle = recipient.handle, actualAccountID = account.id
        let backend = MessagesDirectBackend(send: { eventClass, eventID, parameters in
            if eventClass == 0x636f7265 && eventID == 0x636e7465 { return .init(int32: 1) }
            if eventClass == 0x69636874 && eventID == 0x73656e64 {
                effectCalls += 1; observedText = parameters[0x2d2d2d2d]?.stringValue
                observedRecipientID = parameters[0x544f2020]?.forKeyword(0x73656c64)?.stringValue
                guard Set(parameters.keys) == [0x2d2d2d2d, 0x544f2020] else { throw Failure.assertion("unexpected send parameter") }
                return .null() // Successful no-result send is accepted, never retried.
            }
            guard eventClass == 0x636f7265 && eventID == 0x67657464,
                  let property = parameters[0x2d2d2d2d], let ref = property.forKeyword(0x66726f6d),
                  let code = property.forKeyword(0x73656c64)?.typeCodeValue else { throw Failure.assertion("unexpected metadata request") }
            switch code {
            case 0x70414c4c: return properties(actualAccountID, label: account.label, service: serviceType)
            case 0x49442020:
                if ref.forKeyword(0x666f726d)?.enumCodeValue == 0x74657374 { return one }
                if ref.forKeyword(0x77616e74)?.typeCodeValue == 0x70726573 { return .init(string: recipient.id) }
                return .init(string: actualAccountID)
            case 0x6d73646e: return .init(string: account.label)
            case 0x73747970: return .init(enumCode: serviceType)
            case 0x73737461: return .init(enumCode: 0x636f6e6e)
            case 0x656e626c: return .init(boolean: true)
            case 0x686e646c: return .init(string: actualHandle)
            default: throw Failure.assertion("forbidden property read")
            }
        }, check: {})
        let verified = try backend.recipient(account: account, email: recipient.handle)
        try expect(verified.id == recipient.id && verified.handle == recipient.handle, "actual ID and account binding")
        try backend.deliver(proposal, beforeEffect: {})
        try expect(effectCalls == 1 && observedText == proposal.plaintext && observedRecipientID == recipient.id, "single fixed send with exact text and ID")
        actualAccountID = "synthetic-replaced-account"
        try rejected("selected account ID belongs to the same whole-account observation") { try backend.deliver(proposal, beforeEffect: {}) }
        try expect(effectCalls == 1, "account replacement cannot send using a stale stable selector")
        actualAccountID = account.id
        actualHandle = "Recipient@example.test"
        try rejected("exact handle changed") { try backend.deliver(proposal, beforeEffect: {}) }
        try expect(effectCalls == 1, "case mismatch does not send")
        actualHandle = recipient.handle; serviceType = 0x73736d73
        try rejected("SMS account rejected") { try backend.deliver(proposal, beforeEffect: {}) }
        try expect(effectCalls == 1, "SMS account zero additional sends")
        serviceType = 0x73696d73
        try rejected("cancel immediately before effect") { try backend.deliver(proposal, beforeEffect: { throw AppleDirectFault("cancelled") }) }
        try expect(effectCalls == 1, "late cancel zero additional sends")
        var claims = 0, effects = 0, accepted = 0
        try MessagesDirectSend.perform(proposal: proposal, expectedDigest: proposal.digest, validate: {}, claim: { claims += 1 },
            effect: { validate in try validate(); effects += 1 }, accepted: { accepted += 1 })
        try expect(claims == 1 && effects == 1 && accepted == 1, "durable claim before one send")
        try rejected("changed content before journal") {
            try MessagesDirectSend.perform(proposal: altered, expectedDigest: proposal.digest, validate: {}, claim: { claims += 1 }, effect: { _ in effects += 1 }, accepted: {})
        }
        try expect(claims == 1 && effects == 1, "digest mismatch zero additional claim/send")
        do {
            try MessagesDirectSend.perform(proposal: proposal, expectedDigest: proposal.digest, validate: {}, claim: { throw AppleDirectFault("journal_uncertain") }, effect: { _ in effects += 1 }, accepted: {})
            throw Failure.assertion("partial claim accepted")
        } catch let failure as MessagesDirectSendFault { try expect(failure.consumed && effects == 1, "partial claim never sends") }
        do {
            try MessagesDirectSend.perform(proposal: proposal, expectedDigest: proposal.digest, validate: {}, claim: {}, effect: { _ in effects += 1; throw AppleDirectFault("automation_unconfirmed") }, accepted: { accepted += 1 })
            throw Failure.assertion("unknown send accepted")
        } catch let failure as MessagesDirectSendFault { try expect(failure.consumed && effects == 2 && accepted == 1, "unknown result consumed and never retried") }
        let journalID = UUID(), independentID = UUID()
        do {
            let journal = try MessagesDirectJournal(home: root)
            try journal.claim(id: journalID, digest: proposal.digest)
            try journal.claim(id: independentID, digest: proposal.digest)
            checks += 1 // Existing availability assertion now permits a genuinely new intent.
            try journal.accepted(id: journalID, digest: proposal.digest)
            try rejected("accepted operation cannot replay") { try journal.claim(id: journalID, digest: proposal.digest) }
        }
        do {
            let reopened = try MessagesDirectJournal(home: root)
            try rejected("reopened operation cannot replay") { try reopened.claim(id: journalID, digest: proposal.digest) }
            try reopened.claim(id: UUID(), digest: proposal.digest)
        }
        do { let reopened = try MessagesDirectJournal(home: root); try rejected("original unknown UUID remains consumed after restart") { try reopened.claim(id: independentID, digest: proposal.digest) } }
        let journalPath = root.appendingPathComponent("messages-direct-once-v1")
        try FileManager.default.moveItem(at: journalPath, to: root.appendingPathComponent("retained-journal"))
        try rejected("lost anchored directory never recreated") { _ = try MessagesDirectJournal(home: root) }
        var page = MessagesDirectPageState(); page.appear()
        let click = page.ticket(account: account, recipient: recipient)!
        page.disappear()
        try rejected("hidden queued send") { try page.validate(click, account: account, recipient: recipient) }
        page.appear()
        try rejected("old click after reopening") { try page.validate(click, account: account, recipient: recipient) }
        let current = page.ticket(account: account, recipient: recipient)!
        try rejected("target edited after click") { try page.validate(current, account: account, recipient: other) }
        page.invalidate()
        try rejected("cancel invalidates click") { try page.validate(current, account: account, recipient: recipient) }
        print("{\"status\":\"PASS\",\"checks\":\(checks),\"actual_os_or_messages_calls\":false}")
    }
}
