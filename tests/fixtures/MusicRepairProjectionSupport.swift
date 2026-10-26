import Foundation
// Test-only dependency types. No repository, process, provider, or Keychain API.
// All DTOs, validators, diagnostic decoding, and recovery logic are real sources.
enum CredentialError: Error { case invalidInput, uncertainLocalState, deploymentNotApproved, storageUnavailable }
struct CredentialInput: Sendable {}
enum MusicReadRuntimeFailure: Error { case cleanupUnproven }
enum TransportFailure: Error { case timeout }
enum MusicLoginRuntimeFailure: Error { case runtimeExited, expired }
struct CredentialStorageFailure: Error {}
struct LoginACLFailure: Error {}

// Non-exercised dependency of the complete MusicReadResult source.
enum ConnectionState { case sessionPresentUnverified, loginRequired, credentialUnconfirmed, protocolFailure, networkUnavailable }
