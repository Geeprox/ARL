import Foundation
import ApplicationServices
import Security

enum NotesPermissionCapability: String, CaseIterable {
    case search = "notes.search.v1", read = "notes.read.v1", create = "notes.create.v2"
    var events: [UInt32] { self == .create ? [NotesEvents.get, NotesEvents.count, NotesEvents.make] : [NotesEvents.get, NotesEvents.count] }
}

struct NotesPermissionRequestPlan {
    let requestID: String
    let capability: NotesPermissionCapability
    let expiresAtMS: Int64
    func validate(now: Int64) throws {
        guard uuid(requestID), expiresAtMS > now, expiresAtMS - now <= 120000 else { throw NativeFault("invalid_permission_plan") }
    }
}

struct NotesPermissionObservation {
    let state: String
    let code: String
    static func classify(_ statuses: [OSStatus]) -> Self {
        guard !statuses.isEmpty else { return .init(state: "unknown", code: "permission_unknown") }
        if statuses.contains(-1743) { return .init(state: "denied", code: "denied") }
        if statuses.contains(-600) { return .init(state: "unknown", code: "target_not_running") }
        if statuses.contains(where: { ![noErr, -1744].contains($0) }) { return .init(state: "unknown", code: "permission_unknown") }
        if statuses.contains(-1744) { return .init(state: "not_determined", code: "not_determined") }
        if statuses.allSatisfy({ $0 == noErr }) { return .init(state: "authorized_automation", code: "ok") }
        return .init(state: "unknown", code: "permission_unknown")
    }
}

// Configuration checks are pure over observed signing/Info.plist facts and
// reused by no-effect fixtures. Boolean entitlement types are checked exactly.
enum NotesPermissionHostConfiguration {
    static let usage = "ARL requests permission to control Notes for reviewed search, read and create operations. Note creation requires your separate approval."
    static func validate(usage: Any?, entitlements: [String: Any], onMainThread: Bool) throws {
        guard !onMainThread else { throw NativeFault("permission_request_requires_worker") }
        guard let text = usage as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf8.count <= 1024 else { throw NativeFault("usage_description_missing") }
        guard let entitled = entitlements["com.apple.security.automation.apple-events"] as? NSNumber,
              CFGetTypeID(entitled) == CFBooleanGetTypeID(), entitled.boolValue else { throw NativeFault("automation_entitlement_missing") }
        // This candidate is a non-App-Sandbox helper. A sandboxed enclosing
        // build needs separate reviewed target-access entitlements; none guessed.
        if let value = entitlements["com.apple.security.app-sandbox"] {
            guard let sandbox = value as? NSNumber, CFGetTypeID(sandbox) == CFBooleanGetTypeID(), !sandbox.boolValue else {
                throw NativeFault("sandbox_configuration_unsupported")
            }
        }
    }
    static func verifyActualHost() throws {
        var code: SecCode?; var staticCode: SecStaticCode?; var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let values = info as? [String: Any] else { throw NativeFault("helper_modified") }
        try validate(usage: Bundle.main.object(forInfoDictionaryKey: "NSAppleEventsUsageDescription"),
            entitlements: values[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:], onMainThread: Thread.isMainThread)
    }
}

protocol NotesPermissionSurface: AnyObject {
    func verifyConfiguration() throws
    func query(event: UInt32, ask: Bool) throws -> OSStatus
}

final class NativeNotesPermissionSurface: NotesPermissionSurface {
    // Construct the pure fixed address before request admission; query has no
    // filesystem/descriptor preparation between final admission and the API.
    private let target = NSAppleEventDescriptor(applicationURL: URL(fileURLWithPath: "/System/Applications/Notes.app"))
    func verifyConfiguration() throws { try NotesPermissionHostConfiguration.verifyActualHost() }
    func query(event: UInt32, ask: Bool) throws -> OSStatus {
        guard [NotesEvents.get, NotesEvents.count, NotesEvents.make].contains(event), !Thread.isMainThread else {
            throw NativeFault("unsupported_permission_dependency")
        }
        // Public permission API only. No Apple event is sent, no data accessed,
        // no wildcard, no launch and no remote/caller-selected target is used.
        return AEDeterminePermissionToAutomateTarget(target.aeDesc, NotesEvents.core, event, ask)
    }
}

#if NOTES_SYNTHETIC
final class SyntheticNotesPermissionSurface: NotesPermissionSurface {
    private var authorized = false
    func verifyConfiguration() throws {} // compiled fixture; never OS evidence
    func query(event: UInt32, ask: Bool) throws -> OSStatus {
        if ask { authorized = true }
        return authorized ? noErr : -1744
    }
}
#endif

// A separate sealed manual setup session. It can never produce a Notes session,
// note ID or execution grant. The authenticated native bootstrap owns all hooks.
final class NotesPermissionRequestSession {
    let plan: NotesPermissionRequestPlan
    private let surface: NotesPermissionSurface
    private let verifyAdmission: () throws -> Void
    private let consumeRequest: (String) throws -> Void
    private let acquireLease: () throws -> NotesPermissionLease
    private let clock: () -> Int64
    private let lock = NSLock()
    private var attempted = false
    private(set) var requestStarted = false
    init(plan: NotesPermissionRequestPlan, surface: NotesPermissionSurface, verifyAdmission: @escaping () throws -> Void,
         consumeRequest: @escaping (String) throws -> Void, acquireLease: @escaping () throws -> NotesPermissionLease,
         clock: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) throws {
        try plan.validate(now: clock()); self.plan = plan; self.surface = surface
        self.verifyAdmission = verifyAdmission; self.consumeRequest = consumeRequest; self.clock = clock
        self.acquireLease = acquireLease
    }
    private func admitted() throws {
        guard clock() < plan.expiresAtMS else { throw NativeFault("grant_expired") }
        try verifyAdmission()
        guard clock() < plan.expiresAtMS else { throw NativeFault("grant_expired") }
    }
    func request(_ args: [String: Any]) throws -> [String: Any] {
        guard lock.try() else { throw NotesFirstUseOutcomeFault(code: "busy", indeterminate: false) }
        defer { lock.unlock() } // Held until the OS call returns, including late cancellation.
        // Refuse a second invocation before entering the previous attempt's
        // outcome classifier. A past permission request cannot make this
        // no-effect replay refusal indeterminate.
        guard !attempted else { throw NotesFirstUseOutcomeFault(code: "operation_consumed", indeterminate: false) }
        do {
            guard Set(args.keys) == Set(["action", "request_id", "capability_id"]), args["action"] as? String == "request",
                  args["request_id"] as? String == plan.requestID, args["capability_id"] as? String == plan.capability.rawValue else { throw NativeFault("permission_proposal_mismatch") }
            try admitted(); try surface.verifyConfiguration(); try admitted()
            let lease = try acquireLease()
            defer { withExtendedLifetime(lease) {} }
            try lease.verify(); try admitted()
            attempted = true // Even a partial journal failure is never replayed.
            try consumeRequest(plan.requestID); try admitted()
            var before: [OSStatus] = []
            for event in plan.capability.events {
                try admitted(); try lease.verify(); try admitted()
                before.append(try surface.query(event: event, ask: false)); try admitted()
            }
            let initial = NotesPermissionObservation.classify(before)
            var requested: [OSStatus] = []
            if initial.state == "not_determined" {
                for event in plan.capability.events {
                    try admitted(); try surface.verifyConfiguration(); try lease.verify(); try admitted()
                    requestStarted = true // Outcome may change even if the reply is lost.
                    let status = try surface.query(event: event, ask: true)
                    requested.append(status); try admitted()
                    if status != noErr { break }
                }
            }
            // Denied, unknown and not-running states never launch or try an
            // alternative path. The manual UI can show a bounded explanation.
            var after: [OSStatus] = []
            for event in plan.capability.events {
                try admitted(); try lease.verify(); try admitted()
                after.append(try surface.query(event: event, ask: false)); try admitted()
            }
            let final = NotesPermissionObservation.classify(after)
            try admitted()
            let outcome = final.state == "authorized_automation" ? "authorized" : final.code
            return ["schema_version": 1, "request_id": plan.requestID, "capability_id": plan.capability.rawValue,
                "action": "request", "outcome": outcome, "permission_state": final.state, "preflight_code": final.code,
                "request_attempted": requestStarted, "prompts_requested": requestStarted, "prompt_presentation": "not_observed",
                "execution_grant_created": false, "notes_events_sent": 0, "data_read": false]
        } catch {
            let code = (error as? NativeFault)?.code ?? (error as? ReviewFault)?.code ?? "permission_request_failed"
            throw NotesFirstUseOutcomeFault(code: requestStarted ? "permission_needs_review" : code, indeterminate: requestStarted)
        }
    }
}
