import Foundation
import CoreFoundation

/// Private Keychain value. Never a public snapshot, log entry or generic RPC body.
enum MusicEnvelope {
    static let limit = 131072
    static let names: Set<String> = [".netease_mcp_device.json", ".config/ncm-cli/config.json",
        ".config/ncm-cli/credentials.enc.json", ".config/ncm-cli/tokens.enc.json"]
    private static func isASCIIHex(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
    }
    static func seed(appID: String, privateKey: String) throws -> Data {
        let object: [String: Any] = ["schema": 1, "storage": "seed", "app_id": appID,
                                    "private_key": privateKey, "device_id": UUID().uuidString]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try validate(data); return data
    }
    static func validate(_ data: Data, requireOfficial: Bool = false) throws {
        guard !data.isEmpty, data.count <= limit,
              let object = try? MusicStrictJSON.object(data, limit: limit),
              let version = object["schema"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(), version.doubleValue == 1
        else { throw CredentialError.invalidInput }
        if object["storage"] as? String == "seed" {
            guard !requireOfficial, Set(object.keys) == ["schema","storage","app_id","private_key","device_id"],
                  let appID = object["app_id"] as? String, (1...256).contains(appID.utf8.count),
                  appID.utf8.allSatisfy({ (33...126).contains($0) }),
                  let key = object["private_key"] as? String, (32...16384).contains(key.utf8.count),
                  key.utf8.allSatisfy({ $0 == 10 || $0 == 13 || (32...126).contains($0) }),
                  let device = object["device_id"] as? String, UUID(uuidString: device) != nil
            else { throw CredentialError.invalidInput }
        } else {
            guard Set(object.keys) == ["schema","storage","files"], object["storage"] as? String == "official",
                  let files = object["files"] as? [String: String], Set(files.keys).isSubset(of: names),
                  files[".netease_mcp_device.json"] != nil, files[".config/ncm-cli/credentials.enc.json"] != nil
            else { throw CredentialError.invalidInput }
            var total = 0
            for (name, value) in files {
                guard let bytes = Data(base64Encoded: value), bytes.base64EncodedString() == value,
                      !bytes.isEmpty, bytes.count <= 65536,
                      let object = try? MusicStrictJSON.object(bytes, limit: 65536)
                else { throw CredentialError.invalidInput }
                total += bytes.count
                if name.hasSuffix(".enc.json") {
                    guard Set(object.keys) == ["iv","data"], let iv = object["iv"] as? String,
                          iv.count == 32, iv.utf8.allSatisfy(isASCIIHex),
                          let payload = object["data"] as? String, !payload.isEmpty,
                          payload.count % 32 == 0, payload.utf8.allSatisfy(isASCIIHex)
                    else { throw CredentialError.invalidInput }
                } else if name.hasSuffix("config.json") {
                    guard Set(object.keys).isDisjoint(with: ["appId","privateKey","accessToken","refreshToken"])
                    else { throw CredentialError.invalidInput }
                } else {
                    guard let device = object["deviceId"] as? String, UUID(uuidString: device) != nil
                    else { throw CredentialError.invalidInput }
                }
            }
            guard total <= limit else { throw CredentialError.invalidInput }
        }
    }
}
