import Foundation

struct CredentialPurpose: Equatable, Sendable {
    let service: String
    let purpose: String
    static let demo = Self(service: "demo.provider", purpose: "仅用于演示凭据流程")
}
struct CredentialReference: Identifiable, Equatable, Sendable {
    let id: UUID
    let service: String
    let purpose: String
}
protocol CredentialVault: Sendable {
    func save(dummyValue: String, for purpose: CredentialPurpose) async throws -> CredentialReference
    func removeLocally(_ reference: CredentialReference) async throws
}
/// This implementation never imports Security or reads/writes the system Keychain.
/// Only explicit dummy values are accepted. Removing a reference is not revocation.
actor InMemoryCredentialVault: CredentialVault {
    private var values: [UUID: String] = [:]
    func save(dummyValue: String, for purpose: CredentialPurpose) throws -> CredentialReference {
        guard purpose == .demo, dummyValue.hasPrefix("demo-"), dummyValue.utf8.count >= 6,
              dummyValue.utf8.count <= 256 else { throw ARLError(code: "dummy_credential_required") }
        let reference = CredentialReference(id: UUID(), service: purpose.service, purpose: purpose.purpose)
        values[reference.id] = dummyValue
        return reference
    }
    func removeLocally(_ reference: CredentialReference) throws { values.removeValue(forKey: reference.id) }
    func contains(_ reference: CredentialReference) -> Bool { values[reference.id] != nil }
}
