import Foundation
import CryptoKit

struct MessagesDirectAccount: Identifiable, Equatable, Sendable, Codable {
    let id: String
    let label: String
    func validate() throws {
        try MessagesDirectContract.text(id, maximum: 1024)
        try MessagesDirectContract.text(label, maximum: 1024)
    }
}
// Failed accounts are reported by bounded ordinal and closed diagnostics, never
// promoted to usable accounts or identified from a guessed service/label.
struct MessagesDirectAccountFailure: Identifiable, Sendable, Codable {
    let index: Int
    let fault: AppleDirectFault
    var id: Int { index }
}
enum MessagesDirectService: String, CaseIterable, Sendable, Codable { case iMessage, sms = "SMS", rcs = "RCS" }
struct MessagesDirectAccountScan: Sendable, Codable {
    let accounts: [MessagesDirectAccount]
    let total: Int
    let excluded: Int
    let services: [MessagesDirectService: Int]
    let failures: [MessagesDirectAccountFailure]
}
struct MessagesDirectRecipient: Equatable, Sendable, Codable {
    let account: MessagesDirectAccount
    let id: String
    let handle: String
    let expires: Date
    func validate(now: Date = Date()) throws {
        try account.validate(); try MessagesDirectContract.text(id, maximum: 1024)
        try MessagesDirectContract.address(handle)
        guard expires > now, expires.timeIntervalSince(now) <= 300 else { throw AppleDirectFault("recipient_expired") }
    }
}
struct MessagesDirectProposal: Equatable, Sendable, Codable {
    let id: UUID
    let recipient: MessagesDirectRecipient
    let plaintext: String
    let expires: Date
    func validate(now: Date = Date()) throws {
        try recipient.validate(now: now); try MessagesDirectContract.text(plaintext, maximum: 8192, multiline: true)
        guard expires > now, expires <= recipient.expires, expires.timeIntervalSince(now) <= 120 else {
            throw AppleDirectFault("proposal_expired")
        }
    }
    var digest: String {
        let fields = ["messages.direct.email.text.v1", id.uuidString.lowercased(), recipient.account.id,
            recipient.account.label, recipient.id, recipient.handle, plaintext,
            String(recipient.expires.timeIntervalSince1970), String(expires.timeIntervalSince1970)]
        let bytes = try! JSONEncoder().encode(fields)
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}
enum MessagesDirectContract {
    static func text(_ value: String, maximum: Int, multiline: Bool = false) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.utf8.count <= maximum,
              value.unicodeScalars.allSatisfy({ $0.value >= 32 && !((127...159).contains($0.value)) ||
                  (multiline && [9, 10, 13].contains($0.value)) }) else { throw AppleDirectFault("invalid_text") }
    }
    static func email(_ value: String) throws {
        // An explicit email address only. Never interpret names, phone numbers,
        // URLs, lists, Contacts aliases or guessed participant identifiers.
        guard value.utf8.count <= 254, value.unicodeScalars.allSatisfy({ $0.isASCII }),
              value.range(of: #"^[A-Za-z0-9!#$%&'*+/=?^_`{|}~-]+(?:\.[A-Za-z0-9!#$%&'*+/=?^_`{|}~-]+)*@[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$"#,
                  options: .regularExpression) == value.startIndex..<value.endIndex else {
            throw AppleDirectFault("explicit_email_required")
        }
    }
}
struct MessagesDirectTicket: Sendable {
    let epoch: UUID
    let account: MessagesDirectAccount?
    let recipient: MessagesDirectRecipient?
}
struct MessagesDirectPageState {
    private(set) var epoch = UUID()
    private(set) var visible = false
    mutating func appear() { epoch = UUID(); visible = true }
    mutating func disappear() { epoch = UUID(); visible = false }
    mutating func invalidate() { epoch = UUID() }
    func ticket(account: MessagesDirectAccount?, recipient: MessagesDirectRecipient?) -> MessagesDirectTicket? {
        visible ? .init(epoch: epoch, account: account, recipient: recipient) : nil
    }
    func validate(_ ticket: MessagesDirectTicket, account: MessagesDirectAccount?, recipient: MessagesDirectRecipient?) throws {
        guard visible, ticket.epoch == epoch, ticket.account == account, ticket.recipient == recipient else {
            throw AppleDirectFault("user_action_expired")
        }
    }
}

struct MessagesDirectChat: Identifiable, Equatable, Codable, Sendable {
    let id: String
    let name: String
    let account: MessagesDirectAccount
}
struct MessagesDirectChatPage: Codable, Sendable {
    let chats: [MessagesDirectChat]
    let scanned: Int
    let total: Int
}
enum MessagesDirectRequest: Codable, Sendable {
    case accounts
    case chats(account: MessagesDirectAccount, query: String)
    case prepareSend(id: UUID, account: MessagesDirectAccount, address: String, plaintext: String)
    case send(proposal: MessagesDirectProposal, expectedDigest: String)
    case read(account: MessagesDirectAccount, chatID: String)
}
enum MessagesDirectResult: Codable, Sendable {
    case accounts(MessagesDirectAccountScan)
    case chats(MessagesDirectChatPage)
    case prepared(MessagesDirectProposal)
    case accepted(operationID: UUID)
    case unsupported(code: String, reason: String)
}
struct MessagesDirectReply: Codable, Sendable {
    let result: MessagesDirectResult
    let businessLogAvailable: Bool
}
extension MessagesDirectContract {
    static func address(_ value: String) throws {
        if (try? email(value)) != nil { return }
        guard value.range(of: #"^\+[1-9][0-9]{6,14}$"#, options: .regularExpression) == value.startIndex..<value.endIndex else {
            throw AppleDirectFault("explicit_address_required")
        }
    }
}
