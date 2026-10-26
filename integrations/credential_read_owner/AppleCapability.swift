import Foundation

/// Transport identity is not a business grant. Every new task still requires
/// the existing native confirmation for its exact title and default list.
enum AppleCapability {
    static let reminderCreate = "mio_reminders_create"
    static let reminderStatus = "mio_reminders_operation_status"
    static let names: Set<String> = [reminderCreate, reminderStatus]
    enum Action: Equatable, Sendable { case createReminder, reminderStatus }
    struct Request: Sendable { let action: Action; let taskID: String; let title: String? }
    static func request(tool: String, argumentsJSON: Data) throws -> Request {
        let args = try OwnerReadJSON.object(argumentsJSON, limit: OwnerReadWire.requestLimit)
        let create = tool == reminderCreate
        guard names.contains(tool), Set(args.keys) == (create ? ["task_id", "title"] : ["task_id"]),
              let raw = args["task_id"] as? String, raw.utf8.count == 36, let id = UUID(uuidString: raw)
        else { throw OwnerReadFault.invalid }
        let title = args["title"] as? String
        guard !create || title != nil && title!.utf8.count <= 1200 else { throw OwnerReadFault.invalid }
        return .init(action: create ? .createReminder : .reminderStatus, taskID: id.uuidString.lowercased(), title: title)
    }
    static var descriptors: [[String: Any]] {
        let id: [String: Any] = ["type":"string", "format":"uuid", "minLength":36, "maxLength":36,
            "description":"Original stable task UUID. Preserve it for every status/repeated call; never change it after an unknown result."]
        func descriptor(_ name: String, create: Bool) -> [String: Any] {
            var properties: [String: Any] = ["task_id":id]
            if create { properties["title"] = ["type":"string", "minLength":1, "maxLength":300] }
            return ["name":name,
                "description":create
                    ? "Create one reminder through ARL's existing native task consumer. Local confirmation must approve this exact title and existing default list once; this tool never requests OS permission. Repeated task_id only inspects the durable record, including drafts, and never resumes or repeats a save. saved_local does not verify cloud sync. Due date, alarms, recurrence, new lists, edits and deletes are not supported here."
                    : "Read the durable record of the original task_id. Does not fetch reminder bodies from EventKit, start the helper, request permission, create a task, resume a draft or retry an effect.",
                "inputSchema":["type":"object", "additionalProperties":false,
                    "required":create ? ["task_id","title"] : ["task_id"], "properties":properties],
                "annotations":["readOnlyHint":!create, "destructiveHint":false, "idempotentHint":true, "openWorldHint":false],
                "_meta":["arl/capability":"apple.reminders.task", "arl/version":1, "arl/requiresConfirmation":create, "arl/automaticReplay":false]]
        }
        return [descriptor(reminderCreate, create:true), descriptor(reminderStatus, create:false)]
    }
    static func validDescriptor(_ value: [String: Any]) -> Bool {
        guard let name = value["name"] as? String, let expected = descriptors.first(where: { $0["name"] as? String == name }),
              let actual = try? OwnerReadWire.encode(value, limit:OwnerReadWire.requestLimit),
              let exact = try? OwnerReadWire.encode(expected, limit:OwnerReadWire.requestLimit) else { return false }
        return actual == exact
    }
}
