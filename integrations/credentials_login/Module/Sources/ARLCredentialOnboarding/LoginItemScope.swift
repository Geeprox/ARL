import Foundation

/// Fixed purpose slots only. New-team re-entry never searches the legacy slots.
enum LoginItemScope: Sendable {
    case original, teamReentryV1

    func service(_ purpose: CredentialPurpose) -> String {
        switch self {
        case .original: purpose.service
        case .teamReentryV1: "local.arl.credential-onboarding.team-entry.v1." + purpose.rawValue
        }
    }
    var account: String {
        switch self {
        case .original: "purpose-bound-local-entry"
        case .teamReentryV1: "purpose-bound-team-entry-v1"
        }
    }
}
