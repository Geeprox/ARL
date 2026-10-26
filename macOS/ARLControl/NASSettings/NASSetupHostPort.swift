import Foundation
import Dispatch

// In-process call-through adapter for methods owned by the enclosing host.
// The closures must be bound to its existing controller. This adapter does not
// embed Python, decode a token, authenticate a peer, or create a transport.
@MainActor
public final class ARLNASBoundControllerPort: ARLNASManualControllerPort {
    public typealias CachedSnapshot = @MainActor () -> ARLNASSetupSnapshot
    public typealias CaptureClick = @MainActor (ARLNASActionRequest) throws -> any ARLNASCapturedControllerAction
    private let readCache: CachedSnapshot
    private let captureClick: CaptureClick

    public init(cachedSnapshot: @escaping CachedSnapshot,
                captureAfterClick: @escaping CaptureClick) {
        readCache = cachedSnapshot
        captureClick = captureAfterClick
    }

    public func cachedSnapshot() -> ARLNASSetupSnapshot { readCache() }

    public func captureAfterClick(_ request: ARLNASActionRequest) throws -> any ARLNASCapturedControllerAction {
        // Source-NO-GO applies here as well as at the injected backend. There
        // is no runtime switch to open the dependency's live action paths.
        guard request.action == .saveConfiguration || request.action == .stop else {
            throw request.action == .testWrite ? ARLNASFault.writeUnsupported : .nativeResolverUnavailable
        }
        let captured = try captureClick(request)
        guard captured.request == request else { throw ARLNASFault.bindingMismatch }
        return SingleUseHostAction(captured: captured, readCache: readCache)
    }
}

@MainActor
private final class SingleUseHostAction: ARLNASCapturedControllerAction {
    let request: ARLNASActionRequest
    private let captured: any ARLNASCapturedControllerAction
    private let readCache: ARLNASBoundControllerPort.CachedSnapshot
    private var used = false
    private let deadline: UInt64

    init(captured: any ARLNASCapturedControllerAction,
         readCache: @escaping ARLNASBoundControllerPort.CachedSnapshot) {
        self.captured = captured
        self.readCache = readCache
        request = captured.request
        let value = DispatchTime.now().uptimeNanoseconds.addingReportingOverflow(
            ARLNASManualIntent.maximumLifetimeSeconds * 1_000_000_000)
        deadline = value.overflow ? 0 : value.partialValue
    }

    func run() async -> ARLNASActionReply {
        guard !used else { return failure(.manualIntentRequired) }
        used = true
        guard DispatchTime.now().uptimeNanoseconds < deadline else { return failure(.manualIntentExpired) }
        guard !Task.isCancelled else { return failure(.userCancelled) }
        let result = await captured.run()
        guard !Task.isCancelled else { return failure(.userCancelled) }
        guard result.request == request else { return failure(.bindingMismatch) }
        return result
    }

    private func failure(_ fault: ARLNASFault) -> ARLNASActionReply {
        ARLNASActionReply(request: request, outcome: .held(fault), snapshot: readCache())
    }
}

// Finite error mapping for the host's typed callback. Raw exception messages
// and arbitrary controller outcomes never become UI text.
public enum ARLNASControllerResultProjection {
    public static func fault(_ code: String) -> ARLNASFault {
        switch code {
        case "host_not_configured": return .hostNotConfigured
        case "native_nas_purpose_unavailable": return .nativeNASPurposeUnavailable
        case "native_resolver_unavailable", "unsupported": return .nativeResolverUnavailable
        case "invalid_configuration": return .invalidConfiguration
        case "configuration_not_saved", "nas_not_configured": return .configurationNotSaved
        case "configuration_changed": return .configurationChanged
        case "binding_mismatch": return .bindingMismatch
        case "stale_generation": return .staleGeneration
        case "caller_unverified": return .callerRejected
        case "manual_intent_required": return .manualIntentRequired
        case "manual_intent_expired": return .manualIntentExpired
        case "operation_in_progress", "busy": return .operationInProgress
        case "cancelled", "user_cancelled": return .userCancelled
        case "connection_failed": return .connectionFailed
        case "read_denied": return .readDenied
        case "write_unsupported": return .writeUnsupported
        case "protocol_unsupported": return .protocolUnsupported
        case "disabled": return .disabled
        case "source_changed", "nas_source_changed": return .sourceChanged
        case "reference_mismatch": return .referenceMismatch
        case "revoked": return .revoked
        case "expired": return .expired
        case "budget_exhausted": return .budgetExhausted
        case "ticket_invalid": return .ticketInvalid
        case "credentials_unavailable": return .credentialsUnavailable
        case "credential_invalid": return .credentialInvalid
        case "auth_failed", "nas_auth_failed": return .authenticationFailed
        case "access_denied", "nas_access_denied": return .accessDenied
        case "host_key_mismatch", "nas_host_key_mismatch": return .hostKeyMismatch
        case "transport_timeout", "nas_transport_timeout", "nas_timeout": return .transportTimeout
        case "transport_failed", "nas_transport_failed": return .transportFailed
        case "nas_unavailable": return .connectionFailed
        case "nas_dependency_missing": return .nativeResolverUnavailable
        default: return .providerInvalid
        }
    }

    public static func outcome(_ value: String, failure: String?) -> ARLNASActionOutcome {
        if value == "applied", failure == nil { return .applied }
        guard let failure else { return .failed(.providerInvalid) }
        let mapped = fault(failure)
        switch value {
        case "held": return .held(mapped)
        case "unsupported": return .unsupported(mapped)
        case "failed": return .failed(mapped)
        default: return .failed(.providerInvalid)
        }
    }
}
