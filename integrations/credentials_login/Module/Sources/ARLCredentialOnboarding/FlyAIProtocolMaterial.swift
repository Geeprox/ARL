import Foundation

/// Public transport signing material shipped in official @fly-ai/flyai-cli 1.0.16.
/// This is not an entered API credential, certificate or local Keychain secret.
/// Source archive/bundle hashes and license provenance are pinned in the host docs.
enum FlyAIProtocolMaterial {
    static let signingBytes = Data("XSbdYnucPARDc9knhD8+X6hxdD1Nh6ZGI6Hadg25kBw=".utf8)
    static let clientTag = "ai2c(sk.clawhub)"
}
