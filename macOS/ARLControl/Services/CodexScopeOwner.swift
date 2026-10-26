import Foundation
import Darwin

/// An explicit installation-management action, never normal startup, status or
/// recovery. Removing the scope keeps it absent until another reviewed action.
@MainActor enum CodexScopeOwner {
    static let filename = "codex-service-v1.json"
    nonisolated static let model = "gpt-6.1-sol"
    static let fields: Set<String> = ["schema_version", "caller", "provider", "model", "reasoning_effort", "service_tier",
        "scope_generation", "max_calls", "max_output_bytes", "core_manifest_sha256", "caller_requirement", "explicit_submission_only"]
    static func configuration(previous: Data?, manifest: String, requirement: String) throws -> Data {
        guard manifest.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
              !requirement.isEmpty, requirement.utf8.count <= 512 else { throw ARLError(code: "codex_configuration_invalid") }
        var generation = UUID().uuidString.lowercased()
        if let previous {
            let row = try OwnerReadJSON.object(previous, limit: 4096)
            guard Set(row.keys) == fields, OwnerReadWire.integer(row["schema_version"], 1),
                  row["caller"] as? String == "arl-control", row["provider"] as? String == "codex_app_server",
                  row["model"] as? String == model, row["reasoning_effort"] as? String == "xhigh",
                  row["service_tier"] as? String == "default", OwnerReadWire.integer(row["max_calls"], 32),
                  OwnerReadWire.integer(row["max_output_bytes"], 32768), OwnerReadWire.trueBoolean(row["explicit_submission_only"]),
                  let oldGeneration = row["scope_generation"] as? String,
                  UUID(uuidString: oldGeneration)?.uuidString.lowercased() == oldGeneration,
                  let oldManifest = row["core_manifest_sha256"] as? String, oldManifest.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
                  let oldRequirement = row["caller_requirement"] as? String, !oldRequirement.isEmpty, oldRequirement.utf8.count <= 512
            else { throw ARLError(code: "codex_scope_review_required") }
            if oldManifest == manifest && oldRequirement == requirement { generation = oldGeneration }
        }
        return try OwnerReadWire.encode(["schema_version": 1, "caller": "arl-control", "provider": "codex_app_server", "model": model,
            "reasoning_effort": "xhigh", "service_tier": "default", "scope_generation": generation, "max_calls": 32,
            "max_output_bytes": 32768, "core_manifest_sha256": manifest, "caller_requirement": requirement,
            "explicit_submission_only": true], limit: 4096)
    }
    static func configurationCandidate() throws -> [String: Any] {
        let home = SettingsService.defaultHome
        guard Bundle.main.object(forInfoDictionaryKey: "ARLCodexServicePolicyVersion") as? Int == 1,
              let manifest = Bundle.main.object(forInfoDictionaryKey: "ARLCoreRuntimeManifestSHA256") as? String,
              let resources = Bundle.main.resourceURL,
              RemindersNativeIO.hash(try Data(contentsOf: resources.appendingPathComponent("CoreRuntime/manifest.json"))) == manifest
        else { throw ARLError(code: "codex_native_owner_unavailable") }
        // Exact signed candidate; no UI, TCC, model handshake or state mutation.
        let authority = try OwnerReadAuthority.load(role: .owner)
        try RemindersNativeIO.privateDirectory(home.path)
        let path = home.appendingPathComponent(filename).path
        let previous = FileManager.default.fileExists(atPath: path) ? try RemindersNativeIO.privateFile(path, limit: 4096) : nil
        let bytes = try configuration(previous: previous, manifest: manifest, requirement: authority.own.requirement(seal: authority.seal))
        return ["schema_version": 1, "configuration_base64": bytes.base64EncodedString(), "configuration_sha256": RemindersNativeIO.hash(bytes),
            "previous_sha256": previous.map(RemindersNativeIO.hash) as Any? ?? NSNull(), "production_changed": false, "inference_started": false]
    }
}
