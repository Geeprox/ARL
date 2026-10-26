import Foundation

final class PermissionFixtureLease: NotesPermissionLease {
    func verify() throws {}
}
final class PermissionFixtureSurface: NotesPermissionSurface {
    var value: Int32
    var askCalls = 0
    init(_ value: Int32) { self.value = value }
    func verifyConfiguration() throws {}
    func query(event: UInt32, ask: Bool) throws -> Int32 {
        if ask { askCalls += 1; value = 0 }
        return value
    }
}
@main enum NotesPermissionNativeFixture {
    static func main() throws {
        var checks = 0
        for (statuses, expected) in [([Int32(0)], "authorized_automation"), ([-1744], "not_determined"),
                                     ([-1743], "denied"), ([-600], "unknown"), ([-1712], "unknown"), ([], "unknown")] {
            precondition(NotesPermissionObservation.classify(statuses).state == expected)
            checks += 1
        }
        for (initial, outcome, asked) in [(Int32(0), "authorized", 0), (-1743, "denied", 0),
                                         (-600, "target_not_running", 0), (-1744, "authorized", 3)] {
            let surface = PermissionFixtureSurface(initial)
            let id = UUID().uuidString.lowercased()
            var consumed = 0
            let plan = NotesPermissionRequestPlan(requestID: id, capability: .create, expiresAtMS: 100001)
            let session = try NotesPermissionRequestSession(plan: plan, surface: surface, verifyAdmission: {},
                consumeRequest: { _ in consumed += 1 }, acquireLease: { PermissionFixtureLease() }, clock: { 1 })
            let args: [String: Any] = ["action": "request", "request_id": id, "capability_id": "notes.create.v2"]
            let result = try session.request(args)
            precondition(result["outcome"] as? String == outcome && surface.askCalls == asked && consumed == 1)
            precondition(result["execution_grant_created"] as? Bool == false && result["notes_events_sent"] as? Int == 0)
            do { _ = try session.request(args); preconditionFailure("replayed") }
            catch let error as NotesFirstUseOutcomeFault { precondition(error.code == "operation_consumed") }
            precondition(surface.askCalls == asked && consumed == 1)
            checks += 2
        }
        let surface = PermissionFixtureSurface(0)
        do {
            _ = try NotesPermissionRequestSession(plan: .init(requestID: UUID().uuidString.lowercased(), capability: .read, expiresAtMS: 1),
                surface: surface, verifyAdmission: {}, consumeRequest: { _ in }, acquireLease: { PermissionFixtureLease() }, clock: { 1 })
            preconditionFailure("expired")
        } catch let error as NativeFault { precondition(error.code == "invalid_permission_plan") }
        precondition(surface.askCalls == 0); checks += 1
        print("notes_permission_native_checks=\(checks); real_permission_queries=0; real_notes_events=0; grants_created=0; synthetic_surfaces_only=true")
    }
}
