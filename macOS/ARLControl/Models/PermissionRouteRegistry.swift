import Foundation

/// Presentation/routing only. These entries never create native admission.
enum PermissionRouteRegistry {
    static func section(for capability: String) -> ControlSection? {
        if ["messages.send.v1", "messages.receive.v1"].contains(capability) { return .messages }
        if ["notes.search.v1", "notes.read.v1", "notes.create.v2"].contains(capability) { return .notes }
        if RemindersFirstFrame.operationIDs.contains(capability) || capability == "reminders.create.v1" { return .reminders }
        if capability == "keychain.item_access.v1" { return .credentials }
        return nil
    }
    static func usesRuntimeManualRoute(_ capability: String) -> Bool {
        ApplePermissionSnapshot.ids.contains(capability) && section(for: capability) == nil
            && !["notes.create.v1", "notes.append.v1", "notes.edit.v1"].contains(capability)
    }
    static func isDedicated(_ capability: String) -> Bool {
        section(for: capability) != nil || ["notes.create.v1", "notes.append.v1", "notes.edit.v1"].contains(capability)
    }
}
