// Injected effects/ephemeral signing keys only; never part of the real library.
import Foundation
import CryptoKit
import Security
import Darwin

final class FixtureState {var now:Int64=1000;var mono:Double=0;var cancelled=false;var registered=true;var registrationEpoch:UInt64=1;var policy:ReviewPolicy?}
final class FixtureEffects:AppleEffects {
    var auth="full_access";var lock="unlocked";var authChecks=0;var resolutions=0;var saves=0
    var saveResult="saved_local";var onResolve:(()->Void)?;var onSave:(()->Void)?
    func authorization(_ operation:AppleOperation)->String{authChecks+=1;return auth}
    func lockState()->String{lock}
    func resolve(_ binding:TargetBinding)throws->ResolvedTarget{resolutions+=1;onResolve?();return ResolvedTarget(identifier:binding.identifier,name:"Synthetic \(binding.alias)")}
    func save(_ proposal:AppleProposal,target:ResolvedTarget)throws->String{saves+=1;onSave?();return saveResult}
}
@MainActor final class FixtureReviewer:NativeReviewer {
    var displays=[String]();var decision:(()->Bool)={true}
    func confirm(_ display:ReviewDisplay)->Bool{displays.append(display.text);return decision()}
}
func serialized(_ value:[String:Any])->Data{try! JSONSerialization.data(withJSONObject:value,options:[.sortedKeys,.withoutEscapingSlashes])}
func fixtureProposal(_ op:String="11111111-1111-4111-8111-111111111111",title:String="Synthetic event",reminder:Bool=false)->Data {
    var data:[String:Any]=["schema_version":1,"tool":reminder ? AppleOperation.reminder.rawValue:AppleOperation.calendar.rawValue,
        "operation_id":op,"caller_id":"mio_adapter","target_alias":reminder ? "default_reminders":"default_calendar","title":title,"time_zone":"Asia/Shanghai"]
    if reminder{data["due"]="2026-10-02T10:00:00+08:00"}
    else{data["start"]="2026-10-02T10:00:00+08:00";data["end"]="2026-10-02T10:05:00+08:00"}
    return serialized(data)
}
@MainActor func scenario(_ name:String,home:String)throws->[String:Any] {
    let state=FixtureState();let effects=FixtureEffects();let reviewer=FixtureReviewer()
    let key=Curve25519.Signing.PrivateKey() // Synthetic in-memory key; never saved/exported.
    let binding=TargetBinding(alias:"default_calendar",operation:.calendar,identifier:"synthetic-calendar")
    let reminder=TargetBinding(alias:"default_reminders",operation:.reminder,identifier:"synthetic-reminders")
    func policy(budget:Int=16,qualified:Bool=false,issuers:Set<String>=["fixture_workflow"])->ReviewPolicy {
        ReviewPolicy(epoch:1,callers:["mio_adapter":CallerGrant(operations:[.calendar,.reminder],targets:[binding.alias,reminder.alias],nativeReview:true,workflowIssuers:issuers,maxEffects:budget)],targets:[binding.alias:binding,reminder.alias:reminder],issuerPublicKeys:["fixture_workflow":key.publicKey.rawRepresentation],lockedQualified:qualified ? [.calendar,.reminder]:[])
    }
    state.policy=policy()
    let journal=try ConsumptionJournal(home:home)
    let engine=AppleApprovalEngine(journal:journal,policy:{state.policy},clock:ReviewClock(nowMS:{state.now},monotonic:{state.mono}))
    let caller=AuthenticatedCaller.fixture("mio_adapter",check:{state.registered})
    func permit(_ raw:Data,id:String=UUID().uuidString.lowercased(),patch:[String:Any]=[:],wrongKey:Bool=false)throws->SignedWorkflowPermit {
        let proposal=try AppleProposal(raw);let target=proposal.operation == .calendar ? binding:reminder
        var body:[String:Any]=["schema_version":1,"issuer_id":"fixture_workflow","permit_id":id,"workflow_id":"22222222-2222-4222-8222-222222222222",
            "caller_id":proposal.callerID,"operation_id":proposal.operationID,"tool":proposal.operation.rawValue,"request_sha256":proposal.rawHash,
            "target_alias":target.alias,"target_binding_sha256":target.hash,"issued_at_ms":1000,"expires_at_ms":61000,"max_effects":1,"policy_epoch":1]
        for (k,v) in patch{body[k]=v};let bytes=serialized(body)
        return SignedWorkflowPermit(issuer:"fixture_workflow",payload:bytes,signature:try (wrongKey ? Curve25519.Signing.PrivateKey():key).signature(for:bytes))
    }
    func execute(_ raw:Data,_ signed:SignedWorkflowPermit)throws->[String:Any]{try engine.performWorkflow(raw,permit:signed,caller:caller,effects:effects,cancelled:{state.cancelled})}
    var raw=fixtureProposal();var result:[String:Any]=[:]
    do {
        switch name {
        case "disabled":state.policy=nil;result=try execute(raw,permit(raw))
        case "forged_caller":var p=try flatObject(raw);p["caller_id"]="settings";raw=serialized(p);result=try execute(raw,permit(raw))
        case "approved_flag":var p=try flatObject(raw);p["approved"]=1;raw=serialized(p);result=try execute(raw,permit(raw))
        case "duplicate_key":let p=String(decoding:raw,as:UTF8.self).dropLast()+",\"title\":\"changed\"}";raw=Data(p.utf8);_=try AppleProposal(raw)
        case "bad_signature":result=try execute(raw,permit(raw,wrongKey:true))
        case "tamper":let signed=try permit(raw);result=try execute(fixtureProposal(title:"Changed"),signed)
        case "target_mismatch":result=try execute(raw,permit(raw,patch:["target_binding_sha256":String(repeating:"a",count:64)]))
        case "expired":result=try execute(raw,permit(raw,patch:["issued_at_ms":0,"expires_at_ms":999]))
        case "cancel_before":state.cancelled=true;result=try execute(raw,permit(raw))
        case "cancel_after_review":reviewer.decision={state.cancelled=true;return true};result=try engine.performNative(raw,caller:caller,reviewer:reviewer,effects:effects,cancelled:{state.cancelled})
        case "native_cancel":reviewer.decision={false};result=try engine.performNative(raw,caller:caller,reviewer:reviewer,effects:effects)
        case "late_native":reviewer.decision={state.mono=20;return true};result=try engine.performNative(raw,caller:caller,reviewer:reviewer,effects:effects)
        case "dynamic_native":
            result=try engine.performNative(raw,caller:caller,reviewer:reviewer,effects:effects)
            result=try engine.performNative(fixtureProposal("33333333-3333-4333-8333-333333333333",title:"Another request",reminder:true),caller:caller,reviewer:reviewer,effects:effects)
        case "locked_workflow":state.policy=policy(qualified:true);effects.lock="locked";result=try execute(raw,permit(raw))
        case "locked_unqualified":effects.lock="locked";result=try execute(raw,permit(raw))
        case "unknown_lock":state.policy=policy(qualified:true);effects.lock="unknown";result=try execute(raw,permit(raw))
        case "revoked":effects.onResolve={state.registered=false};result=try execute(raw,permit(raw))
        case "issuer_revoked":effects.onResolve={state.policy=policy(issuers:[])};result=try execute(raw,permit(raw))
        case "budget":state.policy=policy(budget:1);_=try execute(raw,permit(raw));let next=fixtureProposal("33333333-3333-4333-8333-333333333333");result=try execute(next,permit(next))
        case "replay":let signed=try permit(raw);_=try execute(raw,signed);result=try execute(raw,signed)
        case "uncertain":effects.saveResult="outcome_unknown";result=try execute(raw,permit(raw))
        case "late_cancel":effects.onSave={state.cancelled=true};result=try execute(raw,permit(raw))
        case "success":result=try execute(raw,permit(raw))
        case "kernel_peer":
            var pair:[Int32]=[-1,-1];guard socketpair(AF_UNIX,SOCK_STREAM,0,&pair)==0 else{throw ReviewFault("socketpair_unavailable")};defer{close(pair[0]);close(pair[1])}
            var selfCode:SecCode?;var staticCode:SecStaticCode?;var info:CFDictionary?
            guard SecCodeCopySelf([], &selfCode)==errSecSuccess,let selfCode,SecCodeCopyStaticCode(selfCode,[],&staticCode)==errSecSuccess,let staticCode,SecCodeCopySigningInformation(staticCode,[],&info)==errSecSuccess,
                  let record=info as? [String:Any],let bytes=record[kSecCodeInfoUnique as String] as? Data else{throw ReviewFault("fixture_signature_unavailable")}
            let hash=bytes.map{String(format:"%02x",$0)}.joined()
            let verified=try AuthenticatedCaller.fromRegisteredSocket(pair[0],subject:"mio_adapter",expectedPID:getpid(),requirement:"cdhash H\""+hash+"\"",registrationEpoch:1,currentRegistrationEpoch:{state.registered ? state.registrationEpoch:nil})
            guard verified.isCurrent() else{throw ReviewFault("caller_unverified")};state.registered=false
            guard !verified.isCurrent() else{throw ReviewFault("revocation_failed")};state.registered=true;state.registrationEpoch=2
            guard !verified.isCurrent() else{throw ReviewFault("revocation_failed")};result=["verified":true,"revoked":true,"old_generation_rejected":true]
        case "invalid_date":var body=try flatObject(raw);body["start"]="2026-02-30T10:00:00+08:00";raw=serialized(body);_=try AppleProposal(raw)
        case "wrong_offset":var body=try flatObject(raw);body["start"]="2026-10-02T10:00:00+09:00";raw=serialized(body);_=try AppleProposal(raw)
        default:throw ReviewFault("unknown_fixture")
        }
        result["status"]="ok"
    } catch let error as ReviewFault{result=["status":error.code]}
    result["save_calls"]=effects.saves;result["authorization_checks"]=effects.authChecks;result["metadata_reads"]=effects.resolutions
    result["native_prompts"]=reviewer.displays.count;result["displays"]=reviewer.displays
    return result
}
