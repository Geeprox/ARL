import Foundation
import CryptoKit

/// Login targets a server. This value contains no share, directory or read grant.
public struct NASServerEndpoint: Codable, Equatable, Sendable {
    public let sourceRef: String
    public let host: String
    public let port: Int
    public let timeoutSeconds: Int
    public let generation: UInt64
    public init(sourceRef: String, host: String, port: Int = 445, timeoutSeconds: Int = 8, generation: UInt64 = 1) throws {
        guard (1...128).contains(sourceRef.utf8.count), sourceRef.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45,95].contains($0) }),
              (1...253).contains(host.utf8.count), host.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45,46].contains($0) }),
              (1...65535).contains(port), (1...30).contains(timeoutSeconds), generation > 0, generation <= UInt64(Int64.max)
        else { throw CredentialError.invalidInput }
        self.sourceRef = sourceRef; self.host = host; self.port = port
        self.timeoutSeconds = timeoutSeconds; self.generation = generation
    }
    public var fingerprint: String {
        let data = try! JSONEncoder().encode(["nas-server-v2", "smb", host.lowercased(), String(port), "encryption-required"])
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    func validated() throws -> Self {
        try .init(sourceRef: sourceRef, host: host, port: port, timeoutSeconds: timeoutSeconds, generation: generation)
    }
    func scopeJSON(identity: NASCredentialIdentity, target: [String: String] = [:]) throws -> Data {
        _ = try validated()
        guard identity.reference.purpose == .nasSMB else { throw CredentialError.wrongPurpose }
        return try JSONSerialization.data(withJSONObject: ["purpose":"server_metadata_only",
            "source_ref":sourceRef,"credential_ref":identity.reference.id.uuidString.lowercased(),
            "credential_generation":identity.generation.uuidString.replacingOccurrences(of:"-",with:"").lowercased(),
            "config_generation":generation,"endpoint_fingerprint":fingerprint,"metadata_target":target], options:[.sortedKeys])
    }
}

public struct NASShareRecord: Equatable, Sendable, Codable, Identifiable {
    public let name: String
    public var id: String { name }
    public init(name: String) throws {
        guard !name.isEmpty, name.utf8.count <= 255,
              !name.contains(where: { $0 == "/" || $0 == "\\" || $0.isNewline }),
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { throw CredentialError.invalidInput }
        self.name = name
    }
}

public struct NASServerState: Equatable, Sendable {
    public let authenticated: Bool
    public let epoch: String?
    public let shares: [NASShareRecord]
    public let nextCursor: String?
    public let failure: String?
    public init(authenticated: Bool = false, epoch: String? = nil, shares: [NASShareRecord] = [], nextCursor: String? = nil, failure: String? = nil) {
        self.authenticated = authenticated; self.epoch = epoch; self.shares = shares
        self.nextCursor = nextCursor; self.failure = failure
    }
}
