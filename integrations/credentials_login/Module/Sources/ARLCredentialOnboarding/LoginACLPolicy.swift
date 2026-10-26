import Foundation

enum LoginACLFailure: Error, Equatable, Sendable {
    case notReviewed, invalidSignature, unexpectedACL, malformedScope, locked, cancelled
}
/// OS-added constraints never replace or broaden the application's access ACL.
/// Their text stays local and is neither returned to the UI nor logged.
enum LoginSystemConstraint {
    enum Kind: Hashable { case integrity, partition }
    static func validate(_ kind: Kind, label: String, team: String) throws {
        let text = Array(label.utf8)
        guard !text.isEmpty, text.count <= 32768, text.count % 2 == 0,
              text.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else { throw LoginACLFailure.unexpectedACL }
        if kind == .integrity {
            guard text.count == 64 else { throw LoginACLFailure.unexpectedACL }; return
        }
        var bytes = Data()
        for index in stride(from: 0, to: text.count, by: 2) {
            guard let value = UInt8(String(decoding: text[index..<index+2], as: UTF8.self), radix: 16) else { throw LoginACLFailure.unexpectedACL }
            bytes.append(value)
        }
        guard let fields = try? PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any],
              Set(fields.keys) == ["Partitions"], let partitions = fields["Partitions"] as? [String], partitions.count == 1,
              let partition = partitions.first else { throw LoginACLFailure.unexpectedACL }
        let cdhash = partition.hasPrefix("cdhash:") ? String(partition.dropFirst(7)) : ""
        let codeHashConstraint = cdhash.utf8.count == 40 && cdhash.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }
        // A configured team must actually have its one stable team partition;
        // accepting a CDHash fallback would silently lose upgrade stability.
        guard team.isEmpty ? codeHashConstraint : partition == "teamid:" + team else { throw LoginACLFailure.unexpectedACL }
    }
}
enum LoginAuthorization: String, CaseIterable, Hashable, Codable, Sendable {
    case changeACL, encrypt, decrypt, sign, mac, derive, exportClear, exportWrapped
    case delete, itemRead, itemModify, itemDelete
}
struct LoginACLSnapshot: Equatable, Codable, Sendable {
    let authorizations: Set<LoginAuthorization>
    // nil means all applications; [] means no silently trusted application.
    let applicationPins: [Data]?
    let promptFlags: UInt16
}
protocol LoginACLCalls {
    associatedtype Access
    associatedtype Entry
    func verifySignedApplication() throws -> Data
    func createAccessForOnlyVerifiedApplication() throws -> Access
    func entries(_ access: Access) throws -> [Entry]
    func inspect(_ entry: Entry) throws -> LoginACLSnapshot
    // Edits only a newly allocated in-memory SecAccess; never an existing item.
    func restrict(_ entry: Entry, authorizations: Set<LoginAuthorization>) throws
}
enum LoginACLPolicy {
    static let sensitive: Set<LoginAuthorization> = [.decrypt, .sign, .mac, .derive, .exportClear, .exportWrapped, .delete, .itemRead, .itemModify, .itemDelete]
    static func prepare<C: LoginACLCalls>(reviewed: Bool, calls: C) throws -> C.Access {
        guard reviewed else { throw LoginACLFailure.notReviewed }
        let application = try calls.verifySignedApplication()
        let access = try calls.createAccessForOnlyVerifiedApplication()
        let entries = try calls.entries(access)
        guard entries.count == 3 else { throw LoginACLFailure.unexpectedACL }
        var owner: LoginACLSnapshot?
        var safeCount = 0, sensitiveCount = 0
        var safeFlags: UInt16?, sensitiveFlags: UInt16?
        for entry in entries {
            let acl = try calls.inspect(entry)
            if acl.authorizations == [.changeACL] {
                guard owner == nil, acl.applicationPins == [] else { throw LoginACLFailure.unexpectedACL }
                owner = acl // Preserve the owner entry and all native prompt flags unchanged.
            } else if acl.authorizations == [.encrypt] {
                safeCount += 1
                safeFlags = acl.promptFlags
                try calls.restrict(entry, authorizations: [.encrypt])
            } else {
                guard !acl.authorizations.isEmpty, acl.authorizations.isSubset(of: sensitive),
                      acl.applicationPins == [application] else { throw LoginACLFailure.unexpectedACL }
                sensitiveCount += 1
                sensitiveFlags = acl.promptFlags
                try calls.restrict(entry, authorizations: sensitive)
            }
        }
        guard let owner, safeCount == 1, sensitiveCount == 1 else { throw LoginACLFailure.unexpectedACL }
        let verifiedEntries = try calls.entries(access)
        let final = try verifiedEntries.map(calls.inspect)
        let expected = [Set([LoginAuthorization.changeACL]), Set([.encrypt]), sensitive]
        guard final.count == 3, expected.allSatisfy({ tags in final.filter { $0.authorizations == tags }.count == 1 }),
              final.contains(owner),
              final.first(where: { $0.authorizations == [.encrypt] })?.promptFlags == safeFlags,
              final.first(where: { $0.authorizations == sensitive })?.promptFlags == sensitiveFlags,
              final.filter({ $0.authorizations != [.changeACL] }).allSatisfy({ $0.applicationPins == [application] }) else {
            throw LoginACLFailure.unexpectedACL
        }
        return access // Not persisted. Authorization tags alone do not prove native mutation isolation.
    }
}
