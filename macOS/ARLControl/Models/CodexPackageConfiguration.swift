import Foundation

struct CodexPackageRow: Codable, Equatable {
    var display_name: String
    var model: String
    var reasoning_effort: String
    var service_tier: String?
    var tier: String { service_tier ?? "default" }
    var selection: CodexExecutionSelection { .init(model:model, reasoning_effort:reasoning_effort, service_tier:tier) }
}
struct CodexPackagesFile: Codable {
    var schema_version: Int
    var revision: Int
    var catalog_version: String
    var packages: [String: CodexPackageRow]
}
struct CodexPackagesCatalog: Codable {
    var schema_version: Int
    var catalog_version: String
    var models: [CodexExecutionModel]
    var refreshed_at_ms: Int64?
    var current: CodexExecutionSelection
    func isFresh(at date: Date = Date()) -> Bool {
        guard let refreshed_at_ms else { return false }
        let age = date.timeIntervalSince1970 * 1000 - Double(refreshed_at_ms)
        return age >= -60000 && age < 90000
    }
    var execution: CodexExecutionCatalog {
        .init(schema_version:1, source:"app_server_model_list", models:models, selection_enabled:true, current:current)
    }
}

struct ModelSchedulerConfiguration: Codable { let schema_version: Int; let max_parallel: Int }
struct ModelSchedulerStatus: Codable, Sendable {
    let schema_version: Int; let max_parallel: Int; let running: Int; let queued: Int
    let queues: [String:Int]
}
