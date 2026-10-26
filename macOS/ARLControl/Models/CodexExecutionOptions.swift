import Foundation

struct CodexExecutionSelection: Codable, Equatable, Sendable {
    let model: String
    var reasoning_effort: String
    var service_tier: String
    var fast: Bool { service_tier == "fast" }
    var summary: String { "\(model) · \(CodexEffortOption.title(reasoning_effort)) · \(fast ? "加速" : "标准")" }
    var isWellFormed: Bool {
        Self.identifier(model, maximum: 150) && Self.identifier(reasoning_effort, maximum: 40)
            && ["default", "fast"].contains(service_tier)
    }
    static func identifier(_ value: String, maximum: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= maximum && value.range(of: "^[A-Za-z0-9][A-Za-z0-9._/-]*$", options: .regularExpression) != nil
    }
}

struct CodexEffortOption: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let description: String
    var title: String { Self.title(id) }
    static func title(_ id: String) -> String {
        ["none":"无", "minimal":"极简", "low":"低", "medium":"中", "high":"高", "xhigh":"超高", "max":"最大", "ultra":"Ultra"][id] ?? id
    }
}

struct CodexExecutionModel: Codable, Identifiable, Equatable, Sendable {
    let model: String
    let display_name: String
    let description: String
    let default_effort: String
    let efforts: [CodexEffortOption]
    let fast_available: Bool
    let fast_description: String
    var id: String { model }
    func permits(_ selection: CodexExecutionSelection) -> Bool {
        selection.model == model && efforts.contains { $0.id == selection.reasoning_effort }
            && (selection.service_tier == "default" || selection.service_tier == "fast" && fast_available)
    }
    /// Explicit model choice keeps a supported effort and otherwise selects the
    /// new model's advertised default. Never carry Fast into an unsupported model.
    func selecting(from previous: CodexExecutionSelection?) -> CodexExecutionSelection {
        .init(model: model, reasoning_effort: efforts.contains { $0.id == previous?.reasoning_effort } ? previous!.reasoning_effort : default_effort,
              service_tier: previous?.fast == true && fast_available ? "fast" : "default")
    }
}

struct CodexExecutionCatalog: Codable, Sendable {
    let schema_version: Int
    let source: String
    let models: [CodexExecutionModel]
    let selection_enabled: Bool
    let current: CodexExecutionSelection
    var isValid: Bool {
        schema_version == 1 && ["app_server_model_list", "test_double"].contains(source)
            && current.isWellFormed && Set(models.map(\.id)).count == models.count
            && models.allSatisfy { model in
                CodexExecutionSelection.identifier(model.model, maximum: 150) && model.display_name.utf8.count <= 200
                    && model.description.utf8.count <= 2048 && model.fast_description.utf8.count <= 2048
                    && !model.efforts.isEmpty && Set(model.efforts.map(\.id)).count == model.efforts.count
                    && model.efforts.contains { $0.id == model.default_effort }
                    && model.efforts.allSatisfy { CodexExecutionSelection.identifier($0.id, maximum: 40) && $0.description.utf8.count <= 1024 }
            }
    }
    func permits(_ selection: CodexExecutionSelection) -> Bool {
        isValid && selection_enabled && models.contains { $0.permits(selection) }
    }
}
