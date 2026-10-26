import Foundation

/// Short-lived input/lease, deliberately neither Codable nor Equatable. Swift/OS copies prevent a complete zeroization guarantee.
public final class CredentialInput: @unchecked Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let purpose: CredentialPurpose
    private let lock = NSLock()
    private var bytes: Data
    public init(purpose: CredentialPurpose, value: String) throws {
        guard purpose.isTravel else { throw CredentialError.wrongPurpose }
        let data = Data(value.utf8)
        guard (8...2048).contains(data.count), value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.hasPrefix("Bearer "), data.allSatisfy({ (33...126).contains($0) }), !value.contains("\""), !value.contains("\\") else { throw CredentialError.invalidInput }
        self.purpose = purpose; bytes = data
    }
    init(purpose: CredentialPurpose, data: Data) throws {
        if purpose == .neteaseMusic { try MusicEnvelope.validate(data) }
        else if purpose == .nasSMB { try NASEnvelope.validate(data) }
        else {
            guard let value = String(data: data, encoding: .utf8) else { throw CredentialError.invalidInput }
            try Self.validate(data, value: value)
        }
        self.purpose = purpose; bytes = data
    }
    public convenience init(neteaseAppID: String, privateKey: String) throws {
        let data = try MusicEnvelope.seed(appID: neteaseAppID, privateKey: privateKey)
        try self.init(purpose: .neteaseMusic, data: data)
    }
    private static func validate(_ data: Data, value: String) throws {
        guard (8...2048).contains(data.count), data.allSatisfy({ (33...126).contains($0) }), !value.hasPrefix("Bearer "), !value.contains("\""), !value.contains("\\") else { throw CredentialError.invalidInput }
    }
    func copyBytes(for purpose: CredentialPurpose) throws -> Data {
        try lock.withLock { guard self.purpose == purpose else { throw CredentialError.wrongPurpose }; guard !bytes.isEmpty else { throw CredentialError.invalidInput }; return bytes }
    }
    public func clear() { lock.withLock { if !bytes.isEmpty { bytes.resetBytes(in: 0..<bytes.count) }; bytes.removeAll(keepingCapacity: false) } }
    deinit { clear() }
    public var description: String { "CredentialInput(<redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}
