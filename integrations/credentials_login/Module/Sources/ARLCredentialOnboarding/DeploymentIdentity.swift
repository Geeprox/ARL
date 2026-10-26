import Foundation
import Security
import CryptoKit

/// Values come from the final reviewed signed app, not from this source-only package. No default identity or entitlement is invented.
public struct CredentialDeployment: Sendable {
    public let bundleURL: URL
    public let identifier: String
    public let certificateSHA1: String
    public let teamOU: String
    public let designatedRequirement: String
    public let applicationIdentifier: String
    public let applicationAccessGroup: String
    public let reviewedArtifactSHA256: String
    public let provisioningProfileSHA256: String
    public init(bundleURL: URL, identifier: String, certificateSHA1: String, teamOU: String, designatedRequirement: String, applicationIdentifier: String, applicationAccessGroup: String, reviewedArtifactSHA256: String, provisioningProfileSHA256: String) {
        self.bundleURL = bundleURL; self.identifier = identifier; self.certificateSHA1 = certificateSHA1
        self.teamOU = teamOU; self.designatedRequirement = designatedRequirement; self.applicationIdentifier = applicationIdentifier
        self.applicationAccessGroup = applicationAccessGroup; self.reviewedArtifactSHA256 = reviewedArtifactSHA256
        self.provisioningProfileSHA256 = provisioningProfileSHA256
    }
}
struct DisabledDeploymentGate: DeploymentGate { func verify() throws { throw CredentialError.deploymentNotApproved } }
struct NativeDeploymentGate: DeploymentGate {
    let deployment: CredentialDeployment
    private func ok(_ status: OSStatus) throws { guard status == errSecSuccess else { throw CredentialError.identityMismatch } }
    static func matchesOU(_ value: Any?, expected: String) -> Bool {
        if let string = value as? String { return string == expected }
        if let values = value as? [[CFString: Any]], values.count == 1 { return values[0][kSecPropertyKeyValue] as? String == expected }
        return false
    }
    func verify() throws {
        let p = deployment
        guard p.bundleURL.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL,
              p.certificateSHA1.count == 40, p.certificateSHA1.allSatisfy({ $0.isHexDigit }),
              p.reviewedArtifactSHA256.count == 64, !p.identifier.isEmpty, !p.teamOU.isEmpty,
              p.applicationIdentifier.hasSuffix("." + p.identifier), p.applicationAccessGroup == p.applicationIdentifier,
              p.provisioningProfileSHA256.count == 64,
              let profileAttributes = try? p.bundleURL.appendingPathComponent("Contents/embedded.provisionprofile").resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              profileAttributes.isRegularFile == true, profileAttributes.isSymbolicLink != true,
              let profileSize = profileAttributes.fileSize, profileSize > 0, profileSize <= 1_048_576,
              let profile = try? Data(contentsOf: p.bundleURL.appendingPathComponent("Contents/embedded.provisionprofile"), options: .mappedIfSafe),
              SHA256.hash(data: profile).map({ String(format: "%02x", $0) }).joined() == p.provisioningProfileSHA256.lowercased(),
              let executable = Bundle.main.executableURL,
              let digest = try? Data(contentsOf: executable, options: .mappedIfSafe),
              SHA256.hash(data: digest).map({ String(format: "%02x", $0) }).joined() == p.reviewedArtifactSHA256.lowercased() else { throw CredentialError.deploymentNotApproved }
        var code: SecStaticCode?, requirement: SecRequirement?, info: CFDictionary?, actualDR: SecRequirement?, drString: CFString?
        try ok(SecStaticCodeCreateWithPath(p.bundleURL as CFURL, [], &code))
        try ok(SecRequirementCreateWithString(p.designatedRequirement as CFString, [], &requirement))
        guard let code, let requirement else { throw CredentialError.identityMismatch }
        try ok(SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckNestedCode | kSecCSCheckAllArchitectures), requirement))
        try ok(SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info))
        try ok(SecCodeCopyDesignatedRequirement(code, [], &actualDR))
        guard let actualDR else { throw CredentialError.identityMismatch }
        try ok(SecRequirementCopyString(actualDR, [], &drString))
        guard let m = info as? [String: Any], m[kSecCodeInfoIdentifier as String] as? String == p.identifier,
              m[kSecCodeInfoTeamIdentifier as String] as? String == p.teamOU,
              (m[kSecCodeInfoPList as String] as? [String: Any])?["CFBundleIdentifier"] as? String == p.identifier,
              drString as String? == p.designatedRequirement,
              let certificates = m[kSecCodeInfoCertificates as String] as? [SecCertificate], let leaf = certificates.first,
              Insecure.SHA1.hash(data: SecCertificateCopyData(leaf) as Data).map({ String(format: "%02X", $0) }).joined() == p.certificateSHA1.uppercased(),
              let entitlements = m[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
              entitlements["keychain-access-groups"] as? [String] == [p.applicationAccessGroup],
              entitlements["com.apple.application-identifier"] == nil || entitlements["application-identifier"] == nil ||
                  entitlements["com.apple.application-identifier"] as? String == entitlements["application-identifier"] as? String,
              (entitlements["com.apple.application-identifier"] as? String ?? entitlements["application-identifier"] as? String) == p.applicationIdentifier else { throw CredentialError.identityMismatch }
        var failure: Unmanaged<CFError>?
        guard let subject = SecCertificateCopyValues(leaf, [kSecOIDOrganizationalUnitName] as CFArray, &failure) as? [CFString: Any],
              let entry = subject[kSecOIDOrganizationalUnitName] as? [CFString: Any],
              Self.matchesOU(entry[kSecPropertyKeyValue], expected: p.teamOU) else { throw CredentialError.identityMismatch }
    }
}
