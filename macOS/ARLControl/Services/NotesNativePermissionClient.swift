import Foundation
import Security
import Darwin
import CoreFoundation

struct NotesControlFault: Error, Sendable { let code: String; init(_ code: String) { self.code=code } }
final class NotesControlCancellation: @unchecked Sendable {
    private let lock=NSLock(); private var flag=false
    func cancel() { lock.lock();flag=true;lock.unlock() }
    var requested:Bool { lock.lock();defer{lock.unlock()};return flag }
}
struct NotesPermissionDeployment: Decodable, Sendable {
    private static let signedControlRequirement="identifier \"local.arl.control\" and certificate root = H\"859332b7fffbbbb33b80c7b78d30c27d2d81583f\""
    private static let signedHelperRequirement="identifier \"local.arl.notesbridge\" and certificate root = H\"859332b7fffbbbb33b80c7b78d30c27d2d81583f\""
    let schema_version:Int, enabled:Int, epoch:Int, expires_at_ms:Int64
    let control_requirement:String, helper_executable:String, helper_bundle_id:String, helper_requirement:String
    let helper_executable_sha256:String, helper_designated_requirement_sha256:String, helper_cdhash:String
    let profile_path:String, profile_sha256:String, source_closure_sha256:String, surface_scope:String
    let request_id:String, capability_id:String
    static func load(home:URL)throws->Self {
        let raw=try RemindersNativeIO.privateFile(home.appendingPathComponent("notes-v2/control.json").path)
        let object=try RemindersNativeIO.flatObject(raw)
        let keys:Set<String>=["schema_version","enabled","epoch","expires_at_ms","control_requirement","helper_executable","helper_bundle_id","helper_requirement","helper_executable_sha256","helper_designated_requirement_sha256","helper_cdhash","profile_path","profile_sha256","source_closure_sha256","surface_scope","request_id","capability_id"]
        guard Set(object.keys)==keys,RemindersNativeIO.integer(object["schema_version"])==1 else{throw NotesControlFault("invalid_deployment")}
        let value=try JSONDecoder().decode(Self.self,from:raw)
        guard [0,1].contains(value.enabled),value.epoch>0,NotesIntegrationRecord.records.contains(where:{$0.id==value.capability_id}),UUID(uuidString:value.request_id)?.uuidString.lowercased()==value.request_id,
              value.helper_cdhash.range(of:"^[a-f0-9]{40}$",options:.regularExpression) != nil,
              (value.surface_scope=="native_permission_api" ? value.control_requirement==signedControlRequirement && value.helper_requirement==signedHelperRequirement
                  : value.surface_scope=="synthetic_only" && value.control_requirement.range(of:"^cdhash H\"[a-f0-9]{40}\"$",options:.regularExpression) != nil && value.helper_requirement=="cdhash H\""+value.helper_cdhash+"\""),
              [value.helper_executable_sha256,value.helper_designated_requirement_sha256,value.profile_sha256,value.source_closure_sha256].allSatisfy({$0.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil}),
              value.helper_executable.hasPrefix("/"),value.profile_path.hasPrefix("/") else{throw NotesControlFault("invalid_deployment")}
        return value
    }
    func verify()throws {
        var own:SecCode?, rule:SecRequirement?
        guard SecCodeCopySelf([],&own)==errSecSuccess,let own,SecRequirementCreateWithString(control_requirement as CFString,[],&rule)==errSecSuccess,let rule,
              SecCodeCheckValidity(own,SecCSFlags(rawValue:kSecCSStrictValidate),rule)==errSecSuccess else{throw NotesControlFault("control_identity_changed")}
        if surface_scope=="synthetic_only" {
            guard helper_bundle_id=="local.arl.notessynthetic",Bundle.main.bundleIdentifier=="local.arl.control.dev" else{throw NotesControlFault("invalid_deployment")}
        } else { guard surface_scope=="native_permission_api",helper_bundle_id=="local.arl.notesbridge" else{throw NotesControlFault("invalid_deployment")} }
        var code:SecStaticCode?, requirement:SecRequirement?, dr:SecRequirement?, drData:CFData?, info:CFDictionary?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath:helper_executable) as CFURL,[],&code)==errSecSuccess,let code,
              SecRequirementCreateWithString(helper_requirement as CFString,[],&requirement)==errSecSuccess,let requirement,
              SecStaticCodeCheckValidity(code,SecCSFlags(rawValue:kSecCSStrictValidate),requirement)==errSecSuccess,
              SecCodeCopyDesignatedRequirement(code,[],&dr)==errSecSuccess,let dr,SecRequirementCopyData(dr,[],&drData)==errSecSuccess,let drData,
              RemindersNativeIO.hash(drData as Data)==helper_designated_requirement_sha256,
              SecCodeCopySigningInformation(code,SecCSFlags(rawValue:kSecCSSigningInformation),&info)==errSecSuccess,
              (info as? [String:Any])?[kSecCodeInfoIdentifier as String] as? String==helper_bundle_id,
              let observedCDHash=(info as? [String:Any])?[kSecCodeInfoUnique as String] as? Data,
              observedCDHash.map({String(format:"%02x",$0)}).joined()==helper_cdhash else{throw NotesControlFault("helper_identity_changed")}
        var st=stat();guard lstat(helper_executable,&st)==0,st.st_mode&S_IFMT==S_IFREG,st.st_uid==getuid(),st.st_mode&0o022==0,
              URL(fileURLWithPath:helper_executable).resolvingSymlinksInPath().path==helper_executable,
              RemindersNativeIO.hash(try Data(contentsOf:URL(fileURLWithPath:helper_executable)))==helper_executable_sha256 else{throw NotesControlFault("helper_identity_changed")}
        let profile=try RemindersNativeIO.privateFile(profile_path)
        guard RemindersNativeIO.hash(profile)==profile_sha256 else{throw NotesControlFault("profile_changed")}
        let fields=try RemindersNativeIO.flatObject(profile)
        guard fields["session_kind"] as? String=="permission_setup",fields["caller_requirement"] as? String==control_requirement,
              fields["request_id"] as? String==request_id,fields["capability_id"] as? String==capability_id,
              fields["source_closure_sha256"] as? String==source_closure_sha256,
              RemindersNativeIO.integer(fields["epoch"])==epoch,RemindersNativeIO.integer(fields["expires_at_ms"])==Int(expires_at_ms),
              RemindersNativeIO.integer(fields["max_requests"])==1,fields["request_origin"] as? String=="manual_user_action",
              fields["mode"] as? String==(surface_scope=="synthetic_only" ? "synthetic":"notes"),
              RemindersNativeIO.integer(fields["enabled"])==enabled else{throw NotesControlFault("profile_changed")}
    }
    var current:Bool { let age=expires_at_ms-Int64(Date().timeIntervalSince1970*1000);return enabled==1 && age>0 && age<=120000 }
}

struct NotesNativePermissionReply: Sendable {
    let records:[NotesPermissionStatus]
    let outcome:String
    let synthetic:Bool
}
struct NotesPermissionStatus: Sendable {
    let capabilityID:String, state:String, code:String
    let observedAtMS:Int64
    var fresh:Bool{let age=Int64(Date().timeIntervalSince1970*1000)-observedAtMS;return age>=0 && age<=30000}
}

struct NotesNativePermissionClient: Sendable {
    let home:URL
    func request(_ approved:NotesPermissionDeployment,cancel:NotesControlCancellation) async throws->NotesNativePermissionReply {
        try await Task.detached { try Self.session(approved,home:home,cancel:cancel,requestPermission:true) }.value
    }
    func snapshot(_ approved:NotesPermissionDeployment) async throws->[NotesPermissionStatus] {
        try await Task.detached { try Self.session(approved,home:home,cancel:NotesControlCancellation(),requestPermission:false).records }.value
    }
    private static func session(_ d:NotesPermissionDeployment,home:URL,cancel:NotesControlCancellation,requestPermission:Bool)throws->NotesNativePermissionReply {
        try d.verify();guard d.current,!cancel.requested else{throw NotesControlFault("profile_not_admitted")}
        let admissions=home.appendingPathComponent("notes-v2/control-admissions").path
        try RemindersNativeIO.privateDirectory(admissions)
        if requestPermission {
            // Consume the exact admitted UI UUID before an OS permission request.
            try RemindersNativeIO.writeNew(Data("pending_permission_request_no_automatic_replay\n".utf8),to:admissions+"/"+d.request_id)
        }
        let deadline=ProcessInfo.processInfo.systemUptime+Double(d.expires_at_ms-Int64(Date().timeIntervalSince1970*1000))/1000
        var sockets:[Int32]=[0,0];guard socketpair(AF_UNIX,SOCK_STREAM,0,&sockets)==0 else{throw NotesControlFault("transport_unavailable")}
        let fd=sockets[0],child=sockets[1];_ = fcntl(fd,F_SETFD,FD_CLOEXEC);_ = fcntl(child,F_SETFD,FD_CLOEXEC)
        var noSignal:Int32=1;_=setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&noSignal,socklen_t(MemoryLayout<Int32>.size))
        var actions:posix_spawn_file_actions_t?;guard posix_spawn_file_actions_init(&actions)==0 else{close(fd);close(child);throw NotesControlFault("spawn_failed")}
        defer{posix_spawn_file_actions_destroy(&actions)}
        if fd != 3{posix_spawn_file_actions_addclose(&actions,fd)};posix_spawn_file_actions_adddup2(&actions,child,3)
        if child != 3{posix_spawn_file_actions_addclose(&actions,child)}
        posix_spawn_file_actions_addopen(&actions,1,"/dev/null",O_WRONLY,0);posix_spawn_file_actions_addopen(&actions,2,"/dev/null",O_WRONLY,0)
        let args=[strdup(d.helper_executable),strdup("--serve-permissions-controlled-v2"),nil]
        let environment=[strdup("PATH=/usr/bin:/bin"),nil];defer{for p in args+environment{free(p)}}
        var pid:pid_t=0
        let status=args.withUnsafeBufferPointer{a in environment.withUnsafeBufferPointer{e in posix_spawn(&pid,d.helper_executable,&actions,nil,UnsafeMutablePointer(mutating:a.baseAddress!),UnsafeMutablePointer(mutating:e.baseAddress!))}}
        close(child);guard status==0 else{close(fd);throw NotesControlFault("spawn_failed")}
        var dispatched=false, returned=false
        defer {
            close(fd)
            // A blocked OS request retains this worker/peer/child until return.
            // Termination is only after a complete response or before dispatch.
            if !dispatched || returned { var result:Int32=0;for _ in 0..<40{if waitpid(pid,&result,WNOHANG)==pid{break};Thread.sleep(forTimeInterval:0.05)};if waitpid(pid,&result,WNOHANG)==0{kill(pid,SIGTERM);_=waitpid(pid,&result,0)} }
            else { let childPID=pid;DispatchQueue.global().async { var result:Int32=0;while waitpid(childPID,&result,0)<0 && errno==EINTR {} } }
        }
        func send(_ object:[String:Any])throws{try RemindersNativeIO.send(MessagesJSON(object).data,fd)}
        func read(_ method:String,waitForNativeReturn:Bool=false)throws->[String:Any] {
            var data=Data()
            while true {
                if !waitForNativeReturn && (cancel.requested || ProcessInfo.processInfo.systemUptime>=deadline){throw NotesControlFault("cancelled")}
                var p=pollfd(fd:fd,events:Int16(POLLIN),revents:0);let ready=poll(&p,1,100)
                if ready<0 && errno==EINTR{continue};guard ready>=0 else{throw NotesControlFault("transport_disconnected")};if ready==0{continue}
                var byte:UInt8=0;let count=recv(fd,&byte,1,0)
                guard count==1 else{throw NotesControlFault(dispatched ? "permission_needs_review":"transport_disconnected")}
                if byte==10{if waitForNativeReturn{returned=true};break};data.append(byte);guard data.count+1<=65536 else{throw NotesControlFault("invalid_response")}
            }
            return try NotesPermissionWire.decodeEnvelope(data,method:method)
        }
        try send(["schema_version":2,"method":"register_identity","executable_sha256":d.helper_executable_sha256,"designated_requirement_sha256":d.helper_designated_requirement_sha256])
        let ready=try read("bootstrap");try NotesPermissionWire.validateBootstrap(ready,d,pid:pid,parent:getpid())
        let peer=try RemindersNativeIO.Peer(fd,requirement:d.helper_requirement)
        guard peer.token.withUnsafeBytes({$0.loadUnaligned(fromByteOffset:20,as:UInt32.self)})==UInt32(pid) else{throw NotesControlFault("identity_unverified")}
        func admitted()throws{try d.verify();guard peer.current(),d.current,!cancel.requested else{throw NotesControlFault("cancelled")}}
        try admitted();try send(["schema_version":2,"method":"permissions_snapshot"]);let first=try NotesPermissionWire.catalog(read("permissions_snapshot"),d);try admitted()
        if !requestPermission {
            try send(["schema_version":2,"method":"finish"])
            return .init(records:first,outcome:"snapshot_only",synthetic:d.surface_scope=="synthetic_only")
        }
        dispatched=true
        try send(["schema_version":2,"method":"permissions_request","action":"request","request_id":d.request_id,"capability_id":d.capability_id])
        let result=try read("permissions_request",waitForNativeReturn:true);returned=true;try admitted()
        let outcome=try NotesPermissionWire.requestResult(result,d)
        try send(["schema_version":2,"method":"permissions_snapshot"]);let catalog=try read("permissions_snapshot");try admitted()
        let records=try NotesPermissionWire.catalog(catalog,d)
        try send(["schema_version":2,"method":"finish"])
        return .init(records:records,outcome:outcome,synthetic:d.surface_scope=="synthetic_only")
    }
}
