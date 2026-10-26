import Foundation
import AppKit
struct ReviewFault:Error {let code:String;init(_ code:String){self.code=code}}
@MainActor final class Fixture {
 var now=100.0;var observed=MioSetupObservation.unknown;var valid=true;var consumed=false
 var permission="not_determined";var permissionChecks=0;var reviewCount=0;var TCC=0;var targets=0;var phases:[String]=[]
 let scenario:String
 init(_ s:String){scenario=s;if s=="locked"{observed = .locked};if s=="preauthorized"{permission="write_only"};if s=="consumed"{consumed=true}}
 var services:MioSetupServices {
  MioSetupServices(observation:{self.observed},validate:{guard self.valid else{throw ReviewFault("caller_unverified")}},consumed:{self.consumed},phase:{self.phases.append($0)},review:{_,_,_ in
   self.reviewCount+=1
   if self.scenario=="cancel_disclosure" || (self.scenario=="cancel_target" && self.reviewCount==2){return .cancelled}
   if self.scenario=="expire_review"{return .expired}
   if self.scenario=="stale_review"{return .confirmed(self.now-21)}
   if self.scenario=="lock_after_disclosure"{self.observed = .locked}
   if self.scenario=="revoked_after_confirmation" && self.reviewCount==2{self.valid=false}
   return .confirmed(self.now)
  },permission:{
   self.permissionChecks+=1
   if self.scenario=="revoke_during_status" && self.permissionChecks==1{self.valid=false}
   if self.scenario=="revoke_during_final_status" && self.permissionChecks==3{self.valid=false}
   return self.permission
  },requestWriteOnly:{
   self.TCC+=1
   if self.scenario=="deny_permission"{self.permission="denied";return false}
   self.permission="write_only"
   if self.scenario=="revoke_during_permission"{self.valid=false}
   if self.scenario=="cancel_during_permission"{withUnsafeCurrentTask{$0?.cancel()}}
   if self.scenario=="deadline_during_permission"{self.now+=166}
   return true
  },target:{
   self.targets+=1
   if self.scenario=="changed_target" && self.targets==2{return MioSetupTarget(identifier:"changed",name:"test-only changed")}
   if self.scenario=="revoke_during_final_target" && self.targets==2{self.valid=false}
   if self.scenario=="expire_during_final_target" && self.targets==2{self.now+=21}
   return MioSetupTarget(identifier:"synthetic default",name:"test-only default")
  },monotonic:{self.now},wallMs:{1000000})
 }
}
@main struct Run {
 @MainActor static func main()async throws {
  let scenario=CommandLine.arguments[1]
  if scenario=="event_guard" {
   func accepts(_ offset:Double=0,_ same:Bool=true,_ key:Bool=true,_ visible:Bool=true,_ active:Bool=true,_ allowed:Bool=true)->Bool{
    MioNativeInteraction.accepts(eventTime:100+offset,now:100.1,began:99,end:119,eventMatchesWindow:same,windowKey:key,windowVisible:visible,appActive:active,eventType:allowed ? .keyDown:.mouseMoved,isRepeat:false)
   }
   let v=["fresh":accepts(),"stale":accepts(-5),"foreign":accepts(0,false),"not_key":accepts(0,true,false),"not_visible":accepts(0,true,true,false),"inactive":accepts(0,true,true,true,false),"unsupported":accepts(0,true,true,true,true,false),"future":accepts(1)]
   try FileHandle.standardOutput.write(contentsOf:JSONSerialization.data(withJSONObject:v));return
  }
  if scenario=="held_return" {
   func admitted(time:Double,began:Double,type:NSEvent.EventType,repeated:Bool)->Bool {
    MioNativeInteraction.accepts(eventTime:time,now:100.6,began:began,end:120,eventMatchesWindow:true,windowKey:true,windowVisible:true,appActive:true,eventType:type,isRepeat:repeated)
   }
   let v=["first_fresh_press":admitted(time:100.5,began:100,type:.keyDown,repeated:false),"repeat_in_next_dialog":admitted(time:100.5,began:100.2,type:.keyDown,repeated:true),"unpaired_key_up":admitted(time:100.5,began:100.2,type:.keyUp,repeated:false),"old_press_carried":admitted(time:100.1,began:100.2,type:.keyDown,repeated:false),"mouse_confirmation":admitted(time:100.5,began:100.2,type:.leftMouseUp,repeated:false)]
   try FileHandle.standardOutput.write(contentsOf:JSONSerialization.data(withJSONObject:v));return
  }
  let f=Fixture(scenario);var code="granted";var grant=0;var expiry:Int64=0
  do{let result=try await MioCalendarSetupFlow.prepare(f.services);grant=1;expiry=result.expiresAtMs}catch let e as ReviewFault{code=e.code}
  let out:[String:Any]=["code":code,"grants":grant,"reviews":f.reviewCount,"TCC_requests":f.TCC,"target_reads":f.targets,"expires_at_ms":expiry,"observation":f.observed.rawValue,"phases":f.phases,"native_UI_TCC_writes":false]
  try FileHandle.standardOutput.write(contentsOf:JSONSerialization.data(withJSONObject:out))
 }
}
