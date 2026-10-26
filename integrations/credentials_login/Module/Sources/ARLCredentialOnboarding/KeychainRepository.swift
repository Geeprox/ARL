import Foundation
import Security
import LocalAuthentication

protocol DeploymentGate: Sendable { func verify() throws }
struct CredentialCreation: Sendable { let metadata: StoredMetadata; let recoveredExisting: Bool }
protocol CredentialRepository: Sendable {
    func metadata(_ purpose: CredentialPurpose) throws -> StoredMetadata?
    func create(_ input: CredentialInput, purpose: CredentialPurpose) throws -> StoredMetadata
    func createRecovering(_ input: CredentialInput, purpose: CredentialPurpose) throws -> CredentialCreation
    func replace(_ ref: CredentialReference, input: CredentialInput) throws -> StoredMetadata
    func installVerifiedTravel(_ input: CredentialInput, result: ConnectionTestResult, expected: StoredMetadata?) throws -> StoredMetadata
    func recoverTravelMetadata(_ purpose: CredentialPurpose) throws -> StoredMetadata?
    func commitLease(_ ref: CredentialReference, input: CredentialInput, result: ConnectionTestResult?, expectedGeneration: UUID) throws -> StoredMetadata
    func lease(_ ref: CredentialReference) throws -> (metadata: StoredMetadata, secret: CredentialInput)
    func record(_ ref: CredentialReference, result: ConnectionTestResult, expectedGeneration: UUID) throws -> StoredMetadata
    func remove(_ ref: CredentialReference) throws
}
extension CredentialRepository {
    func installVerifiedTravel(_ input: CredentialInput, result: ConnectionTestResult, expected: StoredMetadata?) throws -> StoredMetadata { input.clear(); throw CredentialError.deploymentNotApproved }
    func recoverTravelMetadata(_ purpose: CredentialPurpose) throws -> StoredMetadata? { try metadata(purpose) }
    func createRecovering(_ input: CredentialInput, purpose: CredentialPurpose) throws -> CredentialCreation {
        .init(metadata: try create(input, purpose: purpose), recoveredExisting: false)
    }
    func commitLease(_ ref: CredentialReference, input: CredentialInput, result: ConnectionTestResult?, expectedGeneration: UUID) throws -> StoredMetadata { input.clear(); throw CredentialError.deploymentNotApproved }
}
protocol SecurityItemCalls: Sendable {
    func copy(_ query: [String: Any]) -> (OSStatus, Any?)
    func add(_ attributes: [String: Any]) -> OSStatus
    func update(_ query: [String: Any], _ changes: [String: Any]) -> OSStatus
    func delete(_ query: [String: Any]) -> OSStatus
}
struct SystemSecurityItemCalls: SecurityItemCalls {
    func copy(_ query: [String: Any]) -> (OSStatus, Any?) { var result: CFTypeRef?; let status = SecItemCopyMatching(query as CFDictionary, &result); return (status, result) }
    func add(_ attributes: [String: Any]) -> OSStatus { SecItemAdd(attributes as CFDictionary, nil) }
    func update(_ query: [String: Any], _ changes: [String: Any]) -> OSStatus { SecItemUpdate(query as CFDictionary, changes as CFDictionary) }
    func delete(_ query: [String: Any]) -> OSStatus { SecItemDelete(query as CFDictionary) }
}
struct StoredMetadata: Codable, Equatable, Sendable {
    let schema: Int
    let reference: CredentialReference
    let generation: UUID
    let state: ConnectionState
    let lastTest: ConnectionTestResult?
    init(reference: CredentialReference, state: ConnectionState = .savedUnverified, lastTest: ConnectionTestResult? = nil) { schema = 1; self.reference = reference; generation = UUID(); self.state = state; self.lastTest = lastTest }
    var isConsistent: Bool {
        if state == .savedUnverified { return lastTest == nil }
        guard let lastTest, lastTest.state == state else { return false }
        if state == .verified {
            let evidenceMatches = reference.purpose == .neteaseMusic ? lastTest.evidence == .neteasePlaylistReadResponse : reference.purpose == .amapMapsWeather ? lastTest.evidence == .amapWeatherResponse :
                [ValidationEvidence.flyaiReadOnlyResponse, .flyaiDifferentialReadOnlyResponse].contains(lastTest.evidence)
            return evidenceMatches && lastTest.expiryKnowledge == .unknown
        }
        return lastTest.evidence == .none && state != .notConfigured && state != .revalidationRequired
    }
    var snapshot: CredentialSnapshot { .init(purpose: reference.purpose, reference: reference, state: state, lastTest: lastTest) }
}
/// Exact two purpose slots in a new private DP access group. No legacy login/search-list/ACL fallback.
final class KeychainRepository: CredentialRepository, @unchecked Sendable {
    private let gate: any DeploymentGate
    private let calls: any SecurityItemCalls
    private let accessGroup: String
    private let authenticationContext: @Sendable () -> Any
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    init(gate: any DeploymentGate, calls: any SecurityItemCalls, accessGroup: String, authenticationContext: @escaping @Sendable () -> Any = {
        let context = LAContext(); context.interactionNotAllowed = true; return context
    }) {
        self.gate = gate; self.calls = calls; self.accessGroup = accessGroup; self.authenticationContext = authenticationContext
        encoder.outputFormatting = [.sortedKeys]
    }
    func query(_ purpose: CredentialPurpose) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: purpose.service,
         kSecAttrAccount as String: purpose.account, kSecAttrAccessGroup as String: accessGroup,
         kSecUseDataProtectionKeychain as String: true, kSecAttrSynchronizable as String: false,
         kSecUseAuthenticationContext as String: authenticationContext()]
    }
    private func status(_ status: OSStatus) throws {
        if status == errSecItemNotFound { throw CredentialError.missing }
        if status == errSecDuplicateItem { throw CredentialError.alreadyConfigured }
        guard status == errSecSuccess else { throw CredentialError.storageUnavailable }
    }
    func metadata(_ purpose: CredentialPurpose) throws -> StoredMetadata? {
        try gate.verify()
        var q = query(purpose); q[kSecMatchLimit as String] = kSecMatchLimitOne
        q[kSecReturnAttributes as String] = true; q[kSecReturnData as String] = false
        q[kSecReturnRef as String] = false; q[kSecReturnPersistentRef as String] = false
        let (s, value) = calls.copy(q); if s == errSecItemNotFound { return nil }; try status(s)
        guard let attrs = value as? [String: Any], attrs[kSecAttrService as String] as? String == purpose.service,
              attrs[kSecAttrAccount as String] as? String == purpose.account,
              let raw = attrs[kSecAttrGeneric as String] as? Data, raw.count <= 4096,
              let m = try? decoder.decode(StoredMetadata.self, from: raw), m.schema == 1, m.reference.purpose == purpose, m.isConsistent else { throw CredentialError.uncertainLocalState }
        return m
    }
    private func owned(_ ref: CredentialReference) throws -> StoredMetadata {
        guard let m = try metadata(ref.purpose) else { throw CredentialError.missing }
        guard m.reference == ref else { throw CredentialError.staleReference }; return m
    }
    private func exact(_ m: StoredMetadata) throws -> [String: Any] { var q = query(m.reference.purpose); q[kSecAttrGeneric as String] = try encoder.encode(m); return q }
    func create(_ input: CredentialInput, purpose: CredentialPurpose) throws -> StoredMetadata {
        defer { input.clear() }
        guard input.purpose == purpose else { throw CredentialError.wrongPurpose }
        try gate.verify(); guard try metadata(purpose) == nil else { throw CredentialError.alreadyConfigured }
        let m = StoredMetadata(reference: .init(purpose: purpose)); var attrs = query(purpose)
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        attrs[kSecAttrLabel as String] = "ARL · " + purpose.title
        attrs[kSecAttrGeneric as String] = try encoder.encode(m); attrs[kSecValueData as String] = try input.copyBytes(for: purpose)
        try status(calls.add(attrs)); return m
    }
    func replace(_ ref: CredentialReference, input: CredentialInput) throws -> StoredMetadata {
        defer { input.clear() }; guard input.purpose == ref.purpose else { throw CredentialError.wrongPurpose }
        let old = try owned(ref); let updated = StoredMetadata(reference: ref)
        try status(calls.update(try exact(old), [kSecValueData as String: try input.copyBytes(for: ref.purpose), kSecAttrGeneric as String: try encoder.encode(updated)]))
        return updated
    }
    func lease(_ ref: CredentialReference) throws -> (metadata: StoredMetadata, secret: CredentialInput) {
        let m = try owned(ref); var q = try exact(m); q[kSecMatchLimit as String] = kSecMatchLimitOne
        q[kSecReturnData as String] = true; q[kSecReturnAttributes as String] = false; q[kSecReturnRef as String] = false; q[kSecReturnPersistentRef as String] = false
        let (s, value) = calls.copy(q); try status(s)
        guard let data = value as? Data, data.count <= ref.purpose.maximumCredentialBytes else { throw CredentialError.uncertainLocalState }
        return (m, try CredentialInput(purpose: ref.purpose, data: data))
    }
    func record(_ ref: CredentialReference, result: ConnectionTestResult, expectedGeneration: UUID) throws -> StoredMetadata {
        if ref.purpose == .fliggyTravelReadOnly, result.state == .verified, result.evidence != .flyaiDifferentialReadOnlyResponse { throw CredentialError.uncertainLocalState }
        let old = try owned(ref); guard old.generation == expectedGeneration else { throw CredentialError.staleReference }; let updated = StoredMetadata(reference: ref, state: result.state, lastTest: result)
        guard updated.isConsistent else { throw CredentialError.uncertainLocalState }
        try status(calls.update(try exact(old), [kSecAttrGeneric as String: try encoder.encode(updated)])); return updated
    }
    func remove(_ ref: CredentialReference) throws {
        guard let m = try metadata(ref.purpose) else { return }
        guard m.reference == ref else { throw CredentialError.staleReference }
        try status(calls.delete(try exact(m)))
    }
}
