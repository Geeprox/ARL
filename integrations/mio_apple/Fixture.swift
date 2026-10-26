// Compiled ONLY into the test executable. No EventKit effects or tunnel network.
import Foundation
import Darwin
final class MioFixtureEffects:AppleEffects {
    var saves=0;var reads=0;var auths=0;var lock="unlocked";var outcome="saved_local";var resolveHook:()->Void={};var authorizationHook:()->Void={};var saveHook:()->Void={}
    func authorization(_ op:AppleOperation)->String{auths+=1;authorizationHook();return "write_only"}
    func lockState()->String{lock}
    func resolve(_ binding:TargetBinding)throws->ResolvedTarget{reads+=1;resolveHook();return ResolvedTarget(identifier:binding.identifier,name:"Synthetic calendar")}
    func save(_ proposal:AppleProposal,target:ResolvedTarget)throws->String{saves+=1;saveHook();return outcome}
}
func fixtureTunnel(home:String,host:Int32,mode:String)throws {
    let p=Process();p.executableURL=URL(fileURLWithPath:CommandLine.arguments[0]);p.arguments=[mode=="disconnect" ? "--disconnect-gateway":"--gateway",home,"--host-pid",String(host)]
    p.standardInput=FileHandle.standardInput;p.standardOutput=FileHandle.standardOutput;p.standardError=FileHandle.nullDevice
    try p.run();p.waitUntilExit();guard p.terminationStatus==0 else{throw ReviewFault("gateway_failed")}
}
func fixtureSession(home:String,mode:String,requests:[[String:Any]],tools:[[String:Any]])throws->[String:Any] {
    let listener=try socketAt(home+"/mio.sock",listen:true);defer{close(listener);unlink(home+"/mio.sock")}
    let pipe=Pipe();let out=Pipe();let p=Process();p.executableURL=URL(fileURLWithPath:CommandLine.arguments[0]);p.arguments=["--fixture-tunnel",home,String(getpid()),mode];p.standardInput=pipe;p.standardOutput=out;p.standardError=FileHandle.nullDevice
    try p.run();defer{if p.isRunning{p.terminate()}}
    var rogue:Process?=nil;var rogueInput:Pipe?=nil
    if mode=="rogue_parent" {
        // Controlled mock tunnel has not received startup input yet. Rogue
        // direct launch is the same signed binary but not its registered child.
        let r=Process();r.executableURL=p.executableURL;r.arguments=["--gateway",home,"--host-pid",String(getpid())];let ri=Pipe();rogueInput=ri;r.standardInput=ri;r.standardOutput=FileHandle.nullDevice;r.standardError=FileHandle.nullDevice;try r.run();rogue=r
    } else {try sendLine(jsonBytes(["start":true]),pipe.fileHandleForWriting.fileDescriptor)}
    defer{if let rogue,rogue.isRunning{rogue.terminate()};try? rogueInput?.fileHandleForWriting.close()}
    var wait=pollfd(fd:listener,events:Int16(POLLIN),revents:0);guard poll(&wait,1,3000)>0 else{throw ReviewFault("fixture_deadline")}
    let fd=accept(listener,nil,nil);guard fd>=0 else{throw ReviewFault("fixture_accept_failed")};defer{close(fd)}
    var active=true;var cancelled=false
    let effects=MioFixtureEffects()
    var binding=TargetBinding(alias:"approved_calendar",operation:.calendar,identifier:"synthetic-only")
    let qualified=mode=="locked_qualified"
    if mode.hasPrefix("locked"){effects.lock="locked"};if mode=="unknown_lock"{effects.lock="unknown"};if mode=="uncertain"{effects.outcome="outcome_unknown"}
    let budget=mode=="budget" ? 1:3
    let policy:()->ReviewPolicy?={
        guard active,mode != "disabled" else{return nil}
        return ReviewPolicy(epoch:1,callers:[mioSubject:CallerGrant(operations:[.calendar],targets:[binding.alias],nativeReview:false,workflowIssuers:[],maxEffects:budget,delegatedTunnel:mode != "ungranted")],targets:[binding.alias:binding],issuerPublicKeys:[:],lockedQualified:qualified ? [.calendar]:[])
    }
    let caller:AuthenticatedCaller
    do{caller=try registerControlledAdapter(fd,tunnelPID:p.processIdentifier,requirement:ownRequirement(),enabled:{active && p.isRunning})}
    catch let error as ReviewFault{return ["code":error.code,"saves":0,"reads":0,"auths":0]}
    if mode=="revoked"{effects.resolveHook={active=false}}
    if mode=="cancelled"{effects.resolveHook={cancelled=true}}
    if mode=="target_changed"{effects.resolveHook={binding=TargetBinding(alias:binding.alias,operation:.calendar,identifier:"changed")}}
    var now=Int64(Date().timeIntervalSince1970*1000);var mono=ProcessInfo.processInfo.systemUptime
    effects.authorizationHook={
        guard effects.auths==3 else{return}
        if mode=="final_ready_revoked"{active=false}
        if mode=="final_ready_cancelled"{cancelled=true}
        if mode=="final_ready_target"{binding=TargetBinding(alias:binding.alias,operation:.calendar,identifier:"changed-during-readiness")}
        if mode=="final_ready_expired"{let a=(requests.first?["params"] as? [String:Any])?["arguments"] as? [String:Any];now=integer(a?["expires_at_ms"]) ?? now+60000;mono+=60}
    }
    if mode=="post_admission_cancel"{effects.saveHook={cancelled=true;active=false}}
    let engine=AppleApprovalEngine(journal:try ConsumptionJournal(home:home),policy:policy,clock:ReviewClock(nowMS:{now},monotonic:{mono}))
    let consumer=MioCalendarConsumer(engine:engine,effects:effects,policy:policy)
    for request in requests{try sendLine(jsonBytes(request),pipe.fileHandleForWriting.fileDescriptor)}
    try pipe.fileHandleForWriting.close()
    var responses=[[String:Any]]()
    for _ in requests {
        guard let line=try boundedLine(fd,seconds:3),let request=try JSONSerialization.jsonObject(with:line) as? [String:Any] else{throw ReviewFault("fixture_request_invalid")}
        let response=try consumer.respond(request,caller:caller,legacy:{req in ["jsonrpc":"2.0","id":req["id"] ?? NSNull(),"result":["tools":tools]]},cancelled:{cancelled || disconnected(fd)})
        try sendLine(jsonBytes(response),fd)
        guard let returned=try boundedLine(out.fileHandleForReading.fileDescriptor,limit:1048576,seconds:3),let object=try JSONSerialization.jsonObject(with:returned) as? [String:Any] else{throw ReviewFault("fixture_response_invalid")};responses.append(object)
    }
    return ["responses":responses,"saves":effects.saves,"reads":effects.reads,"auths":effects.auths,"real_kernel_peer":true,"native_prompts":0]
}

func fixtureDisconnectGateway(home:String,host:Int32)throws {
 let fd=try socketAt(home+"/mio.sock",listen:false);defer{close(fd)}
 let caller=try AuthenticatedCaller.fromRegisteredSocket(fd,subject:"mio_controlled_host",expectedPID:host,requirement:ownRequirement(),registrationEpoch:1,currentRegistrationEpoch:{kill(host,0)==0 ? 1:nil})
 guard caller.isCurrent(),let line=try boundedLine(STDIN_FILENO,seconds:3) else{throw ReviewFault("fixture_failed")}
 try sendLine(line,fd);guard shutdown(fd,SHUT_WR)==0 else{throw ReviewFault("fixture_failed")}
 guard let reply=try boundedLine(fd,seconds:3) else{throw ReviewFault("fixture_failed")};try sendLine(reply,STDOUT_FILENO)
}

func transportFixture(_ mode:String)throws->[String:Any] {
 if mode=="real_eof" || mode=="real_absolute_deadline" {
  var pair:[Int32]=[-1,-1];guard pipe(&pair)==0 else{throw ReviewFault("fixture_failed")};defer{close(pair[0]);if pair[1]>=0{close(pair[1])}}
  if mode=="real_eof"{close(pair[1]);pair[1] = -1}
  let start=ProcessInfo.processInfo.systemUptime
  do{let result=try boundedLine(pair[0],seconds:0.03);return ["status":result==nil ? "eof":"ok","elapsed":ProcessInfo.processInfo.systemUptime-start]}
  catch let e as ReviewFault{return ["status":e.code,"elapsed":ProcessInfo.processInfo.systemUptime-start]}
 }
 var now:Double=0;var waits=0;var receives=0
 let io=LineIO(now:{now},wait:{_,ms in
  waits+=1
  if mode=="poll_eintr",waits==1{errno=EINTR;now+=0.1;return -1}
  if mode=="poll_error"{errno=EINVAL;return -1}
  if mode=="absolute_deadline" || (mode=="across_slices" && waits<=3){now+=Double(ms)/1000;return 0}
  return 1
 },receive:{_ in
  receives+=1
  if mode=="read_eintr",receives==1{errno=EINTR;return (-1,0)}
  if mode=="eof" || (mode=="truncated" && receives==2){return (0,0)}
  let index=mode=="read_eintr" ? receives-1:receives
  return (1,index==1 ? 88:10)
 })
 do {
  let data=try boundedLine(-1,seconds:600,io:io)
  return ["status":data==nil ? "eof":"ok","text":String(decoding:data ?? Data(),as:UTF8.self),"waits":waits,"elapsed":now]
 } catch let e as ReviewFault{return ["status":e.code,"waits":waits,"elapsed":now]}
}
