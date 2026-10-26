import Foundation
import ApplicationServices

// Fixed public events for account/chat metadata, a unique explicit address,
// and a frozen text send. No message-history or protected-store fallback.
final class MessagesDirectBackend {
    typealias Transport = (UInt32, UInt32, [UInt32: NSAppleEventDescriptor]) throws -> NSAppleEventDescriptor
    private let send: Transport
    private let check: () throws -> Void
    init(session: AppleDirectSession) {
        send = { try session.send(eventClass: $0, eventID: $1, parameters: $2) }; check = session.check
    }
    init(send: @escaping Transport, check: @escaping () throws -> Void) { self.send = send; self.check = check }
    private let account: UInt32 = 0x69637376, participant: UInt32 = 0x70726573
    private let id: UInt32 = 0x49442020, handle: UInt32 = 0x686e646c
    private func get(_ code: UInt32, _ ref: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor {
        try check()
        do { return try send(0x636f7265, 0x67657464, [0x2d2d2d2d: AppleDirectDescriptor.property(code, of: ref)]) }
        catch let error as AppleDirectFault {
            let step: AppleDirectStep = switch code {
            case id: ref.forKeyword(0x77616e74)?.typeCodeValue == participant ? .messagesParticipantID : .messagesAccountID
            case 0x6d73646e: .messagesDescription
            case 0x73747970: .messagesServiceType
            case 0x656e626c: .messagesEnabled
            case 0x73737461: .messagesConnection
            case handle: .messagesHandle
            default: .messagesMetadata
            }
            throw error.at(step)
        }
    }
    static func text(_ value: NSAppleEventDescriptor, maximum: Int = 1024) throws -> String {
        guard [typeUnicodeText, typeUTF8Text, typeChar].contains(value.descriptorType),
              value.data.count <= maximum * 4, let text = value.stringValue else { throw AppleDirectFault("invalid_response") }
        try MessagesDirectContract.text(text, maximum: maximum); return text
    }
    private func text(_ code: UInt32, _ ref: NSAppleEventDescriptor) throws -> String {
        do { return try Self.text(get(code, ref)) }
        catch let error as AppleDirectFault {
            let step: AppleDirectStep = code == id ?
                (ref.forKeyword(0x77616e74)?.typeCodeValue == participant ? .messagesParticipantID : .messagesAccountID) :
                code == 0x6d73646e ? .messagesDescription : code == handle ? .messagesHandle : .messagesMetadata
            throw error.at(step)
        }
    }
    private enum AccountDescription: Equatable {
        case absent, null, missingValue, text(String), notApplicable
        var label: String? {
            guard case let .text(value) = self, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return value
        }
    }
    private func description(_ record: NSAppleEventDescriptor) throws -> AccountDescription {
        guard let field = record.forKeyword(0x6d73646e) else { return .absent }
        if field.descriptorType == typeNull { return .null }
        if field.descriptorType == typeType && field.typeCodeValue == 0x6d736e67 { return .missingValue }
        guard [typeUnicodeText, typeUTF8Text, typeChar].contains(field.descriptorType),
              field.data.count <= 4096, let value = field.stringValue else {
            throw AppleDirectFault("invalid_response", step: .messagesDescription)
        }
        if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            do { try MessagesDirectContract.text(value, maximum: 1024) }
            catch let error as AppleDirectFault { throw error.at(.messagesDescription) }
        }
        return .text(value)
    }
    private struct AccountObservation: Equatable {
        let account: MessagesDirectAccount
        let service: MessagesDirectService
        let enabled: Bool
        let connection: UInt32
        let description: AccountDescription
        var active: Bool { service == .iMessage && enabled && connection == 0x636f6e6e }
    }
    private func metadata(_ ref: NSAppleEventDescriptor) throws -> AccountObservation {
        let selector: AppleDirectStep = ref.forKeyword(0x666f726d)?.enumCodeValue == 0x49442020 ? .messagesStableMetadata : .messagesIndexedMetadata
        do {
            try check()
            // One pALL response belongs to one resolved account. Separate ID
            // witnesses cannot make per-property indexed reads safe against ABA.
            let record = try send(0x636f7265, 0x67657464,
                [0x2d2d2d2d: AppleDirectDescriptor.property(0x70414c4c, of: ref)])
            let required: Set<UInt32> = [id, 0x73747970, 0x656e626c, 0x73737461]
            guard record.descriptorType == typeAERecord, record.data.count <= 32768,
                  (4...6).contains(record.numberOfItems) else { throw AppleDirectFault("invalid_response") }
            let keys = (1...record.numberOfItems).map { record.keywordForDescriptor(at: $0) }
            guard Set(keys).count == keys.count, required.isSubset(of: Set(keys)),
                  Set(keys).isSubset(of: required.union([0x6d73646e, 0x70636c73])) else { throw AppleDirectFault("invalid_response") }
            if let kind = record.forKeyword(0x70636c73) {
                guard kind.descriptorType == typeType, kind.typeCodeValue == account else { throw AppleDirectFault("invalid_response") }
            }
            func string(_ code: UInt32, _ step: AppleDirectStep) throws -> String {
                guard let field = record.forKeyword(code) else { throw AppleDirectFault("invalid_response", step: step) }
                do { return try Self.text(field) }
                catch let error as AppleDirectFault { throw error.at(step) }
            }
            func enumeration(_ code: UInt32, _ step: AppleDirectStep) throws -> UInt32 {
                guard let field = record.forKeyword(code), field.descriptorType == typeEnumerated else {
                    throw AppleDirectFault("invalid_response", step: step)
                }
                return field.enumCodeValue
            }
            let accountID = try string(id, .messagesAccountID)
            let service: MessagesDirectService
            switch try enumeration(0x73747970, .messagesServiceType) {
            case 0x73696d73: service = .iMessage
            case 0x73736d73: service = .sms
            case 0x73726373: service = .rcs
            default: throw AppleDirectFault("unsupported_service", step: .messagesServiceType)
            }
            guard let enabled = record.forKeyword(0x656e626c), enabled.descriptorType == typeBoolean else {
                throw AppleDirectFault("invalid_response", step: .messagesEnabled)
            }
            let connection = try enumeration(0x73737461, .messagesConnection)
            guard [0x636f6e6e, 0x64636e67, 0x636f6e67, 0x64636f6e].contains(connection) else {
                throw AppleDirectFault("invalid_response", step: .messagesConnection)
            }
            let active = service == .iMessage && enabled.booleanValue && connection == 0x636f6e6e
            let sourceDescription = active ? try description(record) : .notApplicable
            let label = sourceDescription.label ?? service.rawValue + " 账户（未提供名称）"
            return .init(account: .init(id: accountID, label: label), service: service,
                         enabled: enabled.booleanValue, connection: connection, description: sourceDescription)
        } catch let error as AppleDirectFault { throw error.at(selector) }
    }
    private func accountCount() throws -> Int {
        try check()
        let count: NSAppleEventDescriptor
        do { count = try send(0x636f7265, 0x636e7465, AppleDirectDescriptor.countParameters(account)) }
        catch let error as AppleDirectFault { throw error.at(.messagesCount) }
        guard count.descriptorType == typeSInt32, (0...8).contains(count.int32Value) else { throw AppleDirectFault("account_count_unavailable") }
        return Int(count.int32Value)
    }
    func accounts() throws -> MessagesDirectAccountScan {
        let total = try accountCount()
        var result: [MessagesDirectAccount] = [], failures: [MessagesDirectAccountFailure] = []
        var seen = Set<String>(), excluded = 0
        var services: [MessagesDirectService: Int] = [:]
        for index in 1..<(total + 1) {
            try check()
            let indexed = try AppleDirectDescriptor.indexed(account, index: index, parent: .null())
            do {
                let observed = try metadata(indexed)
                guard seen.insert(observed.account.id).inserted else { throw AppleDirectFault("ambiguous_account") }
                services[observed.service, default: 0] += 1
                guard observed.active else { excluded += 1; continue }
                // The stable selector must return the same complete observation,
                // never a second set of fields grafted onto the indexed ID.
                let stable = try AppleDirectDescriptor.object(account, id: observed.account.id)
                guard try metadata(stable) == observed else { throw AppleDirectFault("target_changed") }
                result.append(observed.account)
            } catch let error as AppleDirectFault {
                guard ["automation_failed", "invalid_response", "invalid_text", "unsupported_service"].contains(error.code) else { throw error }
                failures.append(.init(index: index, fault: error))
            }
        }
        guard try accountCount() == total else { throw AppleDirectFault("target_changed") }
        try check(); return .init(accounts: result, total: total, excluded: excluded, services: services, failures: failures)
    }
    private func accountRef(_ value: MessagesDirectAccount) throws -> NSAppleEventDescriptor {
        try value.validate()
        let stable = try AppleDirectDescriptor.object(account, id: value.id)
        let observed = try metadata(stable)
        guard observed.account == value, observed.active else { throw AppleDirectFault("account_changed") }
        return stable
    }
    static func filteredParticipantIDs(accountID: String, email: String) throws -> NSAppleEventDescriptor {
        try MessagesDirectContract.text(accountID, maximum: 1024); try MessagesDirectContract.address(email)
        guard let examined = NSAppleEventDescriptor(descriptorType: typeObjectBeingExamined, data: Data()) else {
            throw AppleDirectFault("encoding_failed")
        }
        let comparison = NSAppleEventDescriptor.record()
        comparison.setDescriptor(try AppleDirectDescriptor.property(0x686e646c, of: examined), forKeyword: 0x6f626a31)
        comparison.setDescriptor(.init(string: email), forKeyword: 0x6f626a32)
        comparison.setDescriptor(.init(enumCode: 0x3d202020), forKeyword: 0x72656c6f)
        guard let test = comparison.coerce(toDescriptorType: typeCompDescriptor) else { throw AppleDirectFault("encoding_failed") }
        let owner = try AppleDirectDescriptor.object(0x69637376, id: accountID)
        let matched = try AppleDirectDescriptor.specifier(0x70726573, form: 0x74657374, key: test, parent: owner)
        return try AppleDirectDescriptor.property(0x49442020, of: matched)
    }
    static func uniqueParticipantID(_ value: NSAppleEventDescriptor) throws -> String {
        guard value.descriptorType == typeAEList, value.numberOfItems == 1,
              value.data.count <= 8192, let item = value.atIndex(1) else { throw AppleDirectFault("recipient_not_unique") }
        return try text(item)
    }
    func recipient(account value: MessagesDirectAccount, email: String) throws -> MessagesDirectRecipient {
        try MessagesDirectContract.address(email); _ = try accountRef(value); try check()
        let query = try Self.filteredParticipantIDs(accountID: value.id, email: email)
        let answer = try send(0x636f7265, 0x67657464, [0x2d2d2d2d: query])
        let actualID = try Self.uniqueParticipantID(answer)
        let result = MessagesDirectRecipient(account: value, id: actualID, handle: email, expires: Date().addingTimeInterval(300))
        _ = try verify(result); return result
    }
    func verify(_ value: MessagesDirectRecipient) throws -> NSAppleEventDescriptor {
        try value.validate()
        let owner = try accountRef(value.account)
        let ref = try AppleDirectDescriptor.object(participant, id: value.id, parent: owner)
        let service = try AppleDirectDescriptor.property(account, of: ref)
        guard try text(id, ref) == value.id, try text(handle, ref) == value.handle,
              try text(id, service) == value.account.id else { throw AppleDirectFault("recipient_changed") }
        try check(); return ref
    }
    private func chatObservation(_ ref: NSAppleEventDescriptor, account value: MessagesDirectAccount) throws -> MessagesDirectChat {
        try check()
        let record = try send(0x636f7265, 0x67657464, [0x2d2d2d2d: AppleDirectDescriptor.property(0x70414c4c, of: ref)])
        let required: Set<UInt32> = [id, 0x706e616d, account]
        guard record.descriptorType == typeAERecord, record.data.count <= 32768,
              (3...4).contains(record.numberOfItems) else { throw AppleDirectFault("invalid_response") }
        let keys = (1...record.numberOfItems).map { record.keywordForDescriptor(at: $0) }
        guard Set(keys).count == keys.count, required.isSubset(of: Set(keys)),
              Set(keys).isSubset(of: required.union([0x70636c73])),
              let chatID = record.forKeyword(id), let title = record.forKeyword(0x706e616d),
              let owner = record.forKeyword(account), owner.descriptorType == typeObjectSpecifier else { throw AppleDirectFault("invalid_response") }
        if let kind = record.forKeyword(0x70636c73) {
            guard kind.descriptorType == typeType, kind.typeCodeValue == 0x696d6374 else { throw AppleDirectFault("invalid_response") }
        }
        guard try text(id, owner) == value.id else { throw AppleDirectFault("account_changed") }
        guard [typeUnicodeText, typeUTF8Text, typeChar].contains(title.descriptorType),
              let chatName = title.stringValue, chatName.utf8.count <= 4096 else { throw AppleDirectFault("invalid_response") }
        return .init(id: try Self.text(chatID), name: chatName, account: value)
    }
    func chats(account value: MessagesDirectAccount, query: String = "") throws -> MessagesDirectChatPage {
        if !query.isEmpty { try MessagesDirectContract.text(query, maximum: 1024) }
        let owner = try accountRef(value)
        try check()
        let answer = try send(0x636f7265, 0x636e7465, AppleDirectDescriptor.countParameters(0x696d6374, parent: owner))
        guard answer.descriptorType == typeSInt32, answer.int32Value >= 0 else { throw AppleDirectFault("invalid_response") }
        let total = Int(answer.int32Value)
        var result: [MessagesDirectChat] = [], seen = Set<String>(), scanned = 0
        for index in 0..<min(total, 200) {
            let indexed = try AppleDirectDescriptor.indexed(0x696d6374, index: index + 1, parent: owner)
            let observed = try chatObservation(indexed, account: value)
            guard seen.insert(observed.id).inserted else { throw AppleDirectFault("ambiguous_target") }
            let stable = try AppleDirectDescriptor.object(0x696d6374, id: observed.id, parent: owner)
            guard try chatObservation(stable, account: value) == observed else { throw AppleDirectFault("target_changed") }
            scanned += 1
            if query.isEmpty || observed.name.localizedCaseInsensitiveContains(query) || observed.id.localizedCaseInsensitiveContains(query) {
                result.append(observed)
                if result.count == 50 { break }
            }
        }
        _ = try accountRef(value)
        let recount = try send(0x636f7265, 0x636e7465, AppleDirectDescriptor.countParameters(0x696d6374, parent: owner))
        guard recount.descriptorType == typeSInt32, recount.int32Value == answer.int32Value else { throw AppleDirectFault("target_changed") }
        return .init(chats: result, scanned: scanned, total: total)
    }
    func deliver(_ proposal: MessagesDirectProposal, beforeEffect: () throws -> Void) throws {
        try proposal.validate()
        let ref = try verify(proposal.recipient)
        try beforeEffect(); try proposal.validate(); try check()
        // This reply reports only system acceptance, not delivery, message ID
        // or the transport used internally by Messages. Never retry on error.
        _ = try send(0x69636874, 0x73656e64, [0x2d2d2d2d: .init(string: proposal.plaintext), 0x544f2020: ref])
    }
}
struct MessagesDirectSendFault: Error, Sendable { let code: String; let consumed: Bool; var businessLogAvailable:Bool? = nil }
enum MessagesDirectSend {
    static func perform(proposal: MessagesDirectProposal, expectedDigest: String,
                        validate: @escaping () throws -> Void, claim: () throws -> Void,
                        effect: (@escaping () throws -> Void) throws -> Void,
                        accepted: () throws -> Void) throws {
        var consumed = false
        do {
            try proposal.validate()
            guard proposal.digest == expectedDigest else { throw AppleDirectFault("proposal_changed") }
            try validate(); consumed = true; try claim()
            try effect { try proposal.validate();try validate() }; try accepted()
        } catch { throw MessagesDirectSendFault(code: (error as? AppleDirectFault)?.code ?? "send_unconfirmed", consumed: consumed) }
    }
}

/// One user submission resolves the explicit email and freezes the proposal
/// before entering the existing journal/effect transaction.
enum MessagesDirectSubmission {
    static func perform(id: UUID, account: MessagesDirectAccount, email: String, plaintext: String,
                        resolve: (MessagesDirectAccount, String) throws -> MessagesDirectRecipient,
                        submit: (MessagesDirectProposal) throws -> Void) throws {
        try account.validate(); try MessagesDirectContract.address(email)
        try MessagesDirectContract.text(plaintext, maximum: 8192, multiline: true)
        let target = try resolve(account, email)
        guard target.account == account, target.handle == email else { throw AppleDirectFault("recipient_changed") }
        let proposal = MessagesDirectProposal(id: id, recipient: target, plaintext: plaintext,
            expires: min(target.expires, Date().addingTimeInterval(120)))
        try proposal.validate()
        try submit(proposal)
    }
}


final class MessagesDirectHandler {
    private let home: URL
    private let backend: MessagesDirectBackend
    private let selectedAccount: MessagesDirectAccount?
    private(set) var businessLogAvailable = true
    init(home: URL, backend: MessagesDirectBackend, selectedAccount: MessagesDirectAccount? = nil) {
        self.home = home; self.backend = backend; self.selectedAccount = selectedAccount
    }
    private func requireSelection(_ account: MessagesDirectAccount) throws {
        guard let selectedAccount else { throw AppleDirectFault("target_required") }
        guard selectedAccount == account else { throw AppleDirectFault("account_changed") }
    }
    func handle(_ request: MessagesDirectRequest) throws -> MessagesDirectReply {
        let callID = UUID()
        record(callID, request: request, response: Optional<MessagesDirectResult>.none, fault: nil)
        do {
            let result: MessagesDirectResult
            switch request {
            case .accounts: result = .accounts(try backend.accounts())
            case let .chats(account, query):
                try requireSelection(account)
                result = .chats(try backend.chats(account: account, query: query))
            case let .prepareSend(id, account, address, plaintext):
                try requireSelection(account)
                var frozen: MessagesDirectProposal?
                try MessagesDirectSubmission.perform(id: id, account: account, email: address, plaintext: plaintext,
                    resolve: { try self.backend.recipient(account: $0, email: $1) }, submit: { frozen = $0 })
                guard let frozen else { throw AppleDirectFault("invalid_response") }
                result = .prepared(frozen)
            case let .send(proposal, expected):
                try requireSelection(proposal.recipient.account)
                let journal = try MessagesDirectJournal(home: home)
                try MessagesDirectSend.perform(proposal: proposal, expectedDigest: expected,
                    validate: {
                        let actual=try self.backend.recipient(account:proposal.recipient.account,email:proposal.recipient.handle)
                        guard actual.id==proposal.recipient.id,actual.account==proposal.recipient.account,actual.handle==proposal.recipient.handle else{throw AppleDirectFault("recipient_changed")}
                        _ = try self.backend.verify(proposal.recipient)
                    },
                    claim: { try journal.claim(id: proposal.id, digest: expected) },
                    effect: { try self.backend.deliver(proposal, beforeEffect: $0) },
                    accepted: { try journal.accepted(id: proposal.id, digest: expected) })
                result = .accepted(operationID: proposal.id)
            case let .read(account, chatID):
                try requireSelection(account)
                try account.validate(); try MessagesDirectContract.text(chatID, maximum: 1024)
                // Installed Messages.sdef has chat metadata and send; no message
                // history class, body, unread state or receive event is exported.
                result = .unsupported(code: "unsupported_public_api", reason: "系统未提供消息收读接口")
            }
            record(callID, request: request, response: result, fault: nil)
            return .init(result: result, businessLogAvailable: businessLogAvailable)
        } catch {
            let code = (error as? AppleDirectFault)?.code ?? (error as? MessagesDirectSendFault)?.code ?? "operation_unconfirmed"
            record(callID, request: request, response: Optional<MessagesDirectResult>.none, fault: code)
            if var fault=error as? AppleDirectFault {fault.businessLogAvailable=businessLogAvailable;throw fault}
            if var fault=error as? MessagesDirectSendFault {fault.businessLogAvailable=businessLogAvailable;throw fault}
            if !businessLogAvailable {var fault=AppleDirectFault("operation_unconfirmed");fault.businessLogAvailable=false;throw fault}
            throw error
        }
    }
    private func record(_ id: UUID, request: MessagesDirectRequest, response: MessagesDirectResult?, fault: String?) {
        if !AppleDirectBusinessLog.record(home: home, domain: "messages", callID: id, request: request, response: response, fault: fault) { businessLogAvailable = false }
    }
}
