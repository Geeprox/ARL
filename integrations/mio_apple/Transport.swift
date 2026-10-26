import Foundation
import Darwin
import Security

func privateFile(_ path:String,limit:Int=65536)throws->Data {
    guard path.hasPrefix("/") else{throw ReviewFault("unsafe_config")}
    var current=""
    for part in path.split(separator:"/") {
        guard part != ".",part != ".." else{throw ReviewFault("unsafe_config")};current+="/"+part
        var st=stat();guard lstat(current,&st)==0,st.st_mode&S_IFMT != S_IFLNK else{throw ReviewFault("unsafe_config")}
    }
    let fd=open(path,O_RDONLY|O_NOFOLLOW);guard fd>=0 else{throw ReviewFault("unsafe_config")};defer{close(fd)}
    var st=stat();guard fstat(fd,&st)==0,st.st_mode&S_IFMT==S_IFREG,st.st_uid==getuid(),st.st_mode&0o022==0,st.st_size>0,st.st_size<=limit else{throw ReviewFault("unsafe_config")}
    return try FileHandle(fileDescriptor:fd,closeOnDealloc:false).readToEnd() ?? Data()
}
func processInfo(_ pid:Int32)throws->proc_bsdinfo {
    var info=proc_bsdinfo();guard proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&info,Int32(MemoryLayout<proc_bsdinfo>.size))==MemoryLayout<proc_bsdinfo>.size else{throw ReviewFault("caller_unverified")};return info
}
func peerPID(_ fd:Int32)throws->Int32 {
    var raw=[UInt8](repeating:0,count:32);var n:socklen_t=32
    guard getsockopt(fd,0,6,&raw,&n)==0,n==32 else{throw ReviewFault("caller_unverified")}
    return Data(raw).withUnsafeBytes{Int32($0.loadUnaligned(fromByteOffset:20,as:UInt32.self))}
}
#if ARL_MIO_HOST_TEST_ONLY
let mioBundleIdentifier="local.arl.mioapplebridge.fixture"
func ownRequirement()throws->String {
    var own:SecCode?;var staticCode:SecStaticCode?;var info:CFDictionary?
    guard Bundle.main.bundleIdentifier==mioBundleIdentifier,
          SecCodeCopySelf([], &own)==errSecSuccess,let own,
          SecCodeCopyStaticCode(own,[],&staticCode)==errSecSuccess,let staticCode,
          SecCodeCopySigningInformation(staticCode,SecCSFlags(rawValue:kSecCSSigningInformation),&info)==errSecSuccess,
          let values=info as? [String:Any],let hash=values[kSecCodeInfoUnique as String] as? Data else{throw ReviewFault("signature_missing")}
    return "identifier \"local.arl.mioapplebridge.fixture\" and cdhash H\""+hash.map{String(format:"%02x",$0)}.joined()+"\""
}
#else
let mioBundleIdentifier="local.arl.mioapplebridge"
func ownRequirement()throws->String {
    let requirement="identifier \"local.arl.mioapplebridge\" and certificate root = H\"859332b7fffbbbb33b80c7b78d30c27d2d81583f\""
    var own:SecCode?;var rule:SecRequirement?
    guard SecCodeCopySelf([], &own)==errSecSuccess,let own,
          SecRequirementCreateWithString(requirement as CFString,[],&rule)==errSecSuccess,let rule,
          SecCodeCheckValidity(own,SecCSFlags(rawValue:kSecCSStrictValidate),rule)==errSecSuccess
    else{throw ReviewFault("signature_missing")}
    return requirement
}
#endif

func address(_ path:String)throws->sockaddr_un {
    var a=sockaddr_un();let bytes=Array(path.utf8)+[0]
    guard bytes.count<=MemoryLayout.size(ofValue:a.sun_path) else{throw ReviewFault("socket_path_too_long")}
    a.sun_family=sa_family_t(AF_UNIX);a.sun_len=UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutableBytes(of:&a.sun_path){$0.copyBytes(from:bytes)};return a
}
func socketAt(_ path:String,listen:Bool)throws->Int32 {
    let fd=socket(AF_UNIX,SOCK_STREAM,0);guard fd>=0 else{throw ReviewFault("transport_unavailable")}
    do {
        var a=try address(path)
        let r=withUnsafePointer(to:&a){$0.withMemoryRebound(to:sockaddr.self,capacity:1){listen ? Darwin.bind(fd,$0,socklen_t(MemoryLayout<sockaddr_un>.size)):Darwin.connect(fd,$0,socklen_t(MemoryLayout<sockaddr_un>.size))}}
        guard r==0 else{throw ReviewFault("transport_unavailable")}
        if listen{guard chmod(path,0o600)==0,Darwin.listen(fd,1)==0 else{throw ReviewFault("transport_unavailable")}}
        return fd
    } catch {close(fd);throw error}
}
// Internal injection is for deterministic deadline regressions, not RPC config.
struct LineIO {
    let now:()->Double;let wait:(Int32,Int32)->Int32;let receive:(Int32)->(Int,UInt8)
    static var system:LineIO {LineIO(now:{ProcessInfo.processInfo.systemUptime},wait:{fd,ms in
        var p=pollfd(fd:fd,events:Int16(POLLIN),revents:0);return poll(&p,1,ms)
    },receive:{fd in var byte:UInt8=0;return (read(fd,&byte,1),byte)})}
}
func boundedLine(_ fd:Int32,limit:Int=65536,seconds:Double=30,io:LineIO = .system)throws->Data? {
    let deadline=io.now()+seconds;var result=Data()
    while result.count<limit {
        let left=deadline-io.now();guard left>0 else{throw ReviewFault("transport_deadline")}
        let waited=io.wait(fd,Int32(min(ceil(left*1000),30000)))
        if waited==0{continue} // slice timeout is not the overall deadline
        if waited<0{if errno==EINTR{continue};throw ReviewFault("transport_unavailable")}
        let (n,byte)=io.receive(fd)
        if n<0 && errno==EINTR{continue}
        if n==0{if result.isEmpty{return nil};throw ReviewFault("transport_truncated")}
        guard n==1 else{throw ReviewFault("transport_unavailable")}
        if byte==10{return result};result.append(byte)
    }
    throw ReviewFault("transport_size_exceeded")
}
// Gateway replies are newline-delimited JSON. The protocol has no length field
// and no 1 MiB ceiling. Read only through this response's delimiter, preserving
// a following line on the socket; deadlines still bound a missing delimiter.
func responseLine(_ fd: Int32, seconds: Double = 200) throws -> Data? {
    let deadline = ProcessInfo.processInfo.systemUptime + seconds
    var result = Data(), chunk = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
        let left = deadline - ProcessInfo.processInfo.systemUptime
        guard left > 0 else { throw ReviewFault("transport_deadline") }
        var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let waited = poll(&p, 1, Int32(min(ceil(left * 1000), 30000)))
        if waited == 0 { continue }
        if waited < 0 { if errno == EINTR { continue }; throw ReviewFault("transport_unavailable") }
        let available = chunk.withUnsafeMutableBytes { recv(fd, $0.baseAddress!, $0.count, MSG_PEEK | MSG_DONTWAIT) }
        if available < 0 && (errno == EAGAIN || errno == EINTR) { continue }
        if available == 0 { if result.isEmpty { return nil }; throw ReviewFault("transport_truncated") }
        guard available > 0 else { throw ReviewFault("transport_unavailable") }
        let newline = chunk.prefix(available).firstIndex(of: 10)
        let wanted = newline.map { $0 + 1 } ?? available
        let received = chunk.withUnsafeMutableBytes { recv(fd, $0.baseAddress!, wanted, MSG_DONTWAIT) }
        if received < 0 && (errno == EAGAIN || errno == EINTR) { continue }
        guard received > 0 else { throw ReviewFault("transport_unavailable") }
        let complete = newline != nil && received == wanted
        result.append(contentsOf: chunk.prefix(complete ? received - 1 : received))
        if complete { return result }
    }
}
func sendLine(_ data:Data,_ fd:Int32)throws {
    let flags=fcntl(fd,F_GETFL);guard flags>=0,fcntl(fd,F_SETFL,flags|O_NONBLOCK)==0 else{throw ReviewFault("transport_unavailable")}
    defer{_ = fcntl(fd,F_SETFL,flags)}
    let deadline=ProcessInfo.processInfo.systemUptime+5
    func writeAll(_ bytes: UnsafeRawBufferPointer) throws {
        var offset = 0
        while offset < bytes.count {
            let left=deadline-ProcessInfo.processInfo.systemUptime;guard left>0 else{throw ReviewFault("transport_deadline")}
            var p=pollfd(fd:fd,events:Int16(POLLOUT),revents:0)
            let waited=poll(&p,1,Int32(min(ceil(left*1000),5000)))
            if waited<0 && errno==EINTR {continue}
            guard waited>0 else{throw ReviewFault("transport_deadline")}
            let n=write(fd,bytes.baseAddress!.advanced(by:offset),min(bytes.count-offset,64*1024))
            if n<0 && (errno==EAGAIN || errno==EINTR){continue}
            guard n>0 else{throw ReviewFault("transport_unavailable")};offset+=n
        }
    }
    // Keep the original data buffer: a delimiter does not require copying JSON.
    try data.withUnsafeBytes { try writeAll($0) }
    var newline: UInt8 = 10
    try withUnsafeBytes(of: &newline) { try writeAll($0) }
}
func disconnected(_ fd:Int32)->Bool{var b:UInt8=0;return recv(fd,&b,1,MSG_PEEK|MSG_DONTWAIT)==0}

func registerControlledAdapter(_ fd:Int32,tunnelPID:Int32,requirement:String,enabled:@escaping()->Bool)throws->AuthenticatedCaller {
    let birth=try processInfo(tunnelPID);let pid=try peerPID(fd);let peerBirth=try processInfo(pid)
    guard peerBirth.pbi_ppid==UInt32(tunnelPID) else{throw ReviewFault("unregistered_adapter")}
    func current()->UInt64? {
        guard enabled(),let t=try? processInfo(tunnelPID),let c=try? processInfo(pid),
              t.pbi_start_tvsec==birth.pbi_start_tvsec,t.pbi_start_tvusec==birth.pbi_start_tvusec,
              c.pbi_ppid==UInt32(tunnelPID),c.pbi_start_tvsec==peerBirth.pbi_start_tvsec,c.pbi_start_tvusec==peerBirth.pbi_start_tvusec else{return nil}
        return 1
    }
    return try AuthenticatedCaller.fromRegisteredSocket(fd,subject:mioSubject,expectedPID:pid,requirement:requirement,registrationEpoch:1,currentRegistrationEpoch:current)
}

// Preserve the terminal response after a standard catalog notification. The
// pinned SDK forwards no-ID notifications while the same request is in flight.
// Forward original bytes so large integers/business JSON are never re-encoded.
func forwardMioGatewayReply(request:[String:Any],readReply:()throws->Data?,writeReply:(Data)throws->Void)throws {
    guard let requestID=request["id"] else{throw ReviewFault("invalid_arguments")}
    let expected=try jsonBytes(["id":requestID])
    while true {
        guard let bytes=try readReply() else{throw ReviewFault("transport_truncated")}
        guard let reply=try JSONSerialization.jsonObject(with:bytes) as? [String:Any] else{throw ReviewFault("invalid_response")}
        guard reply["jsonrpc"] as? String=="2.0" else{throw ReviewFault("invalid_response")}
        if reply["method"] != nil {
            guard Set(reply.keys)==["jsonrpc","method"],
                  reply["method"] as? String=="notifications/tools/list_changed"
            else{throw ReviewFault("invalid_response")}
            try writeReply(bytes);continue
        }
        guard let id=reply["id"],Set(reply.keys).isSubset(of:["jsonrpc","id","result","error"]),
              (reply["result"] != nil) != (reply["error"] != nil),
              (try jsonBytes(["id":id])==expected || id is NSNull && reply["error"] != nil)
        else{throw ReviewFault("invalid_response")}
        try writeReply(bytes);return
    }
}
