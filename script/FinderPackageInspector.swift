import Foundation
import Security
import CryptoKit

@main enum FinderPackageInspector {
    enum Failure: Error { case invalid }
    static func main() {
        do {
            guard CommandLine.arguments.count == 3 else { throw Failure.invalid }
            let url = URL(fileURLWithPath: CommandLine.arguments[1])
            let identifier = "local.arl.control.finderactions"
            let expectedEntitlements: Set<String> = ["com.apple.security.app-sandbox", "com.apple.security.files.user-selected.read-only"]
            var code: SecStaticCode?, rule: SecRequirement?, actual: SecRequirement?, raw: CFDictionary?
            var expectedRuleData: CFData?, actualRuleData: CFData?
            guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
                  SecRequirementCreateWithString(CommandLine.arguments[2] as CFString, [], &rule) == errSecSuccess, let rule,
                  SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode), rule) == errSecSuccess,
                  SecCodeCopyDesignatedRequirement(code, [], &actual) == errSecSuccess, let actual,
                  SecRequirementCopyData(rule, [], &expectedRuleData) == errSecSuccess,
                  SecRequirementCopyData(actual, [], &actualRuleData) == errSecSuccess,
                  let expectedRuleData, let actualRuleData,
                  expectedRuleData as Data == actualRuleData as Data,
                  SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &raw) == errSecSuccess,
                  let fields = raw as? [String: Any], fields[kSecCodeInfoIdentifier as String] as? String == identifier,
                  let entitlements = fields[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
                  Set(entitlements.keys) == expectedEntitlements,
                  expectedEntitlements.allSatisfy({ key in
                      guard let value = entitlements[key] as? NSNumber else { return false }
                      return CFGetTypeID(value) == CFBooleanGetTypeID() && value.boolValue
                  }),
                  let flags = fields[kSecCodeInfoFlags as String] as? NSNumber,
                  flags.uint32Value & SecCodeSignatureFlags.runtime.rawValue != 0,
                  let bundle = Bundle(url: url), bundle.bundleIdentifier == identifier,
                  bundle.object(forInfoDictionaryKey: "CFBundlePackageType") as? String == "XPC!",
                  let specification = bundle.object(forInfoDictionaryKey: "NSExtension") as? [String: Any],
                  specification["NSExtensionPointIdentifier"] as? String == "com.apple.FinderSync",
                  specification["NSExtensionPrincipalClass"] as? String == "ARLFinderActions",
                  let executable = bundle.executableURL else { throw Failure.invalid }
            let result: [String: Any] = ["status": "PASS", "identifier": identifier,
                "entitlements": entitlements, "hardenedRuntime": true,
                "executableSHA256": SHA256.hash(data: try Data(contentsOf: executable)).map { String(format: "%02x", $0) }.joined(),
                "system_enable_performed": false]
            FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]))
        } catch {
            FileHandle.standardOutput.write(Data("{\"status\":\"HOLD\",\"failure\":\"finder_signature_or_package_invariant\"}".utf8))
            exit(2)
        }
    }
}
