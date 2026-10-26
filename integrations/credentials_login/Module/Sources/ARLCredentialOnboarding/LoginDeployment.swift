import Foundation
import Security
import CryptoKit

/// Final externally reviewed values. The stable requirement binds updates to the same
/// identifier and certificate; each update also needs its own reviewed executable hash.
public enum LoginCredentialIdentityRoute: String, Sendable { case developerID, localCodeCertificate, appleDevelopmentTeam }

public struct LoginCredentialDeployment: Sendable {
    public let identityRoute: LoginCredentialIdentityRoute
    public let bundleURL: URL
    public let identifier: String
    public let certificateSHA1: String
    public let teamOU: String
    public let designatedRequirement: String
    public let reviewedArtifactSHA256: String
    public init(bundleURL: URL, identifier: String, certificateSHA1: String, teamOU: String,
                designatedRequirement: String, reviewedArtifactSHA256: String, identityRoute: LoginCredentialIdentityRoute = .developerID) {
        self.identityRoute = identityRoute
        self.bundleURL = bundleURL; self.identifier = identifier; self.certificateSHA1 = certificateSHA1
        self.teamOU = teamOU; self.designatedRequirement = designatedRequirement
        self.reviewedArtifactSHA256 = reviewedArtifactSHA256
    }
    var stableIdentity: String {
        let fields = [identifier, certificateSHA1.uppercased(), teamOU, designatedRequirement] + (identityRoute == .developerID ? [] : [identityRoute.rawValue])
        return SHA256.hash(data: Data(fields.joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
    }
    var itemScope: LoginItemScope { identityRoute == .appleDevelopmentTeam ? .teamReentryV1 : .original }
    var receiptDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/ARL/CredentialsLogin")
            .appendingPathComponent(stableIdentity, isDirectory: true)
    }
}

struct NativeLoginDeploymentGate: DeploymentGate {
    let deployment: LoginCredentialDeployment
    static let teamCertificateSHA1 = "CD85BA24208488935F9AC0BEC63E4BE6AAE189C4"
    static let teamOU = "LGZF25R84Z"
    static let teamRequirement = "identifier \"local.arl.control\" and anchor apple generic and certificate leaf = H\"CD85BA24208488935F9AC0BEC63E4BE6AAE189C4\" and certificate leaf[subject.OU] = \"LGZF25R84Z\" and certificate 1[field.1.2.840.113635.100.6.2.1] exists and certificate leaf[field.1.2.840.113635.100.6.1.12] exists"
    private func ok(_ status: OSStatus) throws { guard status == errSecSuccess else { throw CredentialError.identityMismatch } }
    func verify() throws {
        let p = deployment
        let local = p.identityRoute == .localCodeCertificate
        let team = p.identityRoute == .appleDevelopmentTeam
        if team {
            guard p.identifier == "local.arl.control", p.certificateSHA1.uppercased() == Self.teamCertificateSHA1,
                  p.teamOU == Self.teamOU else { throw CredentialError.identityMismatch }
        }
        if local {
            guard p.identifier == "local.arl.control", p.certificateSHA1.uppercased() == "859332B7FFFBBBB33B80C7B78D30C27D2D81583F", p.teamOU.isEmpty
            else { throw CredentialError.identityMismatch }
        }
        guard p.bundleURL.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL,
              ["local.arl.credential-onboarding", "local.arl.control"].contains(p.identifier),
              p.certificateSHA1.count == 40, p.certificateSHA1.allSatisfy({ $0.isHexDigit }),
              p.reviewedArtifactSHA256.count == 64, p.reviewedArtifactSHA256.allSatisfy({ $0.isHexDigit }),
              (local || !p.teamOU.isEmpty), !p.designatedRequirement.isEmpty,
              let executable = Bundle.main.executableURL,
              let attributes = try? executable.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              attributes.isRegularFile == true, attributes.isSymbolicLink != true,
              let bytes = try? Data(contentsOf: executable, options: .mappedIfSafe),
              SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == p.reviewedArtifactSHA256.lowercased()
        else { throw CredentialError.deploymentNotApproved }
        var code: SecStaticCode?, requirement: SecRequirement?, info: CFDictionary?, actual: SecRequirement?, text: CFString?
        try ok(SecStaticCodeCreateWithPath(p.bundleURL as CFURL, [], &code))
        try ok(SecRequirementCreateWithString(p.designatedRequirement as CFString, [], &requirement))
        guard let code, let requirement else { throw CredentialError.identityMismatch }
        try ok(SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode), requirement))
        var running: SecCode?
        try ok(SecCodeCopySelf([], &running))
        guard let running else { throw CredentialError.identityMismatch }
        try ok(SecCodeCheckValidity(running, [], requirement))
        if team {
            var exactTeam: SecRequirement?
            try ok(SecRequirementCreateWithString(Self.teamRequirement as CFString, [], &exactTeam))
            guard let exactTeam else { throw CredentialError.identityMismatch }
            try ok(SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode), exactTeam))
            try ok(SecCodeCheckValidity(running, [], exactTeam))
        }
        try ok(SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info))
        try ok(SecCodeCopyDesignatedRequirement(code, [], &actual))
        guard let actual else { throw CredentialError.identityMismatch }
        try ok(SecRequirementCopyString(actual, [], &text))
        guard let fields = info as? [String: Any],
              fields[kSecCodeInfoIdentifier as String] as? String == p.identifier,
              (local ? fields[kSecCodeInfoTeamIdentifier as String] == nil : fields[kSecCodeInfoTeamIdentifier as String] as? String == p.teamOU),
              let flags = fields[kSecCodeInfoFlags as String] as? NSNumber,
              flags.uint32Value & SecCodeSignatureFlags.runtime.rawValue != 0,
              (fields[kSecCodeInfoPList as String] as? [String: Any])?["CFBundleIdentifier"] as? String == p.identifier,
              text as String? == p.designatedRequirement,
              let certificates = fields[kSecCodeInfoCertificates as String] as? [SecCertificate], let leaf = certificates.first,
              Insecure.SHA1.hash(data: SecCertificateCopyData(leaf) as Data).map({ String(format: "%02X", $0) }).joined() == p.certificateSHA1.uppercased()
        else { throw CredentialError.identityMismatch }
        let entitlements = fields[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:]
        // This local route is deliberately outside App Sandbox and has no DP access-group entitlement.
        guard entitlements["com.apple.security.app-sandbox"] as? Bool != true,
              entitlements["keychain-access-groups"] == nil,
              entitlements["com.apple.security.get-task-allow"] as? Bool != true,
              entitlements["com.apple.security.cs.disable-library-validation"] as? Bool != true,
              entitlements["com.apple.security.cs.allow-dyld-environment-variables"] as? Bool != true
        else { throw CredentialError.identityMismatch }
        // The team route already proved subject OU and the Apple chain with the
        // native exact-leaf requirement above. OU is not a top-level property
        // returned by SecCertificateCopyValues on this system.
        if local || team { return } // All image, identity, entitlement and runtime checks above remain mandatory.
        var failure: Unmanaged<CFError>?
        guard let properties = SecCertificateCopyValues(leaf, [kSecOIDOrganizationalUnitName] as CFArray, &failure) as? [CFString: Any],
              let entry = properties[kSecOIDOrganizationalUnitName] as? [CFString: Any],
              NativeDeploymentGate.matchesOU(entry[kSecPropertyKeyValue], expected: p.teamOU)
        else { throw CredentialError.identityMismatch }
    }
}
