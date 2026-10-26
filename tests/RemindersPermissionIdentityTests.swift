import Foundation

@main enum RemindersPermissionIdentityTests {
    enum Failure: Error { case failed }
    @MainActor static func main() async throws {
        let current = "identifier \"local.arl.control\" and anchor apple generic and certificate leaf = H\"CD85BA24208488935F9AC0BEC63E4BE6AAE189C4\" and certificate leaf[subject.OU] = \"LGZF25R84Z\" and certificate 1[field.1.2.840.113635.100.6.2.1] exists and certificate leaf[field.1.2.840.113635.100.6.1.12] exists"
        let old = "identifier \"local.arl.control\" and certificate root = H\"859332b7fffbbbb33b80c7b78d30c27d2d81583f\""
        let widened = "identifier \"local.arl.control\" and anchor apple generic and certificate leaf[subject.OU] = \"LGZF25R84Z\""
        guard verifiedPermissionRequirementFormat(current, kind: .remindersFull),
              !verifiedPermissionRequirementFormat(old, kind: .remindersFull),
              !verifiedPermissionRequirementFormat(widened, kind: .remindersFull),
              !verifiedPermissionRequirementFormat(current + " or true", kind: .remindersFull),
              !verifiedPermissionRequirementFormat(current.replacingOccurrences(of: "LGZF25R84Z", with: "AAAAAAAAAA"), kind: .remindersFull) else { throw Failure.failed }
        let failure = RemindersV3PermissionIntegration.requestFailureCode(NSError(domain: "EKErrorDomain", code: 17), phase: .request)
        guard failure == "permission_request_failed:EKErrorDomain:17",
              RemindersV3PermissionIntegration.requestFailureCode(NativePermissionFault.unverified, phase: .admission) == "permission_admission_unverified",
              RemindersV3PermissionIntegration.requestFailureCode(NativePermissionFault.cancelled, phase: .request) == "cancelled" else { throw Failure.failed }
        let native = try JSONSerialization.data(withJSONObject: ["outcome":"unavailable","code":failure])
        guard let parsed = RemindersV3PermissionIntegration.requestOutcome(native), parsed.outcome == "unavailable", parsed.code == failure,
              RemindersV3PermissionIntegration.requestOutcome(Data("{\"outcome\":\"unavailable\"}".utf8))?.code != "ok",
              RemindersV3PermissionIntegration.requestOutcome(Data("{\"outcome\":\"saved_local\"}".utf8)) == nil else { throw Failure.failed }
        let identity = NativePermissionIdentity(helper_bundle_id:"local.arl.remindersbridge",executable_sha256:String(repeating:"0",count:64),designated_requirement_sha256:String(repeating:"0",count:64))
        let invalid = await RemindersV3PermissionIntegration.handlePermissionRequest(frame:Data("{}".utf8),kernelPeerAuditToken:Data(),pinnedControlRequirement:current,approvedHelperIdentity:identity,cancelled:{false})
        guard let rejected = RemindersV3PermissionIntegration.requestOutcome(invalid), rejected.outcome == "unavailable", rejected.code == "permission_validation_unsupported" else { throw Failure.failed }
        print("{\"status\":\"PASS\",\"checks\":12,\"OS_permissions_called\":false}")
    }
}
