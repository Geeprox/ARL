import Foundation
import Security
import CryptoKit

@main enum PackageInspector {
    enum Failure: Error { case invalid }
    static func main() {
        do {
            guard CommandLine.arguments.count == 3 else { throw Failure.invalid }
            let url = URL(fileURLWithPath: CommandLine.arguments[1])
            var code: SecStaticCode?, rule: SecRequirement?, actual: SecRequirement?, raw: CFDictionary?, text: CFString?, data: CFData?
            guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
                  SecRequirementCreateWithString(CommandLine.arguments[2] as CFString, [], &rule) == errSecSuccess,
                  let code, let rule,
                  SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode), rule) == errSecSuccess,
                  SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &raw) == errSecSuccess,
                  SecCodeCopyDesignatedRequirement(code, [], &actual) == errSecSuccess, let actual,
                  SecRequirementCopyString(actual, [], &text) == errSecSuccess, let text,
                  SecRequirementCopyData(actual, [], &data) == errSecSuccess, let data,
                  let fields = raw as? [String: Any], let certificates = fields[kSecCodeInfoCertificates as String] as? [SecCertificate],
                  let leaf = certificates.first, let executable = Bundle(url: url)?.executableURL else { throw Failure.invalid }
            let entitlements = fields[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:]
            let expected = Set(["com.apple.security.automation.apple-events", "com.apple.security.personal-information.calendars"])
            guard Set(entitlements.keys) == expected,
                  entitlements.values.allSatisfy({ value in
                      guard let boolean = value as? NSNumber else { return false }
                      return CFGetTypeID(boolean) == CFBooleanGetTypeID() && boolean.boolValue
                  }),
                  Bundle(url: url)?.object(forInfoDictionaryKey: "NSCalendarsWriteOnlyAccessUsageDescription") as? String != nil,
                  Bundle(url: url)?.object(forInfoDictionaryKey: "NSCalendarsFullAccessUsageDescription") as? String == "查看日程并在确认后保存修改。",
                  Bundle(url: url)?.object(forInfoDictionaryKey: "NSRemindersFullAccessUsageDescription") as? String == "读取提醒事项，并在您确认操作后保存修改。",
                  Bundle(url: url)?.object(forInfoDictionaryKey: "NSCalendarsUsageDescription") == nil,
                  Bundle(url: url)?.object(forInfoDictionaryKey: "NSAppleEventsUsageDescription") as? String ==
                    "ARL 仅在您主动操作时连接备忘录和信息；访问范围及每次写入内容在应用内清楚显示。",
                  let flags = fields[kSecCodeInfoFlags as String] as? NSNumber,
                  flags.uint32Value & SecCodeSignatureFlags.runtime.rawValue != 0 else { throw Failure.invalid }
            let output: [String: Any] = ["status": "PASS", "identifier": fields[kSecCodeInfoIdentifier as String] as? String ?? "",
                "team": fields[kSecCodeInfoTeamIdentifier as String] as? String ?? "",
                "certificateSHA1": Insecure.SHA1.hash(data: SecCertificateCopyData(leaf) as Data).map { String(format: "%02X", $0) }.joined(),
                "designatedRequirement": text as String,
                "designatedRequirementSHA256": SHA256.hash(data: data as Data).map { String(format: "%02x", $0) }.joined(),
                "executableSHA256": SHA256.hash(data: try Data(contentsOf: executable)).map { String(format: "%02x", $0) }.joined(),
                "hardenedRuntime": true, "entitlements": entitlements, "entitlementsEmpty": false,
                "cdhash": (fields[kSecCodeInfoUnique as String] as? Data)?.map { String(format: "%02x", $0) }.joined() ?? ""]
            FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]))
        } catch {
            FileHandle.standardOutput.write(Data("{\"status\":\"HOLD\",\"failure\":\"static_signature_or_package_invariant\"}".utf8))
            exit(2)
        }
    }
}
