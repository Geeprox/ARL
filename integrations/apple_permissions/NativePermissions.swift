import Foundation
import EventKit
import AppKit
import ApplicationServices
import CoreGraphics
import Security
import CryptoKit

// Link this file INTO the actual responsible helper, never into ARLControl.
// No status path constructs EKEventStore, sends an event, reads content or asks TCC.
enum NativePermissionKind: Sendable {
    case calendarWrite, calendarFull, remindersFull, notesCreate, messagesSend
    case accessibility, screenRecording
    var bundle: String {
        switch self {
        case .calendarWrite, .calendarFull: "local.arl.mioapplebridge"
        case .remindersFull: "local.arl.remindersbridge"
        case .notesCreate: "local.arl.notesbridge"
        case .messagesSend: "local.arl.messagesbridge"
        case .accessibility, .screenRecording: "" // no implemented UI operation yet
        }
    }
    var capability: String {
        switch self {
        case .calendarWrite: "calendar.create.v1"
        case .calendarFull: "calendar.read.v1" // adapter only; not advertised by catalog
        case .remindersFull: "reminders.create.v1"
        case .notesCreate: "notes.create.v1"
        case .messagesSend: "messages.send.v1"
        case .accessibility: "ui.accessibility.v1"
        case .screenRecording: "ui.screen_recording.v1"
        }
    }
}

struct NativePermissionIdentity: Codable, Equatable, Sendable {
    let helper_bundle_id: String
    let executable_sha256: String
    let designated_requirement_sha256: String
    static func current(expectedBundle: String) throws -> Self {
        guard !expectedBundle.isEmpty, Bundle.main.bundleIdentifier == expectedBundle,
              let executable = Bundle.main.executableURL else { throw NativePermissionFault.identity }
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess else { throw NativePermissionFault.identity }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { throw NativePermissionFault.identity }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess, let requirement else { throw NativePermissionFault.identity }
        var requirementData: CFData?
        guard SecRequirementCopyData(requirement, [], &requirementData) == errSecSuccess, let requirementData else { throw NativePermissionFault.identity }
        return .init(helper_bundle_id: expectedBundle,
            executable_sha256: SHA256.hash(data: try Data(contentsOf: executable)).map { String(format:"%02x",$0) }.joined(),
            designated_requirement_sha256: SHA256.hash(data: requirementData as Data).map { String(format:"%02x",$0) }.joined())
    }
}
enum NativePermissionFault: Error { case identity, unsupported, unverified, cancelled }
struct NativePermissionEvidence: Encodable, Sendable {
    let schema_version = 1
    let capability_id: String
    let identity: NativePermissionIdentity
    let permission_state: String
    let observed_at_ms: Int64
    let preflight_code: String
    let prompts_requested = false
    let data_read = false
    let access_evidence = "untested"
}

struct NativePermissionResult: Equatable, Sendable {
    let state: String
    let code: String
    static func eventKit(_ status: EKAuthorizationStatus, reminders: Bool) -> Self {
        switch status {
        case .notDetermined: .init(state:"not_determined",code:"not_determined")
        case .denied: .init(state:"denied",code:"denied")
        case .restricted: .init(state:"restricted",code:"restricted")
        case .fullAccess: .init(state:"authorized_full",code:"ok")
        case .writeOnly: reminders ? .init(state:"unknown",code:"permission_unknown") : .init(state:"authorized_write_only",code:"ok")
        @unknown default: .init(state:"unknown",code:"permission_unknown")
        }
    }
    static func automation(_ statuses: [OSStatus]) -> Self {
        if statuses.contains(where: { ![noErr, -1743, -1744, -600].contains($0) }) { return .init(state:"unknown",code:"automation_unknown") }
        if statuses.contains(-1743) { return .init(state:"denied",code:"denied") }
        if statuses.contains(-1744) { return .init(state:"not_determined",code:"not_determined") }
        if statuses.contains(-600) { return .init(state:"unknown",code:"target_not_running") }
        if statuses.isEmpty || statuses.contains(where: { $0 != noErr }) { return .init(state:"unknown",code:"automation_unknown") }
        return .init(state:"authorized_automation",code:"ok")
    }
}

protocol PermissionPreflighting {
    func eventKit(reminders: Bool) -> EKAuthorizationStatus
    func automation(notes: Bool) -> [OSStatus]
    func accessibility() -> Bool
    func screenRecording() -> Bool
}
struct SystemPermissionPreflight: PermissionPreflighting {
    func eventKit(reminders: Bool) -> EKAuthorizationStatus { EKEventStore.authorizationStatus(for: reminders ? .reminder : .event) }
    func automation(notes: Bool) -> [OSStatus] {
        let target = NSAppleEventDescriptor(bundleIdentifier: notes ? "com.apple.Notes" : "com.apple.MobileSMS")
        // Exact event pair, no wildcard grant and no launch/AppleScript send.
        let events: [(UInt32, UInt32)] = notes ? [(0x636f7265,0x67657464),(0x636f7265,0x6372656c)] : [(0x69636874,0x73656e64)]
        return events.map { AEDeterminePermissionToAutomateTarget(target.aeDesc, $0.0, $0.1, false) }
    }
    func accessibility() -> Bool { AXIsProcessTrusted() }
    func screenRecording() -> Bool { CGPreflightScreenCaptureAccess() }
}

func permissionPreflight(_ kind: NativePermissionKind, api: any PermissionPreflighting = SystemPermissionPreflight(), implementedUIOperation: Bool = false) throws -> NativePermissionResult {
    switch kind {
    case .calendarWrite, .calendarFull: return .eventKit(api.eventKit(reminders:false),reminders:false)
    case .remindersFull: return .eventKit(api.eventKit(reminders:true),reminders:true)
    case .notesCreate: return .automation(api.automation(notes:true))
    case .messagesSend: return .automation(api.automation(notes:false))
    case .accessibility, .screenRecording:
        guard implementedUIOperation else { throw NativePermissionFault.unsupported }
        let allowed = kind == .accessibility ? api.accessibility() : api.screenRecording()
        // Bool false is not an exact denied/not-determined distinction.
        return .init(state:allowed ? "authorized_full" : "unknown",code:allowed ? "ok" : "permission_unknown")
    }
}

func nativePermissionSnapshot(_ kind: NativePermissionKind) throws -> Data {
    let identity = try NativePermissionIdentity.current(expectedBundle:kind.bundle)
    let result = try permissionPreflight(kind)
    return try JSONEncoder().encode(NativePermissionEvidence(capability_id:kind.capability,identity:identity,
        permission_state:result.state, observed_at_ms:Int64(Date().timeIntervalSince1970*1000),preflight_code:result.code))
}

// Construct ONLY in the existing signature-verified private native request handler.
// Reminders has one certificate-and-bundle-ID requirement; the other permission
// kinds retain their existing CDHash or Apple signing anchor/team formats.
// Neither the logical app ID nor request JSON supplies it. No command-line route
// constructs this admission object. This object never conveys an execution grant.
func verifiedPermissionRequirementFormat(_ requirement:String,kind:NativePermissionKind)->Bool {
    switch kind {
    case .remindersFull:
        // Keep this dependency-neutral: calendar/Notes helpers also compile
        // this file without RemindersNativeSocket.swift. A mismatched pin fails closed.
        return requirement == "identifier \"local.arl.control\" and anchor apple generic and certificate leaf = H\"CD85BA24208488935F9AC0BEC63E4BE6AAE189C4\" and certificate leaf[subject.OU] = \"LGZF25R84Z\" and certificate 1[field.1.2.840.113635.100.6.2.1] exists and certificate leaf[field.1.2.840.113635.100.6.1.12] exists"
    default:
        return requirement.range(of:#"^cdhash H"[a-fA-F0-9]{40,64}"$"#,options:.regularExpression) != nil || requirement.range(of:#"^identifier "[A-Za-z0-9.-]+" and anchor apple generic and certificate leaf\[subject\.OU\] = "[A-Z0-9]{10}"$"#,options:.regularExpression) != nil
    }
}

struct VerifiedPermissionAdmission: Sendable {
    let requestID: UUID
    let kind: NativePermissionKind
    let identity: NativePermissionIdentity
    init(auditToken: Data, pinnedControlRequirement: String, requestID: UUID,
         kind: NativePermissionKind, approvedHelperIdentity: NativePermissionIdentity) throws {
        guard auditToken.count == 32,
              verifiedPermissionRequirementFormat(pinnedControlRequirement,kind:kind) else { throw NativePermissionFault.unverified }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(pinnedControlRequirement as CFString,[],&requirement) == errSecSuccess, let requirement else { throw NativePermissionFault.unverified }
        var code: SecCode?
        let attributes = [kSecGuestAttributeAudit as String: auditToken] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil,attributes,[],&code) == errSecSuccess, let code,
              SecCodeCheckValidity(code,SecCSFlags(rawValue:kSecCSStrictValidate),requirement) == errSecSuccess,
              try NativePermissionIdentity.current(expectedBundle:kind.bundle) == approvedHelperIdentity else { throw NativePermissionFault.unverified }
        self.requestID=requestID; self.kind=kind; self.identity=approvedHelperIdentity
    }
}

// Real APIs for future reviewed narrow setup routes. Calendar.create UI continues
// to call the OWNER'S --authorize-session route so its private setup/grant boundary
// and default-calendar confirmation remain intact, rather than this bare adapter.
@MainActor func requestNativePermission(_ admission: VerifiedPermissionAdmission, cancelled: @escaping @Sendable () -> Bool) async throws -> NativePermissionResult {
    guard !cancelled(), try NativePermissionIdentity.current(expectedBundle:admission.kind.bundle) == admission.identity else { throw NativePermissionFault.cancelled }
    let usageKey: String
    switch admission.kind {
    case .calendarWrite: usageKey="NSCalendarsWriteOnlyAccessUsageDescription"
    case .calendarFull: usageKey="NSCalendarsFullAccessUsageDescription"
    case .remindersFull: usageKey="NSRemindersFullAccessUsageDescription"
    case .notesCreate, .messagesSend: usageKey="NSAppleEventsUsageDescription"
    case .accessibility, .screenRecording: throw NativePermissionFault.unsupported
    }
    guard let usage=Bundle.main.object(forInfoDictionaryKey:usageKey) as? String, !usage.isEmpty else { throw NativePermissionFault.unsupported }
    let before = try permissionPreflight(admission.kind)
    if before.state == "denied" || before.state == "restricted" { return before }
    switch admission.kind {
    case .calendarWrite:
        if before.state != "authorized_write_only" && before.state != "authorized_full" { _ = try await EKEventStore().requestWriteOnlyAccessToEvents() }
    case .calendarFull:
        if before.state != "authorized_full" { _ = try await EKEventStore().requestFullAccessToEvents() }
    case .remindersFull:
        if before.state != "authorized_full" { _ = try await EKEventStore().requestFullAccessToReminders() }
    case .notesCreate, .messagesSend:
        let notes = admission.kind == .notesCreate
        let status = await Task.detached {
            let target=NSAppleEventDescriptor(bundleIdentifier:notes ? "com.apple.Notes" : "com.apple.MobileSMS")
            let events:[(UInt32,UInt32)]=notes ? [(0x636f7265,0x67657464),(0x636f7265,0x6372656c)] : [(0x69636874,0x73656e64)]
            var results:[OSStatus]=[]
            for event in events {
                if cancelled() { break }
                let status=AEDeterminePermissionToAutomateTarget(target.aeDesc,event.0,event.1,true)
                results.append(status)
                if status != noErr { break }
            }
            return NativePermissionResult.automation(results)
        }.value
        guard !cancelled() else { throw NativePermissionFault.cancelled }; return status
    case .accessibility, .screenRecording:
        // No implemented UI operation in the catalog, so no blanket request.
        throw NativePermissionFault.unsupported
    }
    guard !cancelled() else { throw NativePermissionFault.cancelled }
    return try permissionPreflight(admission.kind)
}
