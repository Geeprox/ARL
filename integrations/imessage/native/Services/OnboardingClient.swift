import Foundation

/// Supply the existing signed native Control channel. There is no script,
/// arbitrary URL/process adapter, Apple credential form, or implicit enrollment.
public protocol MessagesOnboardingClient: Sendable {
    func perform(_ request: OnboardingRequest) async throws -> OnboardingReply
}

public struct SourceOnlyClient: MessagesOnboardingClient {
    public init() {}
    public func perform(_ request: OnboardingRequest) async throws -> OnboardingReply {
        throw SourceError.hostNotInstalled
    }
    public enum SourceError: Error { case hostNotInstalled }
}
