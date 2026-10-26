import Foundation
import Darwin
import Security

func establishControlledClientGroup() throws {
    let pid = getpid()
    // Foundation.Process already puts its child in its own group on macOS.
    guard getpgid(pid) >= 0 else { throw ReviewFault("client_group_unproven") }
    if getpgid(pid) != pid {
        guard setpgid(0, 0) == 0 else { throw ReviewFault("client_group_unproven") }
    }
    guard getpgid(pid) == pid else { throw ReviewFault("client_group_unproven") }
}

final class HostStop: @unchecked Sendable {
    private let lock=NSLock();private var value=false
    func request(){lock.lock();value=true;lock.unlock()}
    var requested:Bool{lock.lock();defer{lock.unlock()};return value}
}
struct OwnedPID {
    let pid:Int32;let seconds:UInt64;let micros:UInt64
    init(_ pid:Int32)throws{let p=try processInfo(pid);self.pid=pid;seconds=p.pbi_start_tvsec;micros=p.pbi_start_tvusec}
    var sameBirth:Bool{guard let p=try? processInfo(pid) else{return false};return p.pbi_start_tvsec==seconds && p.pbi_start_tvusec==micros}
    var current:Bool {guard let p=try? processInfo(pid) else{return false};return sameBirth && p.pbi_status != 5} // Darwin SZOMB
    func signal(_ signal:Int32){if current{_ = kill(pid,signal)}}
    func stopped(by deadline:Double)->Bool{
        while current && ProcessInfo.processInfo.systemUptime<deadline{usleep(10000)}
        return !current
    }
}
func stopOwned(_ process:Process,tunnel:OwnedPID,gateway:OwnedPID?)throws {
    // Only identities captured from this controlled Process/kernel connection.
    // No PID scanning, process-name matching or arbitrary kill endpoint.
    func groupSignal(_ value:Int32){
        if (tunnel.sameBirth && getpgid(tunnel.pid)==tunnel.pid) || (gateway?.current == true && getpgid(gateway!.pid)==tunnel.pid){_ = kill(-tunnel.pid,value)}
    }
    groupSignal(SIGTERM);gateway?.signal(SIGTERM);tunnel.signal(SIGTERM)
    let deadline=ProcessInfo.processInfo.systemUptime+2
    let gatewayStopped=gateway?.stopped(by:deadline) ?? true
    let tunnelStopped=tunnel.stopped(by:deadline)
    if !gatewayStopped{gateway?.signal(SIGKILL)}
    if !tunnelStopped{tunnel.signal(SIGKILL)}
    groupSignal(SIGKILL)
    let final=ProcessInfo.processInfo.systemUptime+2
    guard gateway?.stopped(by:final) ?? true,tunnel.stopped(by:final) else{throw ReviewFault("owned_shutdown_unproven")}
    process.waitUntilExit() // death established first; reap our child
    while kill(-tunnel.pid,0)==0 && ProcessInfo.processInfo.systemUptime<final{usleep(10000)}
    guard kill(-tunnel.pid,0) != 0,errno==ESRCH else{throw ReviewFault("owned_shutdown_unproven")}
}
func verifyOwnedSignature(_ pid:Int32,requirement:String)throws {
    let req:SecRequirement
    var r:SecRequirement?;guard SecRequirementCreateWithString(requirement as CFString,[],&r)==errSecSuccess,let r else{throw ReviewFault("caller_unverified")};req=r
    var code:SecCode?
    guard SecCodeCopyGuestWithAttributes(nil,[kSecGuestAttributePid:pid] as CFDictionary,[],&code)==errSecSuccess,let code,
          SecCodeCheckValidity(code,SecCSFlags(rawValue:kSecCSStrictValidate),req)==errSecSuccess else{throw ReviewFault("caller_unverified")}
}
func writePrivateNew(_ path:String,_ bytes:Data)throws {
    let fd=open(path,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0o600);guard fd>=0 else{throw ReviewFault("existing_private_state")}
    let size=bytes.withUnsafeBytes{write(fd,$0.baseAddress,bytes.count)};let durable=size==bytes.count && fsync(fd)==0;close(fd)
    guard durable else{throw ReviewFault("private_state_uncertain")}
    let dir=open(URL(fileURLWithPath:path).deletingLastPathComponent().path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW)
    guard dir>=0 else{throw ReviewFault("private_state_uncertain")};defer{close(dir)}
    guard fsync(dir)==0 else{throw ReviewFault("private_state_uncertain")}
}
func lockHostHome(_ home:String)throws->Int32 {
    let fd=open(home+"/host.lock",O_RDWR|O_CREAT|O_NOFOLLOW,0o600)
    guard fd>=0 else{throw ReviewFault("host_lock_unavailable")}
    var info=stat()
    guard fstat(fd,&info)==0,info.st_uid==getuid(),info.st_mode&S_IFMT==S_IFREG,info.st_mode&0o077==0,fcntl(fd,F_SETFD,FD_CLOEXEC)==0,flock(fd,LOCK_EX|LOCK_NB)==0 else{close(fd);throw ReviewFault("host_already_running")}
    return fd
}
func recoverStoppedHost(_ home:String)throws {
    let marker=home+"/owned-child.json"
    if access(marker,F_OK) != 0{return}
    let p=try flatObject(privateFile(marker))
    guard Set(p.keys)==Set(["pid","birth_seconds","birth_micros"]),let pid=integer(p["pid"]),pid>0,pid<=Int64(Int32.max),let sec=integer(p["birth_seconds"]),sec>=0,let micro=integer(p["birth_micros"]),micro>=0 else{throw ReviewFault("owned_shutdown_unproven")}
    if let info=try? processInfo(Int32(pid)),info.pbi_start_tvsec==UInt64(sec),info.pbi_start_tvusec==UInt64(micro){throw ReviewFault("owned_shutdown_unproven")}
    guard kill(-Int32(pid),0) != 0,errno==ESRCH else{throw ReviewFault("owned_shutdown_unproven")}
    // Lock is held and old owned group is proven absent. Never signal a stale
    // marker PID. Delete only fixed known private runtime objects, not journal.
    for name in ["active-profile.yaml","mio.sock","control.sock","owned-child.json"]{
        let path=home+"/"+name;var st=stat()
        if lstat(path,&st)==0{guard st.st_uid==getuid(),st.st_mode&S_IFMT != S_IFLNK,st.st_mode&0o077==0 else{throw ReviewFault("unsafe_private_state")};guard unlink(path)==0 else{throw ReviewFault("private_state_uncertain")}}
    }
}
