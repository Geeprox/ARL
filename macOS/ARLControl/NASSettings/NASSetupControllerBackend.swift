import Foundation

// Private native-host composition only. This is neither an RPC interface nor
// a replacement controller/factory. The owner maps controller_bridge.py's
// typed projections to the existing NASSetupContract.swift types.
@MainActor
public protocol ARLNASCapturedControllerAction: AnyObject {
    var request: ARLNASActionRequest { get }
    func run() async -> ARLNASActionReply
}

@MainActor
public protocol ARLNASManualControllerPort: AnyObject {
    // Cached metadata only. No lookup, permission request or transport effect.
    func cachedSnapshot() -> ARLNASSetupSnapshot
    // Must bind exactly this request to the actual controller.capture_click
    // synchronously. The returned operation owns that non-serializable intent.
    func captureAfterClick(_ request: ARLNASActionRequest) throws -> any ARLNASCapturedControllerAction
}

@MainActor
public final class ARLNASControllerBackend: ARLNASSetupBackend {
    private let port: (any ARLNASManualControllerPort)?
    public init(port: (any ARLNASManualControllerPort)? = nil) { self.port = port }

    public func cachedSnapshot() -> ARLNASSetupSnapshot {
        guard let port else { return .unsupported }
        return heldLiveProjection(port.cachedSnapshot())
    }

    public func perform(_ request: ARLNASActionRequest,
                        manualIntent: ARLNASManualIntent) async -> ARLNASActionReply {
        guard manualIntent.consume(for: request) else {
            return reply(request, .held(.manualIntentRequired))
        }
        guard let port else { return reply(request, .held(.hostNotConfigured)) }
        guard !Task.isCancelled else { return reply(request, .failed(.userCancelled)) }
        // Frozen 0.1.0 is source-NO-GO. There is no enable flag, secret input,
        // or optimistic state that can open this checkpoint's live actions.
        guard request.action == .saveConfiguration || request.action == .stop else {
            return reply(request, .unsupported(request.action == .testWrite
                ? .writeUnsupported : .nativeResolverUnavailable))
        }
        do {
            let captured = try port.captureAfterClick(request)
            guard captured.request == request else { return reply(request, .held(.bindingMismatch)) }
            let result = await captured.run()
            guard !Task.isCancelled else { return reply(request, .failed(.userCancelled)) }
            guard result.request == request else { return reply(request, .held(.bindingMismatch)) }
            return ARLNASActionReply(request: request, outcome: result.outcome,
                                     snapshot: heldLiveProjection(result.snapshot))
        } catch let fault as ARLNASFault {
            return reply(request, .held(fault))
        } catch {
            return reply(request, .failed(.providerInvalid))
        }
    }

    private func reply(_ request: ARLNASActionRequest, _ outcome: ARLNASActionOutcome) -> ARLNASActionReply {
        ARLNASActionReply(request: request, outcome: outcome, snapshot: cachedSnapshot())
    }

    private func heldLiveProjection(_ value: ARLNASSetupSnapshot) -> ARLNASSetupSnapshot {
        let blocked = ARLNASAdmission.unsupported(.nativeResolverUnavailable)
        return ARLNASSetupSnapshot(revision: value.revision, provider: .unsupported,
            availability: ARLNASActionAvailability(saveConfiguration: value.availability.saveConfiguration,
                saveCredential: blocked, testConnection: blocked, testRead: blocked,
                reconnect: blocked, stop: value.availability.stop),
            configuration: value.configuration,
            currentConfigurationGeneration: value.currentConfigurationGeneration,
            readScope: value.readScope, observedCallerPins: value.observedCallerPins,
            connectionEpoch: nil, configurationSaved: value.configurationSaved,
            credentialReferenceSaved: value.credentialReferenceSaved,
            credentialAvailable: .unsupported(.nativeResolverUnavailable),
            connected: .unsupported(.nativeResolverUnavailable),
            readable: .unsupported(.nativeResolverUnavailable), writable: value.writable)
    }
}
