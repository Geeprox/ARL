import Foundation

struct ServicePortalCatalog: Decodable, Sendable {
    struct Entry: Decodable, Identifiable, Sendable {
        let service_id: String
        let name: String
        let version: String
        let configured: Bool
        var id: String { service_id }
    }
    let schema_version: Int
    let kind: String
    let catalog_sha256: String
    let entries: [Entry]
}

struct ServicePortalReview: Sendable {
    let catalogSHA256: String
    let checkedAtMilliseconds: Int
    let plan: ServiceDeploymentPlan
    let statuses: [ServiceDeploymentStatus]
    let registry: [AppRegistration]
}

enum ServicePortalContract {
    static func decodeCatalog(_ data: Data) throws -> ServicePortalCatalog {
        let root = try WireSchema.object(document(data), ["schema_version", "kind", "catalog_sha256", "entries"])
        try WireSchema.constantInt(root["schema_version"], 1)
        try WireSchema.choice(root["kind"], ["service_portal_catalog"])
        _ = try digest(root["catalog_sha256"])
        let entries = try WireSchema.array(root["entries"], maximum: 32)
        var ids = Set<String>()
        for value in entries {
            let entry = try WireSchema.object(value, ["service_id", "name", "version", "configured"])
            guard ids.insert(try serviceID(entry["service_id"])).inserted else { throw ARLError(code: "invalid_response") }
            _ = try WireSchema.string(entry["name"])
            try WireSchema.identifier(entry["version"], maximum: 80)
            _ = try WireSchema.boolean(entry["configured"])
        }
        return try JSONDecoder().decode(ServicePortalCatalog.self, from: data)
    }

    static func decodeReview(_ data: Data, serviceID expectedID: String, catalogSHA256 expectedHash: String) throws -> ServicePortalReview {
        let root = try WireSchema.object(document(data), ["schema_version", "kind", "catalog_sha256", "checked_at_ms", "plan", "statuses", "registry"])
        try WireSchema.constantInt(root["schema_version"], 1)
        try WireSchema.choice(root["kind"], ["service_portal_review"])
        let hash = try digest(root["catalog_sha256"])
        guard hash == expectedHash else { throw ARLError(code: "service_catalog_changed") }
        let checked = try WireSchema.integer(root["checked_at_ms"])
        guard checked <= 1_000_000_000_000_000 else { throw ARLError(code: "invalid_response") }
        let plan = try ServiceDeploymentContract.decodePlan(bytes(root["plan"]))
        guard plan.root_service_id == expectedID else { throw ARLError(code: "invalid_response") }
        let statuses = try WireSchema.array(root["statuses"], maximum: 32).map { try ServiceDeploymentContract.decodeStatus(bytes($0)) }
        let registryValues = try WireSchema.array(root["registry"], maximum: 32)
        for value in registryValues { try validateApp(value) }
        let apps = try JSONDecoder().decode([ControlApp].self, from: bytes(registryValues))
        let expectedIDs = Set(plan.services.map(\.service_id))
        guard Set(statuses.map(\.id)) == expectedIDs, statuses.count == expectedIDs.count,
              Set(apps.map(\.id)) == expectedIDs, apps.count == expectedIDs.count else { throw ARLError(code: "invalid_response") }
        for entry in plan.services {
            guard let status = statuses.first(where: { $0.id == entry.id }), let app = apps.first(where: { $0.id == entry.id }),
                  status.checked_at_ms == checked,
                  status.target_id == entry.target_id, status.deployment_id == entry.deployment_id,
                  status.manifest_sha256 == entry.manifest_sha256, status.configuration_sha256 == entry.configuration_sha256,
                  status.version == entry.proposed_registration.version,
                  status.registration == app.registration, status.connection == app.connection,
                  status.authentication == app.authentication, status.authorization == app.authorization else {
                throw ARLError(code: "invalid_response")
            }
            // Before registration, AppRegistry holds its generic descriptor.
            if app.registration == "registered" {
                guard app.name == entry.proposed_registration.name, app.icon_ref == entry.proposed_registration.icon_ref,
                      app.version == entry.proposed_registration.version else { throw ARLError(code: "invalid_response") }
            }
        }
        return ServicePortalReview(catalogSHA256: hash, checkedAtMilliseconds: checked, plan: plan,
                                   statuses: statuses, registry: apps.map(\.presentation))
    }

    private static func document(_ data: Data) throws -> Any {
        guard data.count <= 120_000 else { throw ARLError(code: "invalid_response") }
        return try JSONSerialization.jsonObject(with: data)
    }
    private static func bytes(_ value: Any?) throws -> Data {
        guard let value, JSONSerialization.isValidJSONObject(value) else { throw ARLError(code: "invalid_response") }
        return try JSONSerialization.data(withJSONObject: value)
    }
    private static func serviceID(_ value: Any?) throws -> String {
        let id = try WireSchema.string(value, maximum: 64)
        guard id.range(of: "^service\\.[a-z][a-z0-9-]{0,47}$", options: .regularExpression) != nil else { throw ARLError(code: "invalid_response") }
        return id
    }
    private static func digest(_ value: Any?) throws -> String {
        let hash = try WireSchema.string(value, maximum: 64)
        guard hash.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { throw ARLError(code: "invalid_response") }
        return hash
    }
    private static func validateApp(_ value: Any) throws {
        let base: Set<String> = ["id", "name", "icon_ref", "version", "registration", "connection", "authentication",
                                              "authorization", "last_verified_at_ms", "last_seen_at_ms", "stale_after_ms", "advertised_capabilities", "authorized_tools"]
        let optional: Set<String> = ["handshake_session", "session_remaining_ms"]
        let keys = base.union(Set((value as? [String:Any])?.keys.map { $0 } ?? []).intersection(optional))
        let app = try WireSchema.object(value, keys)
        if let remaining = app["session_remaining_ms"], !(remaining is NSNull) {
            let n = try WireSchema.integer(remaining)
            guard n >= 0, n <= 30000 else { throw ARLError(code:"invalid_response") }
        }
        if let session = app["handshake_session"], !(session is NSNull) {
            let text = try WireSchema.string(session, maximum:64)
            guard text.count == 64, text.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { throw ARLError(code:"invalid_response") }
        }
        _ = try serviceID(app["id"])
        _ = try WireSchema.string(app["name"])
        try WireSchema.icon(app["icon_ref"])
        try WireSchema.nullableString(app["version"], maximum: 80)
        try WireSchema.choice(app["registration"], ["unregistered", "registered", "revoked"])
        try WireSchema.choice(app["connection"], ["never_seen", "connected", "stale", "disconnected"])
        try WireSchema.choice(app["authentication"], ["unverified", "verified", "stale"])
        try WireSchema.choice(app["authorization"], ["none"])
        for field in ["last_verified_at_ms", "last_seen_at_ms"] { try WireSchema.nullableInteger(app[field]) }
        let stale = try WireSchema.integer(app["stale_after_ms"])
        guard stale > 0, stale <= 30_000, try WireSchema.array(app["advertised_capabilities"], maximum: 0).isEmpty,
              try WireSchema.array(app["authorized_tools"], maximum: 0).isEmpty else { throw ARLError(code: "invalid_response") }
        if app["connection"] as? String == "connected" {
            guard app["registration"] as? String == "registered", app["authentication"] as? String == "verified",
                  !(app["last_verified_at_ms"] is NSNull), !(app["last_seen_at_ms"] is NSNull) else { throw ARLError(code: "invalid_response") }
        }
    }
}

/// UI request state only; transport and registry stay in SettingsService/ARL.
struct ServicePortalPresentation: Sendable {
    private(set) var catalog: MetadataFeature<ServicePortalCatalog> = .unsupported
    private(set) var review: MetadataFeature<ServicePortalReview> = .unsupported
    private(set) var reading = false
    private var generation = 0
    private var connected = false
    mutating func setConnection(_ value: Bool) {
        connected = value
        if !value { invalidate() }
    }
    mutating func beginRead() -> Int? {
        guard connected else { return nil }
        generation += 1
        reading = true
        review = .unavailable("reading")
        return generation
    }
    mutating func receiveCatalog(_ value: MetadataFeature<ServicePortalCatalog>, token: Int) -> Bool {
        guard token == generation else { return false }
        catalog = value
        if value.value == nil { review = .unavailable("catalog_unavailable"); reading = false; return false }
        return true
    }
    mutating func receiveReview(_ value: MetadataFeature<ServicePortalReview>, token: Int) {
        guard token == generation else { return }
        review = value
        reading = false
    }
    mutating func invalidate(_ code: String = "disconnected") {
        generation += 1
        catalog = .unavailable(code)
        review = .unavailable(code)
        reading = false
    }
}
