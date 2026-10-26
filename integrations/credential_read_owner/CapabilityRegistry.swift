import Foundation

/// Internal metadata expands into separate, named MCP tools. No generic execute tool.
struct CapabilityAction {
    let capability: String
    let action: String
    let description: String
    let inputSchema: [String: Any]
    let outputSchema: [String: Any]
    let readOnly: Bool
    let risk: String
    let requiresConfirmation: Bool
    var toolName: String { capability + "_" + action }
    var descriptor: [String: Any] {
        ["name": toolName, "description": description, "inputSchema": inputSchema,
         "outputSchema": outputSchema,
         "annotations": ["readOnlyHint": readOnly, "destructiveHint": !readOnly,
                         "idempotentHint": readOnly, "openWorldHint": true],
         "_meta": ["arl/capability": capability, "arl/version": 1,
                   "arl/risk": risk, "arl/requiresConfirmation": requiresConfirmation]]
    }
}

struct CapabilityRegistry {
    private(set) var tools: [[String: Any]] = []
    private var names = Set<String>()
    init(legacy: [[String: Any]] = []) throws {
        // Keep all existing descriptors byte-for-byte equivalent as JSON objects.
        for tool in legacy { try append(tool) }
    }
    mutating func register(_ actions: [CapabilityAction]) throws {
        for action in actions { try append(action.descriptor) }
    }
    mutating func append(_ descriptor: [String: Any]) throws {
        guard let name = descriptor["name"] as? String,
              name.range(of: "^[a-z][a-z0-9_]{1,79}$", options: .regularExpression) != nil,
              descriptor["inputSchema"] is [String: Any],
              names.insert(name).inserted else { throw OwnerReadFault.invalid }
        tools.append(descriptor)
    }
}
