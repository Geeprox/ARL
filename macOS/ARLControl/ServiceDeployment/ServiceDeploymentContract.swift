import Foundation

/// Reuses the frozen Control WireSchema. This adds no RPC or transport method.
enum ServiceDeploymentContract {
    static let issueCodes: Set<String> = ["dependency_missing", "optional_dependency_absent", "optional_dependency_not_selected",
        "dependency_version_mismatch", "dependency_cycle", "configuration_missing", "deployment_id_conflict",
        "target_inventory_unavailable", "target_backend_unsupported", "port_conflict", "port_occupied_in_snapshot",
        "required_port_missing", "endpoint_port_missing", "required_mount_missing", "mount_write_review_required",
        "required_parameter_missing", "required_credential_reference_missing", "credential_resolution_not_performed",
        "native_mount_application_not_defined", "nas_transport_not_configured"]
    static let stepKinds: Set<String> = ["review_source", "verify_target", "verify_dependencies", "review_ports", "review_mounts",
        "review_configuration", "stage_asset", "start_service", "observe_health", "register_portal"]
    static let readinessStates: Set<String> = ["not_checked", "ready", "stale", "revoked", "unverified", "synthetic_only", "not_deployed",
        "not_registered", "evidence_mismatch", "registration_binding_missing", "registry_descriptor_mismatch", "configuration_incomplete",
        "invalid_evidence_time", "health_endpoint_mismatch", "health_failed", "credential_not_checked", "credential_unavailable", "dependency_not_ready"]

    static func decodePlan(_ data: Data) throws -> ServiceDeploymentPlan {
        let root = try WireSchema.object(try document(data), ["schema_version", "kind", "state", "execution", "registration", "readiness",
            "apply_available", "effects_performed", "root_service_id", "services", "dependency_order", "issues", "steps", "inventory_source"])
        try WireSchema.constantInt(root["schema_version"], 1)
        try WireSchema.choice(root["kind"], ["service_deployment_plan"])
        try WireSchema.choice(root["state"], ["blocked", "reviewable"])
        try WireSchema.choice(root["execution"], ["not_performed"])
        try WireSchema.choice(root["registration"], ["not_performed"])
        try WireSchema.choice(root["readiness"], ["not_checked"])
        guard try !WireSchema.boolean(root["apply_available"]),
              try WireSchema.array(root["effects_performed"], maximum: 0).isEmpty else { throw ARLError(code: "invalid_response") }
        try WireSchema.choice(root["inventory_source"], ["none", "synthetic", "host_observation"])
        let rootID = try serviceID(root["root_service_id"])
        let order = try WireSchema.array(root["dependency_order"], maximum: 32).map { try serviceID($0) }
        guard Set(order).count == order.count, order.contains(rootID) else { throw ARLError(code: "invalid_response") }
        let services = try WireSchema.array(root["services"], maximum: 32)
        var ids = Set<String>()
        for value in services {
            let entry = try WireSchema.object(value, ["service_id", "name", "backend", "target_id", "deployment_id", "manifest_sha256",
                "configuration_sha256", "asset", "proposed_registration", "ports", "mounts", "configuration_keys", "credential_requirements", "portal", "health"])
            let id = try serviceID(entry["service_id"])
            guard ids.insert(id).inserted, order.contains(id) else { throw ARLError(code: "invalid_response") }
            _ = try WireSchema.string(entry["name"])
            try WireSchema.choice(entry["backend"], ["mac_native", "docker", "nas_docker"])
            try WireSchema.identifier(entry["target_id"]); try WireSchema.identifier(entry["deployment_id"])
            try digest(entry["manifest_sha256"]); try digest(entry["configuration_sha256"])
            _ = try WireSchema.string(entry["asset"], maximum: 2400)
            let descriptor = try WireSchema.object(entry["proposed_registration"], ["id", "name", "icon_ref", "version", "capabilities"])
            guard try WireSchema.string(descriptor["id"]) == id,
                  try WireSchema.string(descriptor["name"]) == WireSchema.string(entry["name"]),
                  try WireSchema.array(descriptor["capabilities"], maximum: 0).isEmpty else { throw ARLError(code: "invalid_response") }
            try WireSchema.identifier(descriptor["version"], maximum: 80); try WireSchema.icon(descriptor["icon_ref"])
            try strings(entry["ports"], count: 16, length: 256)
            try strings(entry["mounts"], count: 16, length: 2400)
            try strings(entry["credential_requirements"], count: 16, length: 280)
            let keys = try WireSchema.array(entry["configuration_keys"], maximum: 32).map { try WireSchema.string($0, maximum: 64) }
            guard Set(keys).count == keys.count, keys.allSatisfy({ $0.range(of: "^[A-Z][A-Z0-9_]*$", options: .regularExpression) != nil }) else { throw ARLError(code: "invalid_response") }
            _ = try WireSchema.string(entry["portal"], maximum: 512)
            _ = try WireSchema.string(entry["health"], maximum: 768)
        }
        var issueIDs = Set<String>()
        var hasBlocking = false
        for value in try WireSchema.array(root["issues"], maximum: 512) {
            let issue = try WireSchema.object(value, ["code", "severity", "service_id", "field"])
            try WireSchema.choice(issue["code"], issueCodes); try WireSchema.choice(issue["severity"], ["blocking", "notice"])
            let id = try serviceID(issue["service_id"])
            let field = try WireSchema.string(issue["field"], maximum: 256)
            let code = try WireSchema.string(issue["code"])
            guard order.contains(id), issueIDs.insert(id + ":" + field + ":" + code).inserted else { throw ARLError(code: "invalid_response") }
            if try WireSchema.string(issue["severity"]) == "blocking" { hasBlocking = true }
        }
        guard try WireSchema.string(root["state"]) == (hasBlocking ? "blocked" : "reviewable") else { throw ARLError(code: "invalid_response") }
        var stepIDs = Set<String>()
        for value in try WireSchema.array(root["steps"], maximum: 320) {
            let step = try WireSchema.object(value, ["service_id", "kind", "detail", "state"])
            let id = try serviceID(step["service_id"])
            let kind = try WireSchema.string(step["kind"])
            try WireSchema.choice(step["kind"], stepKinds)
            try WireSchema.choice(step["state"], ["not_performed"])
            _ = try WireSchema.string(step["detail"], maximum: 512)
            guard ids.contains(id), stepIDs.insert(id + ":" + kind).inserted else { throw ARLError(code: "invalid_response") }
        }
        return try JSONDecoder().decode(ServiceDeploymentPlan.self, from: data)
    }

    static func decodeStatus(_ data: Data) throws -> ServiceDeploymentStatus {
        let root = try WireSchema.object(try document(data), ["schema_version", "kind", "service_id", "version", "target_id", "deployment_id",
            "manifest_sha256", "configuration_sha256", "generation", "registration", "connection", "authentication", "authorization", "deployment", "readiness", "source",
            "checked_at_ms", "health_checked_at_ms", "ready_until_ms"])
        try WireSchema.constantInt(root["schema_version"], 1); try WireSchema.choice(root["kind"], ["service_deployment_status"])
        _ = try serviceID(root["service_id"]); try WireSchema.identifier(root["version"], maximum: 80)
        try WireSchema.identifier(root["target_id"]); try WireSchema.identifier(root["deployment_id"])
        try digest(root["manifest_sha256"]); try digest(root["configuration_sha256"])
        try WireSchema.nullableInteger(root["generation"])
        try WireSchema.choice(root["registration"], ["unregistered", "registered", "revoked"])
        try WireSchema.choice(root["connection"], ["never_seen", "connected", "stale", "disconnected"])
        try WireSchema.choice(root["authentication"], ["unverified", "verified", "stale"])
        try WireSchema.choice(root["authorization"], ["none", "limited"])
        try WireSchema.choice(root["deployment"], ["not_observed", "observed", "not_deployed", "synthetic_only"])
        try WireSchema.choice(root["readiness"], readinessStates)
        try WireSchema.choice(root["source"], ["none", "synthetic", "host_observation"])
        let checked = try timestamp(root["checked_at_ms"])
        for key in ["health_checked_at_ms", "ready_until_ms"] {
            if !(root[key] is NSNull) { _ = try timestamp(root[key]) }
        }
        if try WireSchema.string(root["readiness"]) == "ready" {
            guard try WireSchema.string(root["source"]) == "host_observation",
                  try WireSchema.string(root["registration"]) == "registered",
                  try WireSchema.string(root["connection"]) == "connected",
                  try WireSchema.string(root["authentication"]) == "verified",
                  try WireSchema.string(root["deployment"]) == "observed",
                  try WireSchema.integer(root["generation"]) > 0,
                  try timestamp(root["ready_until_ms"]) >= checked,
                  try timestamp(root["health_checked_at_ms"]) <= checked else { throw ARLError(code: "invalid_response") }
        } else if !(root["ready_until_ms"] is NSNull) { throw ARLError(code: "invalid_response") }
        return try JSONDecoder().decode(ServiceDeploymentStatus.self, from: data)
    }

    private static func document(_ data: Data) throws -> Any {
        guard data.count <= 120000 else { throw ARLError(code: "invalid_response") }
        return try JSONSerialization.jsonObject(with: data)
    }
    private static func serviceID(_ value: Any?) throws -> String {
        let string = try WireSchema.string(value, maximum: 64)
        guard string.range(of: "^service\\.[a-z][a-z0-9-]{0,47}$", options: .regularExpression) != nil else { throw ARLError(code: "invalid_response") }
        return string
    }
    private static func digest(_ value: Any?) throws {
        let string = try WireSchema.string(value, maximum: 64)
        guard string.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { throw ARLError(code: "invalid_response") }
    }
    private static func strings(_ value: Any?, count: Int, length: Int) throws {
        for item in try WireSchema.array(value, maximum: count) { _ = try WireSchema.string(item, maximum: length) }
    }
    private static func timestamp(_ value: Any?) throws -> Int {
        let result = try WireSchema.integer(value)
        guard result <= 1000000000000000 else { throw ARLError(code: "invalid_response") }; return result
    }
}
