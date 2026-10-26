import Foundation
import AppKit
import Darwin

/// Root supplies these exact pins only in a later reviewed candidate. No UI release switch.
struct MessagesProductAdmission: Sendable {
    let runID: String
    let policySHA256: String
    let closureSHA256: String
    /// Fixed approval deadline, no later than earliest approved launch + 900s.
    /// The approval owner preserves it across reconnect/restart; UI cannot renew it.
    let notAfter: TimeInterval
}

protocol MessagesProductClient: Sendable {
    func exchange(_ request: OnboardingRequest) async throws -> Data
}

/// Additive structured-reply port. Frozen NativeMessagesClient drops snapshot;
/// reuse its deployment/IO/peer validators, retaining authenticated raw bytes.
struct MessagesProductNativeClient: MessagesProductClient {
    let home: URL
    let admission: MessagesProductAdmission?
    func exchange(_ request: OnboardingRequest) async throws -> Data {
        guard let admission else { throw MessagesTransportFault("activation_not_approved") } // before file/socket/LS reads
        guard request.command != "verify_mio", MessagesProductReply.canonicalUUID(admission.runID),
              MessagesProductReply.matches(admission.policySHA256, "^[a-f0-9]{64}$"),
              MessagesProductReply.matches(admission.closureSHA256, "^[a-f0-9]{64}$"),
              admission.notAfter.isFinite, admission.notAfter > 0 else { throw MessagesTransportFault("invalid_deployment") }
        try Self.checkDeadline(request, admission)
        // Same finite request decoder as the native host. No script, target, path or send-body arguments.
        _ = try MessagesControlFrame.decode(JSONEncoder().encode(request))
        let deployment = try MessagesNativeDeployment.load(home.appendingPathComponent("messages/control.json").path)
        try Self.review(deployment, admission)
        do { return try await Task.detached { try Self.exchange(request, deployment, admission) }.value }
        catch let error as MessagesTransportFault where error.code == "transport_unavailable" && request.command == "begin" {
            #if MESSAGES_HOST_FIXTURE
            throw error
            #else
            // Explicit Begin is the only launch path; snapshot/restart never launches.
            try Self.review(deployment, admission)
            try await Self.launch(deployment)
            for _ in 0..<40 {
                do { return try await Task.detached { try Self.exchange(request, deployment, admission) }.value }
                catch let error as MessagesTransportFault where error.code == "transport_unavailable" {
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
            }
            throw MessagesTransportFault("host_unavailable")
            #endif
        }
    }
    private static func review(_ d: MessagesNativeDeployment, _ a: MessagesProductAdmission) throws {
        guard d.policy_sha256 == a.policySHA256, d.closure_sha256 == a.closureSHA256 else { throw MessagesTransportFault("identity_changed") }
        try d.verify()
        let bytes = try MessagesNativeIO.privateFile(d.helper_bundle_path + "/Contents/Resources/activation.json")
        let p = try MessagesJSON.decode(bytes).value
        guard MessagesNativeIO.hash(bytes) == a.policySHA256, p["mode"] as? String == "live",
              p["run_id"] as? String == a.runID, MessagesNativeIO.integer(p["enabled"]) == 1,
              MessagesNativeIO.integer(p["metadata_admitted"]) == 1,
              MessagesNativeIO.integer(p["launch_attribution_verified"]) == 1,
              MessagesNativeIO.integer(p["max_sends"]) == 1,
              MessagesNativeIO.integer(p["scope_seconds"]) == 900,
              MessagesNativeIO.integer(p["metadata_limit"]) == 20 else { throw MessagesTransportFault("activation_not_approved") }
    }
    private static func exchange(_ request: OnboardingRequest, _ d: MessagesNativeDeployment, _ a: MessagesProductAdmission) throws -> Data {
        try checkDeadline(request, a)
        try review(d, a) // recheck after detached dispatch
        let fd = try MessagesNativeIO.socketAt(d.state_root + "/control.sock", listen: false)
        defer { close(fd) }
        let peer = try MessagesNativeIO.Peer(fd, requirement: d.helper_requirement)
        try MessagesNativeIO.send(JSONEncoder().encode(request), fd)
        guard let raw = try MessagesNativeIO.line(fd, limit: 65536, seconds: request.command == "permission_action" ? 195 : 20),
              peer.signatureCurrent() else { throw MessagesTransportFault("identity_unverified") }
        _ = try MessagesProductReply.decode(raw, for: request)
        try review(d, a)
        return raw
    }
    private static func checkDeadline(_ request: OnboardingRequest, _ a: MessagesProductAdmission) throws {
        if !["snapshot", "cancel", "disable"].contains(request.command) {
            let remaining = a.notAfter - Date().timeIntervalSince1970
            guard remaining > 0 && remaining <= 900 else { throw MessagesTransportFault("verification_expired") }
        }
    }
    @MainActor private static func launch(_ d: MessagesNativeDeployment) async throws {
        let config = NSWorkspace.OpenConfiguration()
        config.arguments = ["--serve"]; config.activates = false; config.createsNewApplicationInstance = true
        _ = try await NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: d.helper_bundle_path), configuration: config)
    }
}
