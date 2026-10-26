import Foundation
import ApplicationServices

enum NotesV2Catalog {
    static let dependencies: [(String, [UInt32])] = [
        ("notes.search.v1", [NotesEvents.get, NotesEvents.count]),
        ("notes.read.v1", [NotesEvents.get, NotesEvents.count]),
        ("notes.create.v2", [NotesEvents.get, NotesEvents.count, NotesEvents.make])]
    static func snapshot(identity: NotesV2ObservedIdentity, manualCapability: NotesPermissionCapability? = nil,
                         admitted: () throws -> Void = {}) throws -> [String: Any] {
        var rows: [[String: Any]] = []
        for (capability, events) in dependencies {
            #if NOTES_SYNTHETIC
            let state = "unknown", code = "synthetic_only"
            #else
            guard !Thread.isMainThread else { throw NativeFault("permission_request_requires_worker") }
            let target = NSAppleEventDescriptor(applicationURL: URL(fileURLWithPath: "/System/Applications/Notes.app"))
            var statuses: [OSStatus] = []
            for event in events {
                try admitted()
                statuses.append(AEDeterminePermissionToAutomateTarget(target.aeDesc, NotesEvents.core, event, false))
                try admitted()
            }
            let observation = NotesPermissionObservation.classify(statuses)
            let state = observation.state, code = observation.code
            #endif
            rows.append(["capability_id": capability, "permission_kind": "automation", "identity": identity.object,
                "observed_at_ms": Int64(Date().timeIntervalSince1970 * 1000), "permission_state": state, "preflight_code": code,
                "implementation_state": "source_only", "request_route_state": "requires_user_action",
                "request_source_implemented": true, "request_profile_admitted": manualCapability?.rawValue == capability,
                "readiness": state == "authorized_automation" ? "grant_inactive" : "needs_permission",
                "event_class": NotesEvents.core, "event_ids": events, "prompts_requested": false, "data_read": false])
        }
        return ["schema_version": 2, "records": rows, "synthetic": NotesV2Profile.synthetic,
            "actual_notes_access": false, "permission_requests_enabled": manualCapability != nil,
            "permission_request_source_implemented": true, "append_enabled": false, "attachment_write_enabled": false]
    }
}
