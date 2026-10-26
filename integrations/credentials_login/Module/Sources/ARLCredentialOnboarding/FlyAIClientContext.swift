import Foundation
import CryptoKit
import Darwin
import FlyAICompression

/// Independent native implementation of the public CLI's gzip + version-byte/AES-GCM context framing.
/// Reports truthful native client facts; never reads CLI config, a saved device ID, environment keys or user credentials.
enum FlyAIClientContext {
    static let userAgent = "ARLCredentialSetup/1.0.0 (native macOS; FlyAI transport 1.0.16)"
    static func plaintext() throws -> Data {
        let process = ProcessInfo.processInfo
        let gigabytes = Double(process.physicalMemory) / 1_073_741_824
        let tier = [2, 4, 8, 16, 32].first { gigabytes <= Double($0) } ?? 32
        let language = String(Locale.current.language.languageCode?.identifier.prefix(8) ?? "en")
        var system = utsname(); uname(&system)
        let release = withUnsafeBytes(of: system.release) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x64"
        #endif
        // Fresh per profile assembly; no existing CLI device-ID or stable hardware identifier is consulted.
        let deviceID = SHA256.hash(data: Data(UUID().uuidString.utf8)).map { String(format: "%02x", $0) }.joined()
        return try JSONSerialization.data(withJSONObject: [
            "machine": ["platform": "darwin", "arch": architecture, "cpus": process.processorCount,
                        "memoryTierGB": tier, "osType": "Darwin", "nodeVersion": "native",
                        "osReleaseMajor": String(release.split(separator: ".").first ?? "0")],
            "fingerprint": ["language": language, "platform": "Macintosh", "userAgent": userAgent,
                            "hardwareConcurrency": process.processorCount, "deviceMemory": min(8, max(2, tier)),
                            "clientSurface": "native", "timezoneOffset": TimeZone.current.secondsFromGMT() / 60,
                            "deviceId": deviceID]
        ], options: [.sortedKeys])
    }
    static func encode(_ plaintext: Data, signingMaterial: Data) throws -> String {
        guard !plaintext.isEmpty, plaintext.count <= 8192 else { throw CredentialError.invalidInput }
        var output = [UInt8](repeating: 0, count: 16384)
        let capacity = output.count
        let count = plaintext.withUnsafeBytes { bytes in
            arl_gzip(bytes.bindMemory(to: UInt8.self).baseAddress, plaintext.count, &output, capacity)
        }
        guard count > 0 else { throw CredentialError.invalidInput }
        let seal = try AES.GCM.seal(Data(output.prefix(count)), using: SymmetricKey(data: Data(SHA256.hash(data: signingMaterial))))
        return (Data([1]) + Data(seal.nonce) + seal.ciphertext + seal.tag).base64EncodedString()
    }
}
