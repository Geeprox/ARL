import Foundation
import Security

struct NotesV2ObservedIdentity {
    let signingID: String
    let executableSHA256: String
    let requirementSHA256: String
    let cdhash: String
    var requirement: String { "cdhash H\"" + cdhash + "\"" }
    var object: [String: Any] { ["helper_bundle_id": signingID, "executable_sha256": executableSHA256,
        "designated_requirement_sha256": requirementSHA256, "cdhash": cdhash] }
    static func inspect(_ url: URL) throws -> Self {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess else { throw NativeFault("helper_modified") }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, [], &info) == errSecSuccess, let info = info as? [String: Any],
              let id = info[kSecCodeInfoIdentifier as String] as? String,
              let executable = info[kSecCodeInfoMainExecutable as String] as? URL,
              let hash = info[kSecCodeInfoUnique as String] as? Data, hash.count == 20 else { throw NativeFault("helper_modified") }
        var rule: SecRequirement?; var raw: CFData?
        guard SecCodeCopyDesignatedRequirement(code, [], &rule) == errSecSuccess, let rule,
              SecRequirementCopyData(rule, [], &raw) == errSecSuccess, let raw else { throw NativeFault("helper_modified") }
        return .init(signingID: id, executableSHA256: digest(try Data(contentsOf: executable)), requirementSHA256: digest(raw as Data),
                     cdhash: hash.map { String(format: "%02x", $0) }.joined())
    }
    static func inspectConfiguration(_ url: URL) throws -> [String: Any] {
        // Code-signing facts only; this never asks the OS about Automation.
        _ = try inspect(url)
        var code: SecStaticCode?; var raw: CFDictionary?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &raw) == errSecSuccess,
              let info = raw as? [String: Any] else { throw NativeFault("helper_modified") }
        let entitlements = info[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:]
        func boolean(_ name: String) -> Any {
            guard let value = entitlements[name] else { return NSNull() }
            guard let value = value as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { return "invalid_type" }
            return value.boolValue
        }
        let plist = info[kSecCodeInfoPList as String] as? [String: Any] ?? [:]
        return ["automation_entitlement": boolean("com.apple.security.automation.apple-events"),
                "app_sandbox_entitlement": boolean("com.apple.security.app-sandbox"),
                "secured_usage_description": plist["NSAppleEventsUsageDescription"] as? String ?? "",
                "code_signing_flags": (info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0,
                "os_responsible_identity_verified": false, "permission_queries": 0, "notes_events_sent": 0]
    }
}
