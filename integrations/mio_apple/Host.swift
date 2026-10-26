import Foundation
import Darwin
import Security
import EventKit

// These exact official bytes are carried inside the new signed bundle.
// The outer signature seals Info.plist; the Info seal and per-file pins bind this finite resource tree.
struct MioBundledRuntime {
    let tunnelClient: String
    let cloudflared: String
    static let manifestSHA = "74ab77c977187fd42e2fe30c83ed2407a31d60ea86405a98d8317d8e9475a2db"
    static let pins: [String: (sha: String, bytes: Int, mode: mode_t)] = [
        "tunnel-client": ("309fd85da5a8c2ca8dae920deea8ac10a4d7934ed18ac46e7df0c200139cc9c5", 20405442, 0o755),
        "cloudflared": ("4cf6ca3f4dde4266cd5a61c55f3fe4d8e752914e9d6187a10bd0daf80d0440a1", 38715842, 0o755),
        "cloudflared-manifest.json": ("80003d8a8f38d6a0bd74aabc096e9f99a6e8fad8ed4da699e26a8231fa453aa1", 1038, 0o644),
        "LICENSE": ("f4c1d7ba32ef5bcf5cf03e2eefec5825ebafedf50fa330a36700a49c605c1ef4", 10758, 0o644),
        "NOTICE": ("1364c020d86ecf948b78b7c655175032068203d13aece70fb0bfe112d7802dc2", 551, 0o644),
        "sbom.spdx.json": ("a2c58ed88a09e84ede13772dbbe0c5dd2ad02c507c94b3b068d803a4d93e30be", 2306, 0o644),
    ]
    static func load() throws -> MioBundledRuntime {
        guard let resources = Bundle.main.resourceURL,
              resources.standardizedFileURL.path == Bundle.main.bundleURL.appendingPathComponent("Contents/Resources", isDirectory: true).standardizedFileURL.path,
              let seal = Bundle.main.object(forInfoDictionaryKey: "ARLMioRuntimeManifestSHA256") as? String,
              seal == manifestSHA else { throw ReviewFault("mio_runtime_not_sealed") }
        let root = resources.appendingPathComponent("MioRuntime", isDirectory: true).path
        let raw = try privateFile(root + "/manifest.json", limit: 16384)
        guard digest(raw) == seal,
              let manifest = try JSONSerialization.jsonObject(with: raw) as? [String: Any],
              Set(manifest.keys) == ["schema_version", "tunnel_client_version", "cloudflared_version", "layout", "files"],
              integer(manifest["schema_version"]) == 1,
              manifest["tunnel_client_version"] as? String == "0.0.14",
              manifest["cloudflared_version"] as? String == "2026.8.2",
              manifest["layout"] as? String == "adjacent_executables",
              let files = manifest["files"] as? [String: [String: Any]], Set(files.keys) == Set(pins.keys),
              Set(try FileManager.default.contentsOfDirectory(atPath: root)) == Set(pins.keys).union(["manifest.json"])
        else { throw ReviewFault("mio_runtime_manifest_changed") }
        for (name, pin) in pins {
            guard let record = files[name], Set(record.keys) == ["sha256", "bytes", "mode"],
                  record["sha256"] as? String == pin.sha, integer(record["bytes"]) == Int64(pin.bytes),
                  integer(record["mode"]) == Int64(pin.mode),
                  digest(try privateFile(root + "/" + name, limit: pin.bytes)) == pin.sha
            else { throw ReviewFault("mio_runtime_resource_changed") }
            var metadata = stat()
            guard lstat(root + "/" + name, &metadata) == 0,
                  metadata.st_mode & S_IFMT == S_IFREG, metadata.st_size == Int64(pin.bytes),
                  metadata.st_mode & 0o777 == pin.mode else { throw ReviewFault("mio_runtime_resource_changed") }
        }
        return MioBundledRuntime(tunnelClient: root + "/tunnel-client", cloudflared: root + "/cloudflared")
    }
}
@discardableResult func validateProductionSources() throws -> MioBundledRuntime {
    let runtime = try MioBundledRuntime.load()
    // Only a newly sealed, formally reviewed pair may enable this read route.
    _ = try OwnerReadAuthority.load(role: .mio)
    _ = try MioReadCatalog.descriptors()
    return runtime
}
// Immutable deployment ceiling, sealed BEFORE TCC. No target/expiry is sealed
// afterwards; those are returned only by our controlled native setup child.
struct MioActivation {
    let home:String;let profile:String;let profileSHA:String;let clientHome:String;let healthURLFile:String
    let calendarOSTCCOnly:Bool
    let audienceOrg:String;let tunnelID:String
    let epoch:Int64=1;let budget:Int=3
    init(_ data:Data)throws {
        let p=try flatObject(data)
        let base:Set<String>=["schema_version","enabled","home","profile","profile_sha256","client_home","health_url_file","audience_org","tunnel_id","target_rule","max_effects","session_seconds","locked_qualified"]
        let background=integer(p["schema_version"])==3
        guard (background ? Set(p.keys)==base.union(["calendar_execution_policy"]) && p["calendar_execution_policy"] as? String=="os_tcc_only" : integer(p["schema_version"])==2 && Set(p.keys)==base),integer(p["enabled"])==1,
              let home=p["home"] as? String,home.hasPrefix("/"),let profile=p["profile"] as? String,profile.hasPrefix("/"),let sha=p["profile_sha256"] as? String,sha.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil,
              let client=p["client_home"] as? String,client.hasPrefix("/"),let health=p["health_url_file"] as? String,health.hasPrefix("/"),
              let org=p["audience_org"] as? String,org.range(of:"^org-[A-Za-z0-9]{1,80}$",options:.regularExpression) != nil,
              let tunnel=p["tunnel_id"] as? String,tunnel.range(of:"^tunnel_[a-f0-9]{32}$",options:.regularExpression) != nil,
              p["target_rule"] as? String=="defaultCalendarForNewEvents",integer(p["max_effects"])==3,integer(p["session_seconds"])==3600,integer(p["locked_qualified"])==0 else{throw ReviewFault("activation_disabled_or_invalid")}
        audienceOrg=org;tunnelID=tunnel;self.home=home;self.profile=profile;profileSHA=sha;calendarOSTCCOnly=background;clientHome=client;healthURLFile=health
    }
}
struct NativeSession {
    let target:TargetBinding;let expiry:Int64
    init(_ data:Data)throws {
        let p=try flatObject(data);let now=Int64(Date().timeIntervalSince1970*1000)
        guard Set(p.keys)==Set(["schema_version","target_alias","calendar_identifier","expires_at_ms"]),integer(p["schema_version"])==1,p["target_alias"] as? String=="approved_calendar",
              let id=p["calendar_identifier"] as? String,!id.isEmpty,id.utf8.count<=1024,let expiry=integer(p["expires_at_ms"]),expiry>now,expiry<=now+3600000 else{throw ReviewFault("native_session_invalid")}
        target=TargetBinding(alias:"approved_calendar",operation:.calendar,identifier:id);self.expiry=expiry
    }
    var policy:ReviewPolicy{policy(calendarOSTCCOnly:false)}
    func policy(calendarOSTCCOnly:Bool)->ReviewPolicy{ReviewPolicy(epoch:1,callers:[mioSubject:CallerGrant(operations:[.calendar],targets:[target.alias],nativeReview:false,workflowIssuers:[],maxEffects:3,delegatedTunnel:true,calendarOSTCCOnly:calendarOSTCCOnly)],targets:[target.alias:target],issuerPublicKeys:[:],lockedQualified:[])}
}
func sealedActivation(_ policyPath:String,_ approvedSHA:String)throws->MioActivation {
    var own:SecCode?
    guard SecCodeCopySelf([], &own)==errSecSuccess,let own,SecCodeCheckValidity(own,SecCSFlags(rawValue:kSecCSStrictValidate),nil)==errSecSuccess,
          Bundle.main.bundleIdentifier==mioBundleIdentifier,let sealed=Bundle.main.object(forInfoDictionaryKey:"ARLApprovedPolicySHA256") as? String,
          sealed.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil,sealed==approvedSHA else{throw ReviewFault("activation_not_sealed")}
    let raw=try privateFile(policyPath);guard digest(raw)==approvedSHA else{throw ReviewFault("activation_hash_changed")};return try MioActivation(raw)
}
// Kept as the test injection spelling; production now consumes native owner reads.
func legacy(_ request:[String:Any])throws->[String:Any] {
    try MioReadOwnerAdapter.respond(request)
}
struct HostDependencies {
    let launch:(MioActivation,String,String)throws->Process
    let legacyCall:([String:Any])throws->[String:Any]
    let effects:()->AppleEffects
    let session:(MioActivation,String,String,HostStop)throws->NativeSession
    var readCall: (([String:Any], () -> Bool) throws -> [String:Any])? = nil
    static var production:HostDependencies{HostDependencies(launch:{a,path,sha in
        try validateProductionSources()
        let p=Process();p.executableURL=Bundle.main.executableURL;p.arguments=["--launch-client",path,"--approved-policy-sha256",sha]
        p.environment=["PATH":"","HOME":a.clientHome,"LANG":"en_US.UTF-8"]
        let errors=Pipe(),output=Pipe();MioStartupDiagnostics.capture(errors,role:"client");MioStartupDiagnostics.capture(output,role:"client",stream:"stdout")
        p.standardInput=FileHandle.nullDevice;p.standardOutput=output;p.standardError=errors;try p.run();try errors.fileHandleForWriting.close();try output.fileHandleForWriting.close();return p
    },legacyCall:legacy,effects:{EventKitEffects()},session:controlledSetup,readCall:{request,cancelled in
        try MioReadOwnerAdapter.respond(request,cancelled:cancelled,
            attachmentCall:{ bytes in try MioAttachmentInspection.call(bytes,cancelled:cancelled) })
    })}
}
func controlledSetup(_ a:MioActivation,_ policyPath:String,_ sha:String,_ stop:HostStop)throws->NativeSession {
    guard access(a.home+"/session_consumed",F_OK) != 0 else{throw ReviewFault("session_already_consumed")}
    let p=Process();p.executableURL=Bundle.main.executableURL;p.arguments=["--prepare-session",policyPath,"--approved-policy-sha256",sha]
    p.environment=["PATH":"/usr/bin:/bin","HOME":NSHomeDirectory(),"LANG":"en_US.UTF-8"]
    let out=Pipe(),errors=Pipe();MioStartupDiagnostics.capture(errors,role:"setup")
    p.standardOutput=out;p.standardInput=FileHandle.nullDevice;p.standardError=errors;try p.run();try errors.fileHandleForWriting.close();let owned=try OwnedPID(p.processIdentifier)
    defer{owned.signal(SIGTERM);if !owned.stopped(by:ProcessInfo.processInfo.systemUptime+1){owned.signal(SIGKILL)};if owned.stopped(by:ProcessInfo.processInfo.systemUptime+1){p.waitUntilExit()}}
    try verifyOwnedSignature(p.processIdentifier,requirement:ownRequirement())
    let deadline=ProcessInfo.processInfo.systemUptime+180
    while !stop.requested && ProcessInfo.processInfo.systemUptime<deadline {
        var poller=pollfd(fd:out.fileHandleForReading.fileDescriptor,events:Int16(POLLIN),revents:0)
        if poll(&poller,1,250)==0{continue}
        do{guard let bytes=try boundedLine(out.fileHandleForReading.fileDescriptor,limit:4096,seconds:2) else{throw ReviewFault("native_setup_cancelled")};let session=try NativeSession(bytes)
            guard !stop.requested else{throw ReviewFault("cancelled_before_effect")}
            try writePrivateNew(a.home+"/session_consumed",Data("consumed_no_automatic_renewal\n".utf8));return session
        }
    }
    throw ReviewFault("native_setup_deadline")
}
// Same signed app may request ONE native setup dialog. It cannot send a target,
// approved=true, permit or grant. No tunnel request enters this control socket.
func requestSession(home:String)throws->[String:Any] {
    let fd=try socketAt(home+"/control.sock",listen:false);defer{close(fd)}
    let pid=try peerPID(fd);try verifyOwnedSignature(pid,requirement:ownRequirement())
    try sendLine(jsonBytes(["method":"authorize_session"]),fd)
    guard let data=try boundedLine(fd,limit:4096,seconds:185),let result=try JSONSerialization.jsonObject(with:data) as? [String:Any] else{throw ReviewFault("native_setup_deadline")};return result
}
// Query the signed running effect host. This path never starts EventKit setup.
func calendarAuthorizationStatus(home:String)throws->[String:Any] {
    let fd=try socketAt(home+"/control.sock",listen:false);defer{close(fd)}
    let pid=try peerPID(fd);try verifyOwnedSignature(pid,requirement:ownRequirement())
    try sendLine(jsonBytes(["method":"authorization_status"]),fd)
    guard let data=try boundedLine(fd,limit:1024,seconds:5),
          let result=try JSONSerialization.jsonObject(with:data) as? [String:Any],
          Set(result.keys)==["status","authorization","prompts_requested","data_read"],
          result["status"] as? String=="ok",result["prompts_requested"] as? Bool==false,
          result["data_read"] as? Bool==false,
          let state=result["authorization"] as? String,
          ["not_determined","write_only","full_access","denied","restricted","unknown"].contains(state)
    else{throw ReviewFault("authorization_status_invalid")}
    return result
}
func nativeCalendarAuthorization() -> String {
    switch EKEventStore.authorizationStatus(for:.event) {
    case .notDetermined:return "not_determined"
    case .writeOnly:return "write_only"
    case .fullAccess:return "full_access"
    case .denied:return "denied"
    case .restricted:return "restricted"
    @unknown default:return "unknown"
    }
}
func launchClient(policyPath:String,approvedSHA:String)throws->Never {
    let a=try sealedActivation(policyPath,approvedSHA)
    MioStartupDiagnostics.phase("client_parent")
    let parent=getppid();try verifyOwnedSignature(parent,requirement:ownRequirement())
    MioStartupDiagnostics.phase("client_group")
    try establishControlledClientGroup()
    MioStartupDiagnostics.phase("client_sources")
    let runtime = try validateProductionSources()
    let args=[runtime.tunnelClient,"run","--profile-file",a.home+"/active-profile.yaml","--cloudflared.path",runtime.cloudflared,"--mcp.max-concurrent-requests","1","--control-plane.max-inflight","1","--health.listen-addr","127.0.0.1:0","--health.url-file",a.healthURLFile,"--log.format","json","--log.level","debug","--log.file","","--log.http-raw-unsafe=false"]
    let pointers=args.map{strdup($0)};defer{pointers.forEach{free($0)}}
    MioStartupDiagnostics.phase("client_exec");MioStartupDiagnostics.record("starting")
    // This child does not inherit a caller PATH, proxy, cloudflared override, loader variable or account secret.
    let environment=["PATH=","HOME="+a.clientHome,"LANG=en_US.UTF-8"].map{strdup($0)}
    defer{environment.forEach{free($0)}}
    var argv=pointers+[nil],envp=environment+[nil]
    execve(runtime.tunnelClient,&argv,&envp);throw ReviewFault("client_launch_rejected")
}
// Unified app startup supplies the exact signed current policy seal. Historical
// predecessor launch arguments are retired; the external installed host is unchanged.
func hostPolicySHA(policyPath:String,launchSHA:String,sealedSHA:String?)throws->String {
    guard let sealedSHA,sealedSHA.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil,
          launchSHA == sealedSHA else { throw ReviewFault("activation_not_sealed") }
    return sealedSHA
}
func runHost(policyPath:String,approvedSHA launchSHA:String,dependencies:HostDependencies = .production)throws {
    let approvedSHA=try hostPolicySHA(policyPath:policyPath,launchSHA:launchSHA,sealedSHA:Bundle.main.object(forInfoDictionaryKey:"ARLApprovedPolicySHA256") as? String)
    let a=try sealedActivation(policyPath,approvedSHA)
    MioStartupDiagnostics.phase("host_profile")
    guard digest(try privateFile(a.profile))==a.profileSHA else{throw ReviewFault("source_or_profile_changed")}
    MioStartupDiagnostics.phase("host_state")
    let journal=try ConsumptionJournal(home:a.home)
    let lock=try lockHostHome(a.home);defer{close(lock)}
    try recoverStoppedHost(a.home)
    guard let template=String(data:try privateFile(a.profile),encoding:.utf8),template.components(separatedBy:"{{ARL_MIO_HOST_PID}}").count==2 else{throw ReviewFault("profile_host_binding_missing")}
    let runtime=a.home+"/active-profile.yaml";try writePrivateNew(runtime,Data(template.replacingOccurrences(of:"{{ARL_MIO_HOST_PID}}",with:String(getpid())).utf8));defer{unlink(runtime)}
    let path=a.home+"/mio.sock",control=a.home+"/control.sock"
    guard access(path,F_OK) != 0,access(control,F_OK) != 0 else{throw ReviewFault("existing_socket")}
    MioStartupDiagnostics.phase("host_sockets")
    let listener=try socketAt(path,listen:true);defer{close(listener);unlink(path)}
    let command=try socketAt(control,listen:true);defer{close(command);unlink(control)}
    guard fcntl(listener,F_SETFD,FD_CLOEXEC)==0,fcntl(command,F_SETFD,FD_CLOEXEC)==0 else{throw ReviewFault("transport_unavailable")}
    let stop=HostStop();signal(SIGTERM,SIG_IGN);signal(SIGINT,SIG_IGN)
    let signals=[SIGTERM,SIGINT].map{number -> DispatchSourceSignal in
        let source=DispatchSource.makeSignalSource(signal:number,queue:.global());source.setEventHandler{stop.request()};source.resume();return source
    };defer{signals.forEach{$0.cancel()}}
    MioStartupDiagnostics.phase("host_spawn")
    let child=try dependencies.launch(a,policyPath,approvedSHA);let owned=try OwnedPID(child.processIdentifier)
    var gateway:OwnedPID?=nil;var clean=false
    defer{
        if !clean{do{try stopOwned(child,tunnel:owned,gateway:gateway);clean=true}catch{}}
        if clean{unlink(a.home+"/owned-child.json")}
    }
    try writePrivateNew(a.home+"/owned-child.json",try jsonBytes(["pid":owned.pid,"birth_seconds":owned.seconds,"birth_micros":owned.micros]))
    let rule=try ownRequirement()
    let parentOwner = getppid()
    func transportLive()->Bool{owned.current && !stop.requested && getppid() == parentOwner}
    var fd:Int32 = -1;var caller:AuthenticatedCaller?=nil
    defer{if fd>=0{ARLConnectionLog.production.record("mio","disconnected");close(fd)}}
    var session:NativeSession?=nil
    func current()->ReviewPolicy? {
        guard transportLive(),let session,Int64(Date().timeIntervalSince1970*1000)<session.expiry,
              let bytes=try? privateFile(policyPath),digest(bytes)==approvedSHA,
              let profile=try? privateFile(a.profile),digest(profile)==a.profileSHA else{return nil}
        return session.policy(calendarOSTCCOnly:a.calendarOSTCCOnly)
    }
    let engine=AppleApprovalEngine(journal:journal,policy:current)
    let publication = MioCatalogPublicationEvidence()
    // EventKit creation is lazy: readonly host never initializes its store.
    var consumer:MioCalendarConsumer?=nil
    func readOnlyResponse(_ request:[String:Any])throws->[String:Any] {
        if let readCall=dependencies.readCall {
            return try readCall(request,{disconnected(fd) || stop.requested || !transportLive() || caller?.isCurrent() != true})
        }
        return try dependencies.legacyCall(request) // deterministic fixture injection only
    }
    MioStartupDiagnostics.phase("host_loop");MioStartupDiagnostics.record("running")
    while transportLive() {
        var polled=[pollfd(fd:fd,events:Int16(POLLIN),revents:0),pollfd(fd:command,events:Int16(POLLIN),revents:0),pollfd(fd:listener,events:Int16(POLLIN),revents:0)]
        let count=poll(&polled,3,250);if count<0{if errno==EINTR{continue};throw ReviewFault("transport_unavailable")}
        if polled[2].revents&Int16(POLLIN) != 0 {
            let incoming=accept(listener,nil,nil)
            if incoming>=0 {
                if fd>=0{close(incoming)}
                else{
                    do{
                        caller=try registerControlledAdapter(incoming,tunnelPID:owned.pid,requirement:rule,enabled:transportLive)
                        gateway=try OwnedPID(try peerPID(incoming));fd=incoming
                        ARLConnectionLog.production.record("mio","connected",["peer_pid":gateway!.pid])
                    }catch{close(incoming);throw error}
                }
            }
        }
        if polled[1].revents&Int16(POLLIN) != 0 {
            let c=accept(command,nil,nil)
            if c>=0 {
                defer{close(c)}
                do{
                    let pid=try peerPID(c);try verifyOwnedSignature(pid,requirement:rule)
                    guard let line=try boundedLine(c,limit:1024,seconds:2),let obj=try JSONSerialization.jsonObject(with:line) as? [String:Any],Set(obj.keys)==["method"],let method=obj["method"] as? String else{throw ReviewFault("native_setup_rejected")}
                    if method=="authorization_status" {
                        try sendLine(jsonBytes(["status":"ok","authorization":nativeCalendarAuthorization(),"prompts_requested":false,"data_read":false]),c)
                    } else {
                        guard method=="authorize_session",current()==nil,session==nil else{throw ReviewFault("native_setup_rejected")}
                        session=try dependencies.session(a,policyPath,approvedSHA,stop)
                        consumer=MioCalendarConsumer(engine:engine,effects:dependencies.effects(),policy:current)
                        try sendLine(jsonBytes(["status":"session_active","max_attempts":3,"expires_at_ms":session!.expiry]),c)
                    }
                }catch{try? sendLine(jsonBytes(["status":"inactive","code":"native_setup_rejected"]),c)}
            }
        }
        guard !stop.requested else{break}
        if polled[0].revents != 0 {
            do{
                guard let bytes=try boundedLine(fd,seconds:2) else{ARLConnectionLog.production.record("mio","disconnected");close(fd);fd = -1;caller=nil;continue}
                let request=try OwnerReadJSON.object(bytes,limit:OwnerReadWire.requestLimit)
                guard let caller,caller.isCurrent() else{throw ReviewFault("caller_unverified")}
                if request["id"]==nil{continue}
                let logStarted=ProcessInfo.processInfo.systemUptime
                var logFields=ARLConnectionLog.requestFields(request),logFailed=true
                ARLConnectionLog.production.record("mio","request_received",logFields)
                defer {
                    logFields["elapsed_ms"]=max(0,Int((ProcessInfo.processInfo.systemUptime-logStarted)*1000));logFields["failed"]=logFailed
                    ARLConnectionLog.production.record("mio","request_finished",logFields)
                }
                let response:[String:Any]
                if let consumer {response=try consumer.respond(request,caller:caller,legacy:readOnlyResponse,cancelled:{disconnected(fd) || current()==nil || stop.requested})}
                else if request["method"] as? String=="tools/call",(request["params"] as? [String:Any])?["name"] as? String==mioCalendarName{response=["jsonrpc":"2.0","id":request["id"] ?? NSNull(),"result":["isError":true,"content":[["type":"text","text":"{\"code\":\"calendar_v1_retired\"}"]]]]}
                else{response=try readOnlyResponse(request)}
                if let notification=publication.pendingListChanged(request:request) {
                    // One standard catalog notice on the existing authenticated
                    // request stream. No business handler or credential access.
                    try sendLine(jsonBytes(notification),fd)
                    publication.recordListChangedSent()
                }
                let outgoing = publication.decoratePing(response, request: request)
                try sendLine(jsonBytes(outgoing),fd)
                // Record only after the existing signed gateway socket accepted the reply.
                publication.recordSent(request: request, response: outgoing)
                logFailed=outgoing["error"] != nil || ((outgoing["result"] as? [String:Any])?["isError"] as? Bool == true)
            }
        }
    }
    let unexpected = !stop.requested
    try stopOwned(child,tunnel:owned,gateway:gateway);clean=true
    if unexpected{throw ReviewFault("controlled_client_exited")}
}
func runGateway(home:String,expectedHostPID:Int32)throws {
    let fd=try socketAt(home+"/mio.sock",listen:false);defer{close(fd)}
    let caller=try AuthenticatedCaller.fromRegisteredSocket(fd,subject:"mio_controlled_host",expectedPID:expectedHostPID,requirement:ownRequirement(),registrationEpoch:1,currentRegistrationEpoch:{kill(expectedHostPID,0)==0 ? 1:nil})
    while caller.isCurrent() {
        var pending=pollfd(fd:STDIN_FILENO,events:Int16(POLLIN),revents:0)
        if poll(&pending,1,250)==0{continue}
        do{
            guard let line=try boundedLine(STDIN_FILENO,seconds:30) else{return}
            try sendLine(line,fd)
            guard let request=try JSONSerialization.jsonObject(with:line) as? [String:Any] else{throw ReviewFault("invalid_arguments")}
            if request["id"]==nil{continue}
            let tool=(request["params"] as? [String:Any])?["name"] as? String
            let deadline=ProcessInfo.processInfo.systemUptime+max(200,tool.map { OwnerReadWire.seconds(for:$0)+10 } ?? 200)
            try forwardMioGatewayReply(request:request,readReply:{
                let remaining=deadline-ProcessInfo.processInfo.systemUptime
                guard remaining>0,caller.isCurrent() else{throw ReviewFault("transport_deadline")}
                return try responseLine(fd,seconds:remaining)
            },writeReply:{try sendLine($0,STDOUT_FILENO)})
        }
    }
}

/// Host-loop-only metadata about replies actually sent to the registered gateway.
/// This does not issue a catalog request or attest cloud/connector acceptance.
final class MioCatalogPublicationEvidence {
    private var sentCount = 0
    private var listChangedSent = 0
    func pendingListChanged(request:[String:Any])->[String:Any]? {
        guard sentCount==0,listChangedSent==0,request["method"] as? String=="tools/call",
              let params=request["params"] as? [String:Any],
              params["name"] as? String=="mio_tunnel_ping" else{return nil}
        return ["jsonrpc":"2.0","method":"notifications/tools/list_changed"]
    }
    func recordListChangedSent() {listChangedSent += 1}
    private var lastReply: [String: Any] = ["state": "not_observed"]

    func recordSent(request: [String: Any], response: [String: Any]) {
        guard request["method"] as? String == "tools/list" else { return }
        if sentCount < Int.max { sentCount += 1 }
        if let error = response["error"] as? [String: Any] {
            var value: [String: Any] = ["state": "protocol_error"]
            if let code = error["code"] as? Int,
               [-32700, -32600, -32601, -32602, -32603].contains(code) {
                value["jsonrpc_error_code"] = code
            }
            lastReply = value
            return
        }
        guard let result = response["result"] as? [String: Any],
              let tools = result["tools"] as? [[String: Any]],
              !tools.isEmpty else {
            lastReply = ["state": "metadata_unavailable"]
            return
        }
        let names = tools.compactMap { $0["name"] as? String }
        guard names.count == tools.count, Set(names).count == names.count,
              names.allSatisfy({ $0.range(of: "^[a-z][a-z0-9_]{1,79}$", options: .regularExpression) != nil }),
              let bytes = try? jsonBytes(tools), bytes.count <= 262144 else {
            lastReply = ["state": "metadata_unavailable"]
            return
        }
        lastReply = ["state": "catalog_sent_to_registered_gateway",
                     "tool_count": names.count, "tool_names": names,
                     "sorted_json_tools_sha256": digest(bytes),
                     "has_next_cursor": result["nextCursor"] != nil]
    }

    func snapshot() -> [String: Any] {
        ["schema_version": 1, "host_pid": Int(getpid()),
         "mio_build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
         "tools_list_replies_sent": sentCount, "last_tools_list_reply": lastReply,
         "list_changed_notifications_sent": listChangedSent,
         "list_changed_scope": "once_on_normal_ping_if_catalog_not_listed_this_host_generation",
         "scope": "current_host_generation_after_successful_socket_send",
         "gateway_stdout_forwarding_verified": false,
         "connector_schema_acceptance_verified": false]
    }

    func decoratePing(_ response: [String: Any], request: [String: Any]) -> [String: Any] {
        guard request["method"] as? String == "tools/call",
              let params = request["params"] as? [String: Any],
              params["name"] as? String == "mio_tunnel_ping",
              let arguments = (params["arguments"] ?? [:]) as? [String: Any], arguments.isEmpty,
              var result = response["result"] as? [String: Any],
              result["isError"] as? Bool == false,
              var content = result["content"] as? [[String: Any]],
              let text = try? jsonBytes(["mio_publication": snapshot()]) else { return response }
        content.append(["type": "text", "text": String(decoding: text, as: UTF8.self)])
        result["content"] = content
        var outgoing = response
        outgoing["result"] = result
        return outgoing
    }
}
