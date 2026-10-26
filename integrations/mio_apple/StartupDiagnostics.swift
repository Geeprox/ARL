import Foundation
import Darwin

// Closed metadata only. Never retain raw CLI text/NSError descriptions.
enum MioStartupDiagnostics {
    static let phases:Set<String>=["entry","setup_seal","setup_parent","setup_journal","setup_lock","setup_disclosure","setup_permission","setup_target","setup_confirmation","host_seal","host_profile","host_state","host_sockets","host_spawn","host_loop","client_seal","client_parent","client_group","client_sources","client_exec","gateway","setup","authorize","owned_stderr"]
    static let roles:Set<String>=["host","client","setup","gateway","authorize"]
    static let codes:Set<String>=["native_review_not_main","native_review_displayed","native_review_expired","native_review_cancelled","native_review_confirmed","setup_permission_requested","setup_permission_completed","native_interaction_expired","target_changed","needs_unlock","lock_state_unknown","needs_permission","target_unavailable","user_cancelled","user_cancelled_or_expired","native_setup_cancelled","native_session_invalid","starting","running","activation_not_sealed","activation_hash_changed","activation_disabled_or_invalid","unsafe_config","unsafe_journal","source_or_profile_changed","profile_host_binding_missing","host_lock_unavailable","host_already_running","existing_private_state","private_state_uncertain","existing_socket","socket_path_too_long","transport_unavailable","caller_unverified","signature_missing","client_group_unproven","client_launch_rejected","controlled_client_exited","owned_shutdown_unproven","unregistered_adapter","native_setup_rejected","native_setup_deadline","session_already_consumed","os_error","startup_rejected","mio_runtime_not_sealed","mio_runtime_manifest_changed","mio_runtime_resource_changed","upstream_cli_argument","upstream_profile_rejected","upstream_auth_rejected","upstream_access_rejected","upstream_tls_failed","upstream_stderr_other","stderr_oversize"]
    private static let state=Context()
    private final class Context:@unchecked Sendable { let lock=NSLock();var phase="entry";var role="host";var persist=false }
    static func context(role:String,phase:String="entry") {
        state.lock.lock();defer{state.lock.unlock()}
        state.role=roles.contains(role) ? role:"host";state.phase=phases.contains(phase) ? phase:"entry"
        let seal=Bundle.main.object(forInfoDictionaryKey:"ARLApprovedPolicySHA256") as? String
        state.persist=seal?.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil
    }
    static func phase(_ value:String) { state.lock.lock();defer{state.lock.unlock()};state.phase=phases.contains(value) ? value:"entry" }
    static func object(_ code:String,error:Error?=nil,role:String?=nil,phase:String?=nil)->[String:Any] {
        state.lock.lock();let r=state.role,p=state.phase;state.lock.unlock()
        var v:[String:Any]=["schema_version":1,"role":roles.contains(role ?? "") ? role!:r,"phase":phases.contains(phase ?? "") ? phase!:p,"code":codes.contains(code) ? code:"startup_rejected","checked_at_ms":Int64(Date().timeIntervalSince1970*1000)]
        if let e=error as NSError? {
            if e.domain==NSPOSIXErrorDomain { v["os_domain"]="posix";v["os_code"]=e.code }
            else if e.domain==NSCocoaErrorDomain { v["os_domain"]="cocoa";v["os_code"]=e.code }
        }
        return v
    }
    static func record(_ code:String,error:Error?=nil,role:String?=nil,phase:String?=nil) {
        state.lock.lock();let enabled=state.persist;state.lock.unlock()
        guard enabled else{return} // unapproved bundles/test doubles never touch production state
        let v=object(code,error:error,role:role,phase:phase)
        ARLConnectionLog.production.record("mio", "startup", ["code_sha256": ARLConnectionLog.fingerprint(v["code"]) ?? "", "os_code": v["os_code"] ?? 0])
        guard let data=try? JSONSerialization.data(withJSONObject:v,options:.sortedKeys),data.count<=1024 else{return}
        // One <=1KiB record per fixed role. Same approved private state, no
        // arbitrary file path. Diagnostics never confer authority or signal PIDs.
        let home=NSHomeDirectory()+"/Library/Application Support/ARL/mio-apple";var path=""
        for part in home.split(separator:"/") {
            path+="/"+part;var st=stat()
            guard lstat(path,&st)==0,st.st_mode&S_IFMT != S_IFLNK,st.st_uid==0 || st.st_uid==getuid(),st.st_mode&0o022==0 else{return}
        }
        let dir=open(home,O_RDONLY|O_DIRECTORY|O_NOFOLLOW);guard dir>=0 else{return};defer{close(dir)}
        var st=stat();guard fstat(dir,&st)==0,st.st_uid==getuid(),st.st_mode&0o077==0 else{return}
        let fd=openat(dir,(v["role"] as! String)+"-startup.json",O_WRONLY|O_CREAT|O_NOFOLLOW,0o600);guard fd>=0 else{return};defer{close(fd)}
        guard fstat(fd,&st)==0,st.st_mode&S_IFMT==S_IFREG,st.st_uid==getuid(),st.st_mode&0o077==0,st.st_nlink==1,ftruncate(fd,0)==0 else{return}
        _=data.withUnsafeBytes{write(fd,$0.baseAddress,data.count)};_=fsync(fd)
    }
    static func failure(_ error:Error) {
        let code=(error as? ReviewFault)?.code ?? "os_error"
        record(code,error:error)
        if let bytes=try? JSONSerialization.data(withJSONObject:object(code,error:error),options:.sortedKeys) { FileHandle.standardError.write(bytes+Data([10])) }
    }
    static func capture(_ pipe:Pipe,role:String,stream:String="stderr") {
        let parser=MioStderrClassifier()
        let output=ARLConnectionOutput(log:.production,source:role == "client" ? "tunnel":"mio",stream:stream)
        pipe.fileHandleForReading.readabilityHandler={handle in
            let data=handle.availableData
            output.feed(data,end:data.isEmpty)
            if data.isEmpty{handle.readabilityHandler=nil;return}
            guard stream == "stderr" else { return }
            for code in parser.feed(data) {
                // Native children already persisted their precise phase/OS code.
                // Only classify raw upstream stderr here; do not erase that record.
                if code.hasPrefix("upstream_") || code=="stderr_oversize" {
                    record(code,role:role,phase:"owned_stderr")
                }
            }
        }
    }
}

final class MioStderrClassifier:@unchecked Sendable {
    private let lock=NSLock();private var bytes=Data();private var dropping=false;private var emitted=Set<String>()
    func feed(_ data:Data)->[String] {
        lock.lock();defer{lock.unlock()};var result:[String]=[]
        for byte in data {
            if byte != 10 { if !dropping{if bytes.count<1024{bytes.append(byte)}else{bytes.removeAll();dropping=true}};continue }
            let code:String
            if dropping{code="stderr_oversize"}
            else if let v=(try? JSONSerialization.jsonObject(with:bytes)) as? [String:Any],let c=v["code"] as? String,MioStartupDiagnostics.codes.contains(c){code=c}
            else{
                let text=String(decoding:bytes,as:UTF8.self).lowercased()
                if text.contains("unexpected argument"){code="upstream_cli_argument"}
                else if text.contains("profile") && (text.contains("invalid") || text.contains("parse")){code="upstream_profile_rejected"}
                else if text.contains("unauthorized"){code="upstream_auth_rejected"}
                else if text.contains("forbidden"){code="upstream_access_rejected"}
                else if text.contains("certificate") || text.contains("tls"){code="upstream_tls_failed"}
                else{code="upstream_stderr_other"}
            }
            bytes.removeAll();dropping=false
            if emitted.count<8 && emitted.insert(code).inserted{result.append(code)}
        }
        return result
    }
}
