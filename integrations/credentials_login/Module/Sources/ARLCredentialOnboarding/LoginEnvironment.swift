import Foundation
import Security
import Darwin

struct LoginSession { let target: Any; let path: String }
protocol LoginEnvironment: Sendable {
    func withSession<T>(_ body: (LoginSession) throws -> T) throws -> T
    func prepareAccess() throws -> (Any, [LoginACLSnapshot])
    func inspectACL(_ item: Any) throws -> [LoginACLSnapshot]
    func persistentReference(_ item: Any) throws -> Data
    func resolve(_ reference: Data) throws -> Any
    func parentPath(_ item: Any) throws -> String
}
protocol LoginItemCalls: SecurityItemCalls { func addReturning(_ attributes: [String: Any]) -> (OSStatus, Any?) }
struct SystemLoginItemCalls: LoginItemCalls {
    func copy(_ query: [String: Any]) -> (OSStatus, Any?) { SystemSecurityItemCalls().copy(query) }
    func add(_ attributes: [String: Any]) -> OSStatus { SystemSecurityItemCalls().add(attributes) }
    func addReturning(_ attributes: [String: Any]) -> (OSStatus, Any?) {
        var result: CFTypeRef?; let status = SecItemAdd(attributes as CFDictionary, &result); return (status, result)
    }
    func update(_ query: [String: Any], _ changes: [String: Any]) -> OSStatus { SystemSecurityItemCalls().update(query, changes) }
    func delete(_ query: [String: Any]) -> OSStatus { SystemSecurityItemCalls().delete(query) }
}
enum LoginPathPolicy {
    static func validate(_ path: String, home: String, unlocked: Bool) throws -> String {
        let directory = URL(fileURLWithPath: home).appendingPathComponent("Library/Keychains").path
        guard [directory + "/login.keychain-db", directory + "/login.keychain"].contains(path), unlocked else {
            throw CredentialError.storageUnavailable
        }
        return path
    }
}

/// No native work in init. Calls run serially with process interaction disabled and restored.
/// This is transient prompt suppression, never a Keychain permission/ACL/trust change.
final class NativeLoginEnvironment: LoginEnvironment, @unchecked Sendable {
    private static let interactionLock = NSLock()
    private let deployment: LoginCredentialDeployment
    init(deployment: LoginCredentialDeployment) { self.deployment = deployment }
    private func ok(_ status: OSStatus) throws { guard status == errSecSuccess else { throw CredentialStorageFailure(operation: .environment, status: status) } }
    func withSession<T>(_ body: (LoginSession) throws -> T) throws -> T {
        try Self.interactionLock.withLock {
            var prior: DarwinBoolean = false
            try ok(SecKeychainGetUserInteractionAllowed(&prior))
            try ok(SecKeychainSetUserInteractionAllowed(false))
            let result: Result<T, any Error>
            do {
                var candidate: SecKeychain?, state: SecKeychainStatus = 0
                try ok(SecKeychainCopyDomainDefault(.user, &candidate))
                guard let candidate, let home = getpwuid(getuid())?.pointee.pw_dir else { throw CredentialError.storageUnavailable }
                try ok(SecKeychainGetStatus(candidate, &state))
                let path = try LoginPathPolicy.validate(Self.path(candidate), home: String(cString: home),
                                                       unlocked: state & UInt32(kSecUnlockStateStatus) != 0)
                var metadata = stat()
                guard lstat(path, &metadata) == 0, metadata.st_uid == getuid(), metadata.st_mode & S_IFMT == S_IFREG
                else { throw CredentialError.storageUnavailable }
                result = .success(try body(.init(target: candidate, path: path)))
            } catch { result = .failure(error) }
            try ok(SecKeychainSetUserInteractionAllowed(prior.boolValue))
            return try result.get()
        }
    }
    private static func path(_ keychain: SecKeychain) throws -> String {
        var count: UInt32 = 4096, bytes = [CChar](repeating: 0, count: 4096)
        let status = SecKeychainGetPath(keychain, &count, &bytes)
        guard status == errSecSuccess else { throw CredentialStorageFailure(operation: .environment, status: status) }
        guard count < 4096 else { throw CredentialError.uncertainLocalState }
        return String(cString: bytes)
    }
    private func item(_ object: Any) throws -> SecKeychainItem {
        guard CFGetTypeID(object as CFTypeRef) == SecKeychainItemGetTypeID() else { throw CredentialError.uncertainLocalState }
        return object as! SecKeychainItem
    }
    func prepareAccess() throws -> (Any, [LoginACLSnapshot]) {
        let calls = NativeCredentialACL(deployment: deployment)
        let access = try LoginACLPolicy.prepare(reviewed: true, calls: calls)
        return (access, try calls.entries(access).map(calls.inspect))
    }
    func inspectACL(_ object: Any) throws -> [LoginACLSnapshot] {
        var access: SecAccess?
        try ok(SecKeychainItemCopyAccess(try item(object), &access))
        guard let access else { throw CredentialError.uncertainLocalState }
        let calls = NativeCredentialACL(deployment: deployment)
        return try calls.inspectStored(access)
    }
    func persistentReference(_ object: Any) throws -> Data {
        var value: CFData?; try ok(SecKeychainItemCreatePersistentReference(try item(object), &value))
        guard let value, CFDataGetLength(value) > 0, CFDataGetLength(value) <= 4096 else { throw CredentialError.uncertainLocalState }
        return value as Data
    }
    func resolve(_ reference: Data) throws -> Any {
        guard !reference.isEmpty, reference.count <= 4096 else { throw CredentialError.uncertainLocalState }
        var value: SecKeychainItem?; try ok(SecKeychainItemCopyFromPersistentReference(reference as CFData, &value))
        guard let value else { throw CredentialError.uncertainLocalState }; return value
    }
    func parentPath(_ object: Any) throws -> String {
        var parent: SecKeychain?; try ok(SecKeychainItemCopyKeychain(try item(object), &parent))
        guard let parent else { throw CredentialError.uncertainLocalState }; return try Self.path(parent)
    }
}

/// Restricts only fresh volatile objects. Stored access objects are inspected, never repaired.
final class NativeCredentialACL: LoginACLCalls {
    typealias Access = SecAccess
    typealias Entry = SecACL
    let deployment: LoginCredentialDeployment
    private var application: SecTrustedApplication?
    init(deployment: LoginCredentialDeployment) { self.deployment = deployment }
    private func ok(_ status: OSStatus) throws { guard status == errSecSuccess else { throw CredentialStorageFailure(operation: .accessMetadata, status: status) } }
    func verifySignedApplication() throws -> Data {
        try NativeLoginDeploymentGate(deployment: deployment).verify()
        var app: SecTrustedApplication?
        try deployment.bundleURL.path.withCString { try ok(SecTrustedApplicationCreateFromPath($0, &app)) }
        guard let app else { throw LoginACLFailure.invalidSignature }; application = app; return try pin(app)
    }
    func createAccessForOnlyVerifiedApplication() throws -> SecAccess {
        guard let application else { throw LoginACLFailure.invalidSignature }
        var access: SecAccess?
        try ok(SecAccessCreate("ARL · 本机服务凭据" as CFString, [application] as CFArray, &access))
        guard let access else { throw LoginACLFailure.unexpectedACL }; return access
    }
    func entries(_ access: SecAccess) throws -> [SecACL] {
        var values: CFArray?; try ok(SecAccessCopyACLList(access, &values))
        guard let values = values as? [SecACL], values.count <= 8 else { throw LoginACLFailure.unexpectedACL }; return values
    }
    /// Keychain adds integrity and partition constraints when it persists an item.
    /// Validate these separate OS constraints without editing them, then compare
    /// all three application access entries to the original prepared baseline.
    func inspectStored(_ access: SecAccess) throws -> [LoginACLSnapshot] {
        var result: [LoginACLSnapshot] = []
        var constraints: Set<LoginSystemConstraint.Kind> = []
        for entry in try entries(access) {
            let tags = SecACLCopyAuthorizations(entry) as? [String]
            let kind: LoginSystemConstraint.Kind?
            if tags == [kSecACLAuthorizationIntegrity as String] { kind = .integrity }
            else if tags == [kSecACLAuthorizationPartitionID as String] { kind = .partition }
            else { kind = nil }
            guard let kind else { result.append(try inspect(entry)); continue }
            var apps: CFArray?, label: CFString?, flags = SecKeychainPromptSelector(rawValue: 0)
            try ok(SecACLCopyContents(entry, &apps, &label, &flags))
            guard constraints.insert(kind).inserted, apps == nil, flags.rawValue == 0, let label else { throw LoginACLFailure.unexpectedACL }
            try LoginSystemConstraint.validate(kind, label: label as String, team: deployment.teamOU)
        }
        guard constraints == [.integrity, .partition], result.count == 3 else { throw LoginACLFailure.unexpectedACL }
        return result
    }
    func inspect(_ entry: SecACL) throws -> LoginACLSnapshot {
        var apps: CFArray?, label: CFString?, flags = SecKeychainPromptSelector(rawValue: 0)
        try ok(SecACLCopyContents(entry, &apps, &label, &flags))
        guard let tags = SecACLCopyAuthorizations(entry) as? [String], !tags.isEmpty, tags.count <= 12,
              tags.count == Set(tags).count, tags.allSatisfy({ Self.reverse[$0] != nil }),
              apps == nil || (apps as? [SecTrustedApplication]).map({ $0.count <= 1 }) == true else { throw LoginACLFailure.unexpectedACL }
        return .init(authorizations: Set(tags.compactMap { Self.reverse[$0] }),
                     applicationPins: try (apps as? [SecTrustedApplication])?.map(pin), promptFlags: flags.rawValue)
    }
    func restrict(_ entry: SecACL, authorizations: Set<LoginAuthorization>) throws {
        guard let application else { throw LoginACLFailure.invalidSignature }
        var apps: CFArray?, label: CFString?, flags = SecKeychainPromptSelector(rawValue: 0)
        try ok(SecACLCopyContents(entry, &apps, &label, &flags))
        guard let label else { throw LoginACLFailure.unexpectedACL }
        try ok(SecACLSetContents(entry, [application] as CFArray, label, flags))
        try ok(SecACLUpdateAuthorizations(entry, authorizations.map { Self.tags[$0]! } as CFArray))
    }
    private func pin(_ app: SecTrustedApplication) throws -> Data {
        var value: CFData?; try ok(SecTrustedApplicationCopyData(app, &value))
        guard let value, CFDataGetLength(value) <= 8192 else { throw LoginACLFailure.unexpectedACL }; return value as Data
    }
    private static let tags: [LoginAuthorization: String] = [
        .changeACL: kSecACLAuthorizationChangeACL as String, .encrypt: kSecACLAuthorizationEncrypt as String,
        .decrypt: kSecACLAuthorizationDecrypt as String, .sign: kSecACLAuthorizationSign as String,
        .mac: kSecACLAuthorizationMAC as String, .derive: kSecACLAuthorizationDerive as String,
        .exportClear: kSecACLAuthorizationExportClear as String, .exportWrapped: kSecACLAuthorizationExportWrapped as String,
        .delete: kSecACLAuthorizationDelete as String, .itemRead: kSecACLAuthorizationKeychainItemRead as String,
        .itemModify: kSecACLAuthorizationKeychainItemModify as String, .itemDelete: kSecACLAuthorizationKeychainItemDelete as String]
    private static let reverse = Dictionary(uniqueKeysWithValues: tags.map { ($0.value, $0.key) })
}
