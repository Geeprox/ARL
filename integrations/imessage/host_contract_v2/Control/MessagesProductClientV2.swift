import Foundation
import AppKit
import Darwin

enum MessagesV2CandidateStatus: Sendable {
    case held
    /// Verified sealed source/deployment only. This is NOT host availability, OS or trial evidence.
    case verified(runID: String, policyHash: String)
}
protocol MessagesProductClientV2: Sendable {
    func inspectCandidate() async throws -> MessagesV2CandidateStatus
    func exchange(_ request: OnboardingRequest) async throws -> Data
}
private struct MessagesV2ConnectionAbsent: Error, Sendable {}

struct MessagesProductNativeClientV2: MessagesProductClientV2 {
    let home: URL
    let admission: MessagesProductAdmission?
    func inspectCandidate() async throws -> MessagesV2CandidateStatus {
        guard let admission else { return .held } // no file/socket/LS access
        _ = try await Task.detached { try reviewed(admission) }.value
        return .verified(runID: admission.runID, policyHash: admission.policySHA256)
    }
    func exchange(_ request: OnboardingRequest) async throws -> Data {
        guard let admission else { throw MessagesTransportFault("activation_not_approved") }
        let bytes = try MessagesControlWireV2.encode(request)
        _ = try MessagesControlWireV2.decode(bytes)
        try Self.checkDeadline(request, admission)
        let deployment = try await Task.detached { try reviewed(admission) }.value
        do { return try await Task.detached { try Self.once(request, deployment, admission) }.value }
        catch is MessagesV2ConnectionAbsent {
            guard request.command == "begin" else { throw MessagesTransportFault("host_not_connected") }
            #if MESSAGES_HOST_FIXTURE
            throw MessagesTransportFault("host_not_connected")
            #else
            // Only an explicit Begin after candidate verification may launch. No status-triggered launch.
            try Self.checkDeadline(request, admission)
            try await Self.launch(deployment)
            for _ in 0..<40 {
                do { return try await Task.detached { try Self.once(request, deployment, admission) }.value }
                catch is MessagesV2ConnectionAbsent { try await Task.sleep(nanoseconds: 100_000_000) }
            }
            throw MessagesTransportFault("host_not_connected")
            #endif
        }
    }
    private func reviewed(_ a: MessagesProductAdmission) throws -> MessagesNativeDeployment {
        guard MessagesV2Fields.canonicalUUID(a.runID), [a.policySHA256, a.closureSHA256].allSatisfy({ MessagesV2Fields.matches($0, "^[a-f0-9]{64}$") }),
              a.notAfter.isFinite, a.notAfter > 0 else { throw MessagesTransportFault("invalid_deployment") }
        let d = try MessagesNativeDeployment.load(home.appendingPathComponent("messages/control.json").path)
        try Self.review(d, a); return d
    }
    private static func review(_ d: MessagesNativeDeployment, _ a: MessagesProductAdmission) throws {
        guard d.policy_sha256 == a.policySHA256, d.closure_sha256 == a.closureSHA256 else { throw MessagesTransportFault("identity_changed") }
        try d.verify()
        guard Bundle(path: d.helper_bundle_path)?.object(forInfoDictionaryKey: "ARLMessagesWireVersion") as? Int == 2 else { throw MessagesTransportFault("protocol_upgrade_required") }
        let bytes = try MessagesNativeIO.privateFile(d.helper_bundle_path + "/Contents/Resources/activation.json")
        let p = try MessagesJSON.decode(bytes).value
        guard MessagesNativeIO.hash(bytes) == a.policySHA256, MessagesNativeIO.integer(p["schema_version"]) == 2,
              p["mode"] as? String == "live", p["run_id"] as? String == a.runID,
              (p["run_not_after"] as? Double) == a.notAfter, MessagesNativeIO.integer(p["enabled"]) == 1,
              [0, 1].contains(MessagesNativeIO.integer(p["metadata_admitted"]) ?? -1),
              [0, 1].contains(MessagesNativeIO.integer(p["launch_attribution_verified"]) ?? -1),
              MessagesNativeIO.integer(p["max_sends"]) == 1, MessagesNativeIO.integer(p["scope_seconds"]) == 900,
              MessagesNativeIO.integer(p["metadata_limit"]) == 20 else { throw MessagesTransportFault("activation_not_approved") }
        // Initial setup may have metadata/attribution admission 0. Actual host gates still enforce each route.
    }
    private static func once(_ request: OnboardingRequest, _ d: MessagesNativeDeployment, _ a: MessagesProductAdmission) throws -> Data {
        try checkDeadline(request, a); try review(d, a)
        let fd: Int32
        do { fd = try MessagesNativeIO.socketAt(d.state_root + "/control.sock", listen: false) }
        catch let error as MessagesTransportFault where error.code == "transport_unavailable" { throw MessagesV2ConnectionAbsent() }
        defer { close(fd) }
        let peer = try MessagesNativeIO.Peer(fd, requirement: d.helper_requirement)
        // After sending starts, no failure is classified as pre-dispatch absence and no retry/launch follows.
        try MessagesNativeIO.send(MessagesControlWireV2.encode(request), fd)
        guard let raw = try MessagesNativeIO.line(fd, limit: 65536, seconds: request.command == "permission_action" ? 195 : 20),
              peer.signatureCurrent() else { throw MessagesTransportFault("identity_unverified") }
        let reply = try MessagesProductReplyV2.decode(raw, for: request)
        if let authority = reply.authority {
            guard authority.run_id == a.runID, authority.policy_sha256 == a.policySHA256,
                  authority.deadline <= a.notAfter else { throw MessagesTransportFault("identity_changed") }
        }
        try review(d, a); return raw
    }
    private static func checkDeadline(_ r: OnboardingRequest, _ a: MessagesProductAdmission) throws {
        if !["snapshot", "cancel", "disable"].contains(r.command) {
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
