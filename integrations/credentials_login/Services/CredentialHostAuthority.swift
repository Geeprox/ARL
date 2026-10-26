import Foundation
import ARLCredentialOnboarding

public enum CredentialHostAdmissionError: Error, Sendable { case notAdmitted, malformed, identityMismatch, unsupportedScope }

/// Public review metadata only; no entered credential or protocol signing material belongs in this file.
public struct CredentialHostAuthority: Decodable, Sendable {
    public let schema: Int
    public let executionAllowed: Bool
    public let localCredentialManagementAllowed: Bool
    public let storageRoute: String?
    public let bundlePath: String
    public let identifier: String
    public let certificateSHA1: String
    public let teamOU: String
    public let designatedRequirement: String?
    public let applicationIdentifier: String?
    public let applicationAccessGroup: String?
    public let executableSHA256: String?
    public let provisioningProfileSHA256: String?
    public let validationPurposes: [CredentialPurpose]
    public let flyAIProfileIdentifier: String
    public let flyAIProfileSourceSHA256: String
    public static let candidateIdentifier = "local.arl.credential-onboarding"
    public static let expectedCertificateSHA1 = "CD85BA24208488935F9AC0BEC63E4BE6AAE189C4"
    public static let expectedCertificateOU = "LGZF25R84Z"
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 16384 else { throw CredentialHostAdmissionError.malformed }
        do { return try JSONDecoder().decode(Self.self, from: data) }
        catch { throw CredentialHostAdmissionError.malformed }
    }
    public func loginDeployment(for bundleURL: URL) throws -> LoginCredentialDeployment {
        guard executionAllowed, localCredentialManagementAllowed else { throw CredentialHostAdmissionError.notAdmitted }
        let local = schema == 2 && storageRoute == "local-code-login-acl-v2"
        let developer = schema == 1 && storageRoute == "local-login-acl-v1"
        let team = schema == 3 && storageRoute == "local-team-reentry-v1"
        guard local || developer || team,
              !team || identifier == "local.arl.control",
              identifier == Self.candidateIdentifier || identifier == "local.arl.control",
              URL(fileURLWithPath: bundlePath).standardizedFileURL == bundleURL.standardizedFileURL
        else { throw CredentialHostAdmissionError.identityMismatch }
        if local {
            guard identifier == "local.arl.control", certificateSHA1.uppercased() == "859332B7FFFBBBB33B80C7B78D30C27D2D81583F", teamOU.isEmpty
            else { throw CredentialHostAdmissionError.identityMismatch }
        } else {
            guard certificateSHA1.uppercased() == Self.expectedCertificateSHA1, teamOU == Self.expectedCertificateOU
            else { throw CredentialHostAdmissionError.identityMismatch }
        }
        guard let designatedRequirement, !designatedRequirement.isEmpty,
              let executableSHA256, Self.digest(executableSHA256),
              applicationIdentifier == nil, applicationAccessGroup == nil, provisioningProfileSHA256 == nil,
              Set(validationPurposes).count == validationPurposes.count,
              flyAIProfileIdentifier == FlyAIGatewayProfile.profileIdentifier,
              flyAIProfileSourceSHA256 == FlyAIGatewayProfile.sourceBundleSHA256
        else { throw CredentialHostAdmissionError.unsupportedScope }
        return .init(bundleURL: bundleURL, identifier: identifier, certificateSHA1: certificateSHA1, teamOU: teamOU,
                     designatedRequirement: designatedRequirement, reviewedArtifactSHA256: executableSHA256,
                     identityRoute: local ? .localCodeCertificate : team ? .appleDevelopmentTeam : .developerID)
    }
    public func deployment(for bundleURL: URL) throws -> CredentialDeployment {
        guard schema == 1, executionAllowed, localCredentialManagementAllowed else { throw CredentialHostAdmissionError.notAdmitted }
        guard identifier == Self.candidateIdentifier || identifier == "local.arl.control",
              certificateSHA1.uppercased() == Self.expectedCertificateSHA1,
              teamOU == Self.expectedCertificateOU,
              URL(fileURLWithPath: bundlePath).standardizedFileURL == bundleURL.standardizedFileURL else { throw CredentialHostAdmissionError.identityMismatch }
        guard let designatedRequirement, !designatedRequirement.isEmpty,
              let applicationIdentifier, applicationIdentifier.hasSuffix("." + identifier),
              let applicationAccessGroup, applicationAccessGroup == applicationIdentifier,
              let executableSHA256, Self.digest(executableSHA256),
              let provisioningProfileSHA256, Self.digest(provisioningProfileSHA256),
              Set(validationPurposes).count == validationPurposes.count,
              flyAIProfileIdentifier == FlyAIGatewayProfile.profileIdentifier,
              flyAIProfileSourceSHA256 == FlyAIGatewayProfile.sourceBundleSHA256 else { throw CredentialHostAdmissionError.unsupportedScope }
        return .init(bundleURL: bundleURL, identifier: identifier, certificateSHA1: certificateSHA1, teamOU: teamOU,
                     designatedRequirement: designatedRequirement, applicationIdentifier: applicationIdentifier,
                     applicationAccessGroup: applicationAccessGroup, reviewedArtifactSHA256: executableSHA256,
                     provisioningProfileSHA256: provisioningProfileSHA256)
    }
    private static func digest(_ value: String) -> Bool { value.count == 64 && value.allSatisfy { $0.isHexDigit } }
}
