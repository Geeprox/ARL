import Foundation
import CoreFoundation

enum MessagesV2Fields {
    static func canonicalUUID(_ s: String) -> Bool { UUID(uuidString: s)?.uuidString.lowercased() == s }
    static func matches(_ s: String, _ pattern: String) -> Bool { s.range(of: pattern, options: .regularExpression) != nil }
    static func trueBoolean(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return false }
        return number.boolValue
    }
}

struct MessagesNativeScopeV2: Codable, Sendable {
    let lease_id, session_id: String
    let generation: Int
    let candidate_pin, owner, group_id, scope_id, plan_hash, operation_id, send_text_sha256: String
    let expires_at: Double
    var revoked, consumed: Bool
    var send_outcome: String
}

/// Captured before dispatch, retained across awaits, and never reconstructed from a snapshot.
struct MessagesCleanupOperationV2: Codable, Sendable, Equatable {
    let operation_id: String
    let epoch, host_generation: Int
    let session_id: String?
    let generation: Int
    let lease_id: String?
}

/// Only the responsible native host produces this envelope, on the same authenticated channel.
struct MessagesNativeAuthorityV2: Codable, Sendable {
    let schema_version: Int
    let run_id, policy_sha256: String
    let host_generation, revision: Int
    let started_at, deadline, observed_at: Double
    let expired, backend_ready: Bool
    let send: Send
    let lease: Lease
    let cleanup: Cleanup
    struct Send: Codable, Sendable {
        let limit: Int
        let consumed: Bool
        let outcome: String
        let operation_id: String?
    }
    struct Lease: Codable, Sendable {
        let state: String
        let session_id: String?
        let generation: Int
        let scope_id: String?
    }
    struct Cleanup: Codable, Sendable {
        let epoch: Int
        let state: String
        let session_id: String?
        let generation: Int
        let operation_id: String?
    }
    var wireValue: [String: Any] {
        get throws {
            var root = try JSONSerialization.jsonObject(with: JSONEncoder().encode(self)) as! [String: Any]
            var send = root["send"] as! [String: Any]; send["operation_id"] = self.send.operation_id ?? (NSNull() as Any)
            var lease = root["lease"] as! [String: Any]; lease["session_id"] = self.lease.session_id ?? (NSNull() as Any); lease["scope_id"] = self.lease.scope_id ?? (NSNull() as Any)
            var cleanup = root["cleanup"] as! [String: Any]; cleanup["session_id"] = self.cleanup.session_id ?? (NSNull() as Any); cleanup["operation_id"] = self.cleanup.operation_id ?? (NSNull() as Any)
            root["send"] = send; root["lease"] = lease; root["cleanup"] = cleanup
            return root
        }
    }
    var clean: Bool { ["completed", "not_required"].contains(cleanup.state) }
    var trialActive: Bool { !expired && backend_ready && lease.state == "active" && cleanup.state == "pending" }
    func validate(_ raw: Any) throws {
        func object(_ value: Any?, _ keys: Set<String>) throws -> [String: Any] {
            guard let value = value as? [String: Any], Set(value.keys) == keys else { throw MessagesTransportFault("invalid_response") }
            return value
        }
        let root = try object(raw, ["schema_version", "run_id", "policy_sha256", "host_generation", "revision", "started_at", "deadline", "observed_at", "expired", "backend_ready", "send", "lease", "cleanup"])
        _ = try object(root["send"], ["limit", "consumed", "outcome", "operation_id"])
        _ = try object(root["lease"], ["state", "session_id", "generation", "scope_id"])
        _ = try object(root["cleanup"], ["epoch", "state", "session_id", "generation", "operation_id"])
        guard schema_version == 2, MessagesV2Fields.canonicalUUID(run_id),
              MessagesV2Fields.matches(policy_sha256, "^[a-f0-9]{64}$"), host_generation > 0, revision > 0,
              started_at.isFinite, started_at >= 0, deadline.isFinite, deadline > started_at && deadline <= started_at + 900,
              observed_at.isFinite, observed_at >= started_at, expired || observed_at < deadline,
              send.limit == 1, ["unused", "consumed_unknown", "accepted"].contains(send.outcome),
              send.consumed == (send.outcome != "unused"), send.operation_id.map(MessagesV2Fields.canonicalUUID) ?? !send.consumed,
              ["inactive", "active", "revoked", "expired"].contains(lease.state), lease.generation >= 0,
              lease.session_id.map(MessagesV2Fields.canonicalUUID) ?? (lease.generation == 0 && lease.scope_id == nil && lease.state == "inactive"),
              lease.scope_id.map({ MessagesV2Fields.matches($0, "^ims_[a-f0-9]{32}$") }) ?? (lease.state == "inactive"),
              lease.session_id == nil || lease.generation > 0, !(expired && lease.state == "active"),
              cleanup.epoch >= 0, ["not_required", "pending", "in_progress", "completed", "unknown"].contains(cleanup.state),
              cleanup.session_id.map(MessagesV2Fields.canonicalUUID) ?? (cleanup.generation == 0),
              cleanup.session_id == nil || cleanup.generation > 0,
              cleanup.operation_id.map(MessagesV2Fields.canonicalUUID) ?? ["not_required", "pending"].contains(cleanup.state) else { throw MessagesTransportFault("invalid_response") }
    }
}

/// V2 Control frames retain the finite v1 commands/arguments used by the owned backend.
/// No new target, path, text, script, grant or generic bootstrap command is introduced.
enum MessagesControlWireV2 {
    static func encode(_ request: OnboardingRequest) throws -> Data {
        var raw = try MessagesJSON.decode(JSONEncoder().encode(request)).value
        raw["schema_version"] = 2
        return try MessagesJSON(raw).data
    }
    static func decode(_ bytes: Data) throws -> MessagesControlFrame {
        var raw = try MessagesJSON.decode(bytes, limit: 16384).value
        guard MessagesNativeIO.integer(raw["schema_version"]) == 2 else { throw MessagesTransportFault("invalid_request") }
        raw["schema_version"] = 1
        let frame = try MessagesControlFrame.decode(MessagesJSON(raw).data)
        guard frame.command != "verify_mio" else { throw MessagesTransportFault("event_unproven") }
        return frame
    }
}
