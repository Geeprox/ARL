import Foundation
import CryptoKit

struct CallerGrant {
    let operations:Set<AppleOperation>;let targets:Set<String>;let nativeReview:Bool
    let workflowIssuers:Set<String>;let maxEffects:Int
    let delegatedTunnel:Bool;let calendarOSTCCOnly:Bool
    init(operations:Set<AppleOperation>,targets:Set<String>,nativeReview:Bool,workflowIssuers:Set<String>,maxEffects:Int,delegatedTunnel:Bool=false,calendarOSTCCOnly:Bool=false){
        self.operations=operations;self.targets=targets;self.nativeReview=nativeReview;self.workflowIssuers=workflowIssuers;self.maxEffects=maxEffects;self.delegatedTunnel=delegatedTunnel;self.calendarOSTCCOnly=calendarOSTCCOnly
    }
}
struct ReviewPolicy {
    let epoch:Int64;let callers:[String:CallerGrant];let targets:[String:TargetBinding]
    let issuerPublicKeys:[String:Data];let lockedQualified:Set<AppleOperation>
}
struct ReviewClock {
    let nowMS:()->Int64;let monotonic:()->Double
    static var system:ReviewClock{ReviewClock(nowMS:{Int64(Date().timeIntervalSince1970*1000)},monotonic:{ProcessInfo.processInfo.systemUptime})}
}
struct SignedWorkflowPermit {let issuer:String;let payload:Data;let signature:Data}
private struct VerifiedPermit {let id:String;let expiry:Int64;let epoch:Int64}
protocol AppleEffects {
    func authorization(_ operation:AppleOperation)->String
    func lockState()->String
    func resolve(_ binding:TargetBinding)throws->ResolvedTarget
    func save(_ proposal:AppleProposal,target:ResolvedTarget)throws->String
}
@MainActor protocol NativeReviewer {func confirm(_ display:ReviewDisplay)->Bool}

final class AppleApprovalEngine {
    private let journal:ConsumptionJournal
    private let policy:()->ReviewPolicy?
    private let clock:ReviewClock
    // Default-disabled; policy is a trusted composition, never decoded from RPC.
    init(journal:ConsumptionJournal,policy:@escaping()->ReviewPolicy?={nil},clock:ReviewClock = .system){self.journal=journal;self.policy=policy;self.clock=clock}
    private func authorized(_ proposal:AppleProposal,caller:AuthenticatedCaller,epoch:Int64?=nil)throws->(ReviewPolicy,CallerGrant,TargetBinding) {
        guard caller.isCurrent(),caller.subject==proposal.callerID else{throw ReviewFault("caller_unverified")}
        guard let current=policy(),current.epoch>=1,epoch==nil || epoch==current.epoch,
              let grant=current.callers[caller.subject],grant.operations.contains(proposal.operation),
              grant.targets.contains(proposal.targetAlias),(1...16).contains(grant.maxEffects),
              let binding=current.targets[proposal.targetAlias],binding.alias==proposal.targetAlias,
              binding.operation==proposal.operation,!binding.identifier.isEmpty,binding.identifier.utf8.count<=1024 else{throw ReviewFault("capability_not_granted")}
        return (current,grant,binding)
    }
    private func ready(_ proposal:AppleProposal,effects:AppleEffects,policy:ReviewPolicy,native:Bool)throws {
        let auth=effects.authorization(proposal.operation)
        guard auth=="full_access" || (proposal.operation == .calendar && auth=="write_only") else{throw ReviewFault("needs_permission")}
        // Sealed/native-composition-only scope; not an observed unlock state.
        // Only this explicitly delegated Calendar policy omits app-level lock
        // admission. Actual OS permission/error handling remains mandatory.
        if !native,proposal.operation == .calendar,
           let grant=policy.callers[proposal.callerID],grant.delegatedTunnel,grant.calendarOSTCCOnly{return}
        let lock=effects.lockState()
        guard lock=="unlocked" || (!native && lock=="locked" && policy.lockedQualified.contains(proposal.operation)) else{
            throw ReviewFault(lock=="locked" ? "needs_unlock":"lock_state_unknown")
        }
    }
    private func resolve(_ binding:TargetBinding,effects:AppleEffects)throws->ResolvedTarget {
        let target=try effects.resolve(binding)
        guard target.identifier==binding.identifier,safeText(target.name,limit:200) else{throw ReviewFault("target_changed")}
        return target
    }
    private func verify(_ permit:SignedWorkflowPermit,proposal:AppleProposal,binding:TargetBinding,policy:ReviewPolicy,grant:CallerGrant)throws->VerifiedPermit {
        guard identifier(permit.issuer),grant.workflowIssuers.contains(permit.issuer),
              let bytes=policy.issuerPublicKeys[permit.issuer],let key=try? Curve25519.Signing.PublicKey(rawRepresentation:bytes),
              permit.payload.count<=8192,permit.signature.count==64,key.isValidSignature(permit.signature,for:permit.payload) else{throw ReviewFault("permit_unverified")}
        let p=try flatObject(permit.payload,limit:8192)
        guard Set(p.keys)==Set(["schema_version","issuer_id","permit_id","workflow_id","caller_id","operation_id","tool","request_sha256","target_alias","target_binding_sha256","issued_at_ms","expires_at_ms","max_effects","policy_epoch"]),
              integer(p["schema_version"])==1,p["issuer_id"] as? String==permit.issuer,
              let id=p["permit_id"] as? String,uuid(id),let workflow=p["workflow_id"] as? String,uuid(workflow),
              p["caller_id"] as? String==proposal.callerID,p["operation_id"] as? String==proposal.operationID,
              p["tool"] as? String==proposal.operation.rawValue,p["request_sha256"] as? String==proposal.rawHash,
              p["target_alias"] as? String==binding.alias,p["target_binding_sha256"] as? String==binding.hash,
              integer(p["max_effects"])==1,integer(p["policy_epoch"])==policy.epoch,
              let issued=integer(p["issued_at_ms"]),let expiry=integer(p["expires_at_ms"]) else{throw ReviewFault("permit_binding_mismatch")}
        let now=clock.nowMS()
        guard issued>=now-60000,issued<=now+5000,expiry>now,expiry>issued,expiry<=issued+600000 else{throw ReviewFault("permit_expired")}
        return VerifiedPermit(id:id,expiry:expiry,epoch:policy.epoch)
    }
    @MainActor func performNative(_ data:Data,caller:AuthenticatedCaller,reviewer:NativeReviewer,effects:AppleEffects,cancelled:()->Bool={false})throws->[String:Any] {
        let proposal=try AppleProposal(data);let (initial,grant,binding)=try authorized(proposal,caller:caller)
        guard grant.nativeReview else{throw ReviewFault("native_review_not_granted")}
        guard !cancelled() else{throw ReviewFault("cancelled_before_effect")}
        try ready(proposal,effects:effects,policy:initial,native:true)
        let expiry=clock.nowMS()+120000;let deadline=clock.monotonic()+20
        try journal.consume(operationID:proposal.operationID,permitID:UUID().uuidString.lowercased(),subject:caller.subject,epoch:initial.epoch,budget:grant.maxEffects)
        let target=try resolve(binding,effects:effects)
        guard reviewer.confirm(ReviewDisplay(proposal:proposal,target:target)) else{throw ReviewFault("user_cancelled")}
        return try commit(proposal,caller:caller,binding:binding,epoch:initial.epoch,expiry:expiry,deadline:deadline,native:true,issuer:nil,effects:effects,cancelled:cancelled)
    }
    // A verified permit replaces local UI ONLY for a specifically granted issuer.
    // No NativeReviewer dependency exists on this headless path.
    func performWorkflow(_ data:Data,permit:SignedWorkflowPermit,caller:AuthenticatedCaller,effects:AppleEffects,cancelled:()->Bool={false})throws->[String:Any] {
        let proposal=try AppleProposal(data);let (initial,grant,binding)=try authorized(proposal,caller:caller)
        let verified=try verify(permit,proposal:proposal,binding:binding,policy:initial,grant:grant)
        guard !cancelled() else{throw ReviewFault("cancelled_before_effect")}
        try ready(proposal,effects:effects,policy:initial,native:false)
        let deadline=clock.monotonic()+max(0,min(600,Double(verified.expiry-clock.nowMS())/1000))
        try journal.consume(operationID:proposal.operationID,permitID:verified.id,subject:caller.subject,epoch:initial.epoch,budget:grant.maxEffects)
        return try commit(proposal,caller:caller,binding:binding,epoch:verified.epoch,expiry:verified.expiry,deadline:deadline,native:false,issuer:(permit.issuer,initial.issuerPublicKeys[permit.issuer]!),effects:effects,cancelled:cancelled)
    }
    // Setup-approved private-tunnel delegation, NOT a human/chat approval receipt.
    // Caller is kernel-verified by the controlled Mio host; RPC cannot mint it.
    func performDelegated(_ data:Data,caller:AuthenticatedCaller,expiresAtMS:Int64,policyEpoch:Int64,effects:AppleEffects,cancelled:()->Bool={false})throws->[String:Any] {
        let proposal=try AppleProposal(data);let (initial,grant,binding)=try authorized(proposal,caller:caller,epoch:policyEpoch)
        guard grant.delegatedTunnel else{throw ReviewFault("delegation_not_granted")}
        let remaining=expiresAtMS-clock.nowMS()
        guard remaining>0,remaining<=60000 else{throw ReviewFault("approval_expired")}
        guard !cancelled() else{throw ReviewFault("cancelled_before_effect")}
        try ready(proposal,effects:effects,policy:initial,native:false)
        let deadline=clock.monotonic()+min(20,Double(remaining)/1000)
        try journal.consume(operationID:proposal.operationID,permitID:UUID().uuidString.lowercased(),subject:caller.subject,epoch:initial.epoch,budget:grant.maxEffects)
        var result=try commit(proposal,caller:caller,binding:binding,epoch:initial.epoch,expiry:expiresAtMS,deadline:deadline,native:false,issuer:nil,delegated:true,effects:effects,cancelled:cancelled)
        result["authority"]="setup_delegated_private_tunnel";return result
    }
    private func commit(_ proposal:AppleProposal,caller:AuthenticatedCaller,binding:TargetBinding,epoch:Int64,expiry:Int64,deadline:Double,native:Bool,issuer:(String,Data)?,delegated:Bool=false,effects:AppleEffects,cancelled:()->Bool)throws->[String:Any] {
        guard clock.nowMS()<expiry,clock.monotonic()<deadline else{throw ReviewFault("approval_expired")}
        guard !cancelled() else{throw ReviewFault("cancelled_before_effect")}
        let (current,grant,nowBinding)=try authorized(proposal,caller:caller,epoch:epoch)
        guard nowBinding.hash==binding.hash,(native ? grant.nativeReview:(delegated ? grant.delegatedTunnel:!grant.workflowIssuers.isEmpty)) else{throw ReviewFault("capability_not_granted")}
        if let (id,key)=issuer{guard grant.workflowIssuers.contains(id),current.issuerPublicKeys[id]==key else{throw ReviewFault("permit_unverified")}}
        try ready(proposal,effects:effects,policy:current,native:native)
        let target=try resolve(binding,effects:effects)
        guard !cancelled(),clock.nowMS()<expiry,clock.monotonic()<deadline else{throw ReviewFault("cancelled_or_expired_before_effect")}
        let (last,lastGrant,lastBinding)=try authorized(proposal,caller:caller,epoch:epoch)
        guard lastBinding.hash==binding.hash,(!native || lastGrant.nativeReview),(!delegated || lastGrant.delegatedTunnel) else{throw ReviewFault("capability_not_granted")}
        if let (id,key)=issuer{guard lastGrant.workflowIssuers.contains(id),last.issuerPublicKeys[id]==key else{throw ReviewFault("permit_unverified")}}
        try ready(proposal,effects:effects,policy:last,native:native)
        // Readiness can invoke external code. Invalidation during that read is
        // still PRE-admission. No effect/readiness callback follows this check.
        let (admitted,admittedGrant,admittedBinding)=try authorized(proposal,caller:caller,epoch:epoch)
        guard admittedBinding.hash==binding.hash,
              (native ? admittedGrant.nativeReview:(delegated ? admittedGrant.delegatedTunnel:!admittedGrant.workflowIssuers.isEmpty)) else{throw ReviewFault("capability_not_granted")}
        if let (id,key)=issuer{guard admittedGrant.workflowIssuers.contains(id),admitted.issuerPublicKeys[id]==key else{throw ReviewFault("permit_unverified")}}
        guard !cancelled(),clock.nowMS()<expiry,clock.monotonic()<deadline else{throw ReviewFault("cancelled_or_expired_before_effect")}
        // This synchronous boundary is admission. The host serializes policy
        // handling/calls; external generation changes are observed above.
        // Cancellation AFTER admission cannot guarantee that save is stopped.
        // Save is synchronous/non-preemptible. No post-save cancellation relabel,
        // replay, compensating delete, invented cloud sync or permission request.
        let result=try effects.save(proposal,target:target)
        guard result=="saved_local" else{throw ReviewFault("outcome_unknown")}
        return ["schema_version":1,"operation_id":proposal.operationID,"request_sha256":proposal.rawHash,
                "target_binding_sha256":binding.hash,"persistence":"saved_local","cloud_sync":"not_checked"]
    }
}
