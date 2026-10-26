import Foundation
import EventKit
import AppKit
import Darwin

// Only the existing signature-verified controlled host child reaches here.
// OS permission remains write-only; no event fetch/save is introduced.
@MainActor func prepareMioCalendarSession(policyPath:String,approvedSHA:String)async throws->NativeSession {
    MioStartupDiagnostics.phase("setup_seal")
    let a=try sealedActivation(policyPath,approvedSHA)
    let parent=getppid();let birth=try OwnedPID(parent);let requirement=try ownRequirement()
    MioStartupDiagnostics.phase("setup_parent");try verifyOwnedSignature(parent,requirement:requirement)
    MioStartupDiagnostics.phase("setup_journal");_ = try ConsumptionJournal(home:a.home)
    var store:EKEventStore?=nil
    func eventStore()->EKEventStore{if let store{return store};let value=EKEventStore();store=value;return value}
    func permission()->String {
        switch EKEventStore.authorizationStatus(for:.event) {
        case .notDetermined:return "not_determined"
        case .writeOnly:return "write_only"
        case .fullAccess:return "full_access"
        case .denied:return "denied"
        case .restricted:return "restricted"
        @unknown default:return "unknown"
        }
    }
    let services=MioSetupServices(observation:{MioSetupObservation(rawValue:EventKitEffects().lockState()) ?? .unknown},validate:{
        guard birth.current else{throw ReviewFault("caller_unverified")}
        try verifyOwnedSignature(parent,requirement:requirement)
        guard digest(try privateFile(policyPath))==approvedSHA,digest(try privateFile(a.profile))==a.profileSHA else{throw ReviewFault("activation_hash_changed")}
    },consumed:{access(a.home+"/session_consumed",F_OK)==0},phase:MioStartupDiagnostics.phase,review:nativeMioSetupReview,permission:permission,
    requestWriteOnly:{try await eventStore().requestWriteOnlyAccessToEvents()},target:{
        guard let calendar=eventStore().defaultCalendarForNewEvents,calendar.allowsContentModifications,
              calendar.allowedEntityTypes.contains(.event),safeText(calendar.title,limit:200),
              !calendar.calendarIdentifier.isEmpty,calendar.calendarIdentifier.utf8.count<=1024 else{throw ReviewFault("target_unavailable")}
        return MioSetupTarget(identifier:calendar.calendarIdentifier,name:calendar.title)
    },monotonic:{ProcessInfo.processInfo.systemUptime},wallMs:{Int64(Date().timeIntervalSince1970*1000)})
    let result=try await MioCalendarSetupFlow.prepare(services)
    return try NativeSession(jsonBytes(["schema_version":1,"target_alias":"approved_calendar","calendar_identifier":result.target.identifier,"expires_at_ms":result.expiresAtMs]))
}
