import Foundation
import ARLCredentialOnboarding

public struct CredentialHostBootstrap: Sendable {
    public let service: CredentialOnboarding
    public let configured: Bool
    public init(service: CredentialOnboarding, configured: Bool) { self.service = service; self.configured = configured }
    public static func disabled() -> Self { .init(service: .disabled(), configured: false) }
    /// Authority is adjacent public root-review metadata, rather than a self-referential executable hash embedded in its signature.
    /// Missing/false/malformed authority leaves the actual product entry points disabled.
    public static func load(bundle: Bundle = .main) -> Self {
        let authorityURL = bundle.bundleURL.deletingPathExtension().appendingPathExtension("authority.json")
        guard let values = try? authorityURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size <= 16384,
              let bytes = try? Data(contentsOf: authorityURL) else { return .init(service: .disabled(), configured: false) }
        return assemble(bytes, bundleURL: bundle.bundleURL)
    }
    public static func assemble(_ authorityBytes: Data, bundleURL: URL) -> Self {
        do {
            let authority = try CredentialHostAuthority.decode(authorityBytes)
            let deployment = try authority.loginDeployment(for: bundleURL)
            let profile = authority.validationPurposes.contains(.fliggyTravelReadOnly) ? try FlyAIGatewayProfile.officialCLI116Compatibility() : nil
            return .init(service: .approvedLoginMacOS(deployment: deployment, flyAIProfile: profile,
                                               validationPurposes: Set(authority.validationPurposes)), configured: true)
        } catch { return .init(service: .disabled(), configured: false) }
    }
}
