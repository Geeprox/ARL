import Foundation
// Account handle only; the projection/cache test never leases credentials.
enum CredentialPurpose:Sendable {case neteaseMusic}
struct CredentialReference:Hashable,Sendable {let id=UUID();init(purpose:CredentialPurpose){}}
