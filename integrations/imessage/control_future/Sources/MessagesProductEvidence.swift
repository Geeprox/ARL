import Foundation

enum MessagesProductPhase: String, Decodable, Sendable {
    case disabled, account, permissions, group, verifying, connected, canceling, disabling, failed
    case reviewTest = "review_test", localReady = "local_ready", verifyingMio = "verifying_mio"
    case reconnectRequired = "reconnect_required", needsReview = "needs_review"
}

/// Structured wire evidence from the existing host, never inferred from panel copy.
struct MessagesProductSnapshot: Decodable, Sendable {
    let schema_version: Int
    let phase: MessagesProductPhase
    let enabled: Bool
    let implementation: String
    let session_id: String?
    let generation: Int
    let account: Account
    let permissions: Permissions
    let selection: Selection
    let local_transport: Local
    let mio: Mio
    let cleanup: String
    let last_error: String?
    let remaining_test_sends: Int
    let operational_grant: String

    struct Account: Decodable, Sendable {
        let state, evidence, server_authentication, service_route: String
    }
    struct Permissions: Decodable, Sendable {
        let identity, receive_access, send_automation, send_readback_access: String
        let executable_pinned: Bool
        var authorized: Bool {
            identity == "verified" && receive_access == "verified" && send_readback_access == "verified"
                && send_automation == "authorized_automation" && executable_pinned
        }
    }
    struct Selection: Decodable, Sendable {
        let state: String
        let scope_id: String?
        let participant_count: Int
    }
    struct Local: Decodable, Sendable {
        let receive, send, locked_state, media, understanding: String
    }
    struct Mio: Decodable, Sendable {
        let audience: String
        let personal_exclusive: Bool
        let transport, consumption, workflow_identity: String
    }
    var epoch: String { "\(session_id ?? "none")/\(generation)" }
    var trialVerified: Bool {
        enabled && [.localReady, .connected].contains(phase) && implementation == "installed"
            && permissions.authorized && account.state == "reported_signed_in"
            && selection.state == "selected" && operational_grant == "bounded_trial_only"
            && local_transport.receive == "verified_challenge" && local_transport.send == "participant_confirmed"
            && cleanup == "pending" && last_error == nil
    }
}

struct MessagesProductReview: Decodable, Sendable {
    let schema_version: Int
    let plan_id, operation_id, scope_id: String
    let send_text, receive_text, confirmation_text: String
    let send_limit, receive_limit: Int
    let expires_at: Double
    let audience, group_pin: String
    let automatic_retry: Bool
}

struct MessagesProductReply: Decodable, Sendable {
    let schema_version: Int
    let request_id, command: String
    let ok: Bool
    let snapshot: MessagesProductSnapshot?
    let presentation: OnboardingPanel?
    let candidates: [GroupChoice]?
    let plan: MessagesProductReview?
    let error: OnboardingReply.ErrorCode?

    static func decode(_ raw: Data, for request: OnboardingRequest) throws -> Self {
        let object = try MessagesJSON.decode(raw).value // size/depth/duplicate-key checks shared with frozen host
        guard Set(object.keys).isSubset(of: ["schema_version", "request_id", "command", "ok", "snapshot", "presentation", "candidates", "plan", "error"]),
              MessagesNativeIO.integer(object["schema_version"]) == 1,
              object["request_id"] as? String == request.requestID.uuidString.lowercased(),
              object["command"] as? String == request.command else { throw MessagesTransportFault("invalid_response") }
        let reply = try JSONDecoder().decode(Self.self, from: raw)
        guard reply.ok ? reply.error == nil : reply.error != nil else { throw MessagesTransportFault("invalid_response") }
        if !reply.ok {
            guard reply.snapshot == nil, reply.plan == nil, reply.candidates == nil,
                  let code = reply.error?.code, codes.union(transportCodes).contains(code) else { throw MessagesTransportFault("invalid_response") }
            return reply
        }
        guard let panel = reply.presentation, panel.schemaVersion == 1,
              MessagesProductPhase(rawValue: panel.phase) != nil,
              panel.actions.count <= 20, Set(panel.actions.map(\.id)).count == panel.actions.count else {
            throw MessagesTransportFault("invalid_response")
        }
        if request.command == "discover_groups" {
            guard reply.plan == nil, reply.snapshot == nil, let choices = reply.candidates,
                  choices.count <= 20, Set(choices.map(\.id)).count == choices.count,
                  choices.allSatisfy({ matches($0.id, "^candidate_[a-f0-9]{64}$") && bounded($0.name, 120)
                    && (2...16).contains($0.participants.count) && Set($0.participants).count == $0.participants.count
                    && $0.participants.allSatisfy({ bounded($0, 256) }) }) else { throw MessagesTransportFault("invalid_response") }
        } else if request.command == "prepare_test" {
            guard reply.candidates == nil, reply.snapshot == nil, let plan = reply.plan else { throw MessagesTransportFault("invalid_response") }
            guard let rawPlan = object["plan"] as? [String: Any], Set(rawPlan.keys) == ["schema_version", "plan_id", "operation_id", "scope_id", "send_text", "receive_text", "confirmation_text", "send_limit", "receive_limit", "expires_at", "audience", "group_pin", "automatic_retry"] else { throw MessagesTransportFault("invalid_response") }
            try validate(plan)
        } else {
            guard reply.candidates == nil, reply.plan == nil, let snapshot = reply.snapshot,
                  snapshot.phase.rawValue == panel.phase else { throw MessagesTransportFault("invalid_response") }
            try validate(snapshot, object["snapshot"])
        }
        return reply
    }

    private static func validate(_ s: MessagesProductSnapshot, _ raw: Any?) throws {
        guard let raw = raw as? [String: Any], Set(raw.keys) == ["schema_version", "phase", "enabled", "implementation", "session_id", "generation", "account", "permissions", "selection", "local_transport", "mio", "cleanup", "last_error", "remaining_test_sends", "operational_grant"],
              s.schema_version == 1, s.generation >= 0,
              s.session_id.map(canonicalUUID) ?? (s.generation == 0 && !s.enabled),
              s.session_id == nil || s.generation > 0,
              ["source_only", "installed"].contains(s.implementation), (0...3).contains(s.remaining_test_sends),
              ["not_required", "pending", "completed", "unknown", "failed"].contains(s.cleanup),
              ["inactive", "bounded_trial_only", "stopping_unverified"].contains(s.operational_grant),
              s.last_error.map({ codes.contains($0) }) ?? true,
              ["unknown", "reported_signed_in"].contains(s.account.state),
              ["not_checked", "user_confirmation_in_messages"].contains(s.account.evidence),
              (s.account.state == "reported_signed_in") == (s.account.evidence == "user_confirmation_in_messages"),
              s.account.server_authentication == "not_inspected",
              ["not_verified", "verified"].contains(s.account.service_route),
              ["unknown", "verified"].contains(s.permissions.identity),
              ["untested", "verified", "blocked"].contains(s.permissions.receive_access),
              ["untested", "verified", "blocked"].contains(s.permissions.send_readback_access),
              ["unknown", "not_determined", "authorized_automation", "denied", "restricted"].contains(s.permissions.send_automation),
              ["selected", "unselected"].contains(s.selection.state),
              s.selection.state == "selected" ? ((2...16).contains(s.selection.participant_count) && s.selection.scope_id.map({ matches($0, "^ims_[a-f0-9]{32}$") }) == true) : s.selection.participant_count == 0,
              ["not_verified", "verified_challenge"].contains(s.local_transport.receive),
              ["not_verified", "participant_confirmed"].contains(s.local_transport.send),
              ["not_tested", "verified_for_trial"].contains(s.local_transport.locked_state),
              s.local_transport.media == "not_tested", s.local_transport.understanding == "not_performed",
              s.mio.audience == "organization", !s.mio.personal_exclusive,
              ["not_attempted", "transport_accepted"].contains(s.mio.transport),
              ["unproven", "observed_event_trigger"].contains(s.mio.consumption),
              s.mio.workflow_identity == "not_available_from_subscription" else { throw MessagesTransportFault("invalid_response") }
        let fields: [String: Set<String>] = [
            "account": ["state", "evidence", "server_authentication", "service_route"],
            "permissions": ["identity", "receive_access", "send_automation", "send_readback_access", "executable_pinned"],
            "selection": ["state", "scope_id", "participant_count"],
            "local_transport": ["receive", "send", "locked_state", "media", "understanding"],
            "mio": ["audience", "personal_exclusive", "transport", "consumption", "workflow_identity"]]
        for (key, keys) in fields {
            guard let value = raw[key] as? [String: Any], Set(value.keys) == keys else { throw MessagesTransportFault("invalid_response") }
        }
    }
    private static func validate(_ p: MessagesProductReview) throws {
        let nonce = String(p.receive_text.dropFirst("ARL setup hello ".count))
        guard p.schema_version == 1, canonicalUUID(p.plan_id), canonicalUUID(p.operation_id),
              matches(p.scope_id, "^ims_[a-f0-9]{32}$"), matches(p.group_pin, "^[a-f0-9]{64}$"),
              matches(nonce, "^[a-f0-9]{32}$"), p.receive_text == "ARL setup hello " + nonce,
              p.send_text == "ARL setup test " + nonce, p.confirmation_text == "ARL setup received " + nonce,
              p.send_limit == 1, p.receive_limit == 2, p.expires_at.isFinite, p.expires_at >= 0,
              p.audience == "local_only", !p.automatic_retry else { throw MessagesTransportFault("invalid_response") }
    }
    static func matches(_ s: String, _ pattern: String) -> Bool { s.range(of: pattern, options: .regularExpression) != nil }
    static func canonicalUUID(_ s: String) -> Bool { UUID(uuidString: s)?.uuidString.lowercased() == s }
    private static func bounded(_ s: String, _ limit: Int) -> Bool { !s.isEmpty && s.count <= limit && !s.contains("\0") }
    static let codes: Set<String> = ["invalid_request", "identity_unverified", "identity_changed", "disabled", "busy", "unsupported", "account_confirmation_required", "permission_required", "metadata_scope_not_approved", "group_changed", "group_not_selected", "activation_not_approved", "request_conflict", "request_capacity", "verification_expired", "verification_timeout", "receive_timeout", "send_unknown", "attempt_consumed", "budget_exhausted", "cancelled", "cleanup_unknown", "storage_uncertain", "host_unavailable", "invalid_evidence", "event_unproven", "event_attempt_consumed", "clock_rollback"]
    static let transportCodes: Set<String> = ["invalid_deployment", "invalid_response", "duplicate_key", "invalid_arguments", "outcome_unknown", "socket_path_too_long", "transport_deadline", "transport_size_exceeded", "transport_truncated", "transport_unavailable", "unsafe_config", "unsafe_home", "unsafe_socket"]
}
