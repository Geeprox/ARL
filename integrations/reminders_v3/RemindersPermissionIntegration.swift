import Foundation
import CoreFoundation
import ARLRemindersCore
import ARLRemindersEventKit

/// Link alongside the owner's real v3 operation modules into the responsible
/// signed native helper. This candidate proposes preserving the existing bundle
/// ID local.arl.remindersbridge; old/new DR and TCC attribution require review.
/// No permissions/status from the legacy helper or raw Terminal are imported.
final class RemindersV3PermissionIntegration {
    static let capabilityIDs=Set(Request.operations.map { "apple.reminders.\($0).v3" })
    static let responsibleBundleID="local.arl.remindersbridge"
    private let operationAdapter: RemindersAdapter
    init(privateJournalDirectory:URL, repository:any ReminderRepository = EventKitRepository()) throws {
        // Repository init is lazy: no store construction or personal-data read.
        // Injection is trusted source composition for isolated acceptance tests,
        // never a request frame, executable argument or caller-selected backend.
        operationAdapter=RemindersAdapter(repository:repository,journal:try OperationJournal(directory:privateJournalDirectory))
    }
    static func permissionSnapshot(capabilityID:String) throws -> Data {
        guard capabilityIDs.contains(capabilityID) else { throw NativePermissionFault.unsupported }
        let identity=try NativePermissionIdentity.current(expectedBundle:responsibleBundleID)
        let result=classifyOwnerAuthorization(EventKitRepository.authorizationStatus())
        return try JSONEncoder().encode(NativePermissionEvidence(capability_id:capabilityID,identity:identity,
            permission_state:result.state,observed_at_ms:Int64(Date().timeIntervalSince1970*1000),preflight_code:result.code))
    }
    static func classifyOwnerAuthorization(_ status:String) -> NativePermissionResult {
        switch status {
        case "full_access": return .init(state:"authorized_full",code:"ok")
        case "not_determined": return .init(state:"not_determined",code:"not_determined")
        case "denied": return .init(state:"denied",code:"denied")
        case "restricted": return .init(state:"restricted",code:"restricted")
        default: return .init(state:"unknown",code:"permission_unknown")
        }
    }
    @MainActor static func requestFullAccess(capabilityID:String,admission:VerifiedPermissionAdmission,cancelled:@escaping @Sendable ()->Bool) async throws -> NativePermissionResult {
        guard capabilityIDs.contains(capabilityID),admission.kind == .remindersFull,
              admission.identity.helper_bundle_id == responsibleBundleID else { throw NativePermissionFault.unverified }
        // Same process, same identity. No target/list read and no execution grant.
        return try await requestNativePermission(admission,cancelled:cancelled)
    }
    enum RequestPhase: String { case validation, admission, request }
    // Native domain/code are diagnostics, never localized error text or content.
    static func requestFailureCode(_ error: Error, phase: RequestPhase) -> String {
        switch error {
        case NativePermissionFault.cancelled: return "cancelled"
        case NativePermissionFault.identity: return "permission_identity_changed"
        case NativePermissionFault.unsupported: return "permission_" + phase.rawValue + "_unsupported"
        case NativePermissionFault.unverified: return "permission_" + phase.rawValue + "_unverified"
        default:
            let native = error as NSError
            return "permission_" + phase.rawValue + "_failed:" + native.domain + ":" + String(native.code)
        }
    }
    static func requestOutcome(_ data: Data) -> (outcome: String, code: String)? {
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let outcome = raw["outcome"] as? String,
              ["completed", "denied", "restricted", "user_cancelled", "unavailable"].contains(outcome) else { return nil }
        let fallback = outcome == "completed" ? "ok" : outcome == "user_cancelled" ? "cancelled" : "permission_request_failed"
        return (outcome, raw["code"] as? String ?? fallback)
    }
    /// Concrete private handler for the authenticated native broker transport.
    /// auditToken comes from the kernel peer, never from frame JSON. Requirement
    /// and helper pin are immutable host composition, not caller declarations.
    @MainActor static func handlePermissionRequest(frame:Data,kernelPeerAuditToken:Data,pinnedControlRequirement:String,approvedHelperIdentity:NativePermissionIdentity,cancelled:@escaping @Sendable ()->Bool) async -> Data {
        var result:[String:Any]=["schema_version":1,"outcome":"unavailable","code":"permission_request_failed"]
        var phase = RequestPhase.validation
        do {
            guard frame.count <= 4096,let request=try JSONSerialization.jsonObject(with:frame) as? [String:Any],
                Set(request.keys)==["schema_version","capability_id","action","request_id"],
                (request["schema_version"] as? Int)==1,request["action"] as? String == "request",
                let capability=request["capability_id"] as? String,capabilityIDs.contains(capability),
                let text=request["request_id"] as? String,let requestID=UUID(uuidString:text),requestID.uuidString.lowercased()==text else { throw NativePermissionFault.unsupported }
            // Strict JSON booleans are NSNumber too; reject a forged true version.
            guard let version=request["schema_version"] as? NSNumber,CFGetTypeID(version) != CFBooleanGetTypeID(), !["f","d"].contains(String(cString:version.objCType)) else { throw NativePermissionFault.unsupported }
            phase = .admission
            let admission=try VerifiedPermissionAdmission(auditToken:kernelPeerAuditToken,pinnedControlRequirement:pinnedControlRequirement,requestID:requestID,kind:.remindersFull,approvedHelperIdentity:approvedHelperIdentity)
            phase = .request
            let state=try await requestFullAccess(capabilityID:capability,admission:admission,cancelled:cancelled)
            let outcome=state.state == "authorized_full" ? "completed" : state.state == "denied" ? "denied" : state.state == "restricted" ? "restricted" : "unavailable"
            result=["schema_version":1,"request_id":text,"capability_id":capability,"outcome":outcome,"code":state.code,
                "evidence":try JSONSerialization.jsonObject(with:permissionSnapshot(capabilityID:capability))]
        } catch NativePermissionFault.cancelled { result["outcome"]="user_cancelled"; result["code"]="cancelled" }
        catch { result["outcome"]="unavailable"; result["code"]=requestFailureCode(error,phase:phase) }
        return (try? JSONSerialization.data(withJSONObject:result,options:[.sortedKeys])) ?? Data()
    }
    func callReviewedOperation(requestJSON:Data,authority:HostAuthority) throws -> Data {
        let request=try Request.decode(requestJSON)
        let response=try operationAdapter.execute(request,authority:authority)
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        return try encoder.encode(response)
    }
}
