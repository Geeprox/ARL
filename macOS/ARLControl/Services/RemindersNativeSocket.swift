import Foundation
import CoreFoundation
import Darwin
import Security
import CryptoKit

struct RemindersTransportFault: Error, Sendable { let code:String;init(_ code:String){self.code=code} }

// The updated control has one exact reviewed Apple Development leaf; the
// helper retains its local certificate. No arbitrary team application is trusted.
enum RemindersStablePeerIdentity {
    static let certificateSHA1="859332b7fffbbbb33b80c7b78d30c27d2d81583f"
    static let controlRequirement="identifier \"local.arl.control\" and anchor apple generic and certificate leaf = H\"CD85BA24208488935F9AC0BEC63E4BE6AAE189C4\" and certificate leaf[subject.OU] = \"LGZF25R84Z\" and certificate 1[field.1.2.840.113635.100.6.2.1] exists and certificate leaf[field.1.2.840.113635.100.6.1.12] exists"
    static let helperRequirement="identifier \"local.arl.remindersbridge\" and certificate root = H\""+certificateSHA1+"\""
}

// Narrow adaptation of canonical mio_apple/Transport.swift and apple_review/
// PeerAuthentication.swift. Both sides authenticate the kernel audit token;
// neither PID text nor JSON flags authenticate a peer. No new general framework.
enum RemindersNativeIO {
    static func hash(_ bytes:Data)->String {SHA256.hash(data:bytes).map{String(format:"%02x",$0)}.joined()}
    static func integer(_ value:Any?)->Int? {
        guard let n=value as? NSNumber,CFGetTypeID(n) != CFBooleanGetTypeID(),!["f","d"].contains(String(cString:n.objCType)) else{return nil};return n.intValue
    }
    // Canonical flatObject duplicate-key check, restricted to integer/string/null.
    static func flatObject(_ data:Data,limit:Int=16384)throws->[String:Any] {
        guard (1...65536).contains(limit),data.count<=limit,let object=try JSONSerialization.jsonObject(with:data) as? [String:Any] else{throw RemindersTransportFault("invalid_arguments")}
        let bytes=Array(data);var index=0;var keys=Set<String>()
        func spaces(){while index<bytes.count,[9,10,13,32].contains(bytes[index]){index+=1}}
        func quoted()throws->String {
            guard index<bytes.count,bytes[index]==34 else{throw RemindersTransportFault("invalid_arguments")};let start=index;index+=1;var escape=false
            while index<bytes.count {let byte=bytes[index];index+=1;if escape{escape=false;continue};if byte==92{escape=true;continue};if byte==34 {guard let text=(try? JSONSerialization.jsonObject(with:Data(bytes[start..<index]),options:.fragmentsAllowed)) as? String else{throw RemindersTransportFault("invalid_arguments")};return text}}
            throw RemindersTransportFault("invalid_arguments")
        }
        spaces();guard index<bytes.count,bytes[index]==123 else{throw RemindersTransportFault("invalid_arguments")};index+=1;spaces()
        if index<bytes.count,bytes[index]==125{index+=1} else {
            while true {let key=try quoted();guard keys.insert(key).inserted else{throw RemindersTransportFault("duplicate_key")};spaces();guard index<bytes.count,bytes[index]==58 else{throw RemindersTransportFault("invalid_arguments")};index+=1;spaces()
                if index<bytes.count,bytes[index]==34{_=try quoted()}else{let start=index;while index<bytes.count,![44,125,9,10,13,32].contains(bytes[index]){index+=1};guard index>start else{throw RemindersTransportFault("invalid_arguments")};let token=String(decoding:bytes[start..<index],as:UTF8.self);guard token=="null" || token.range(of:#"^-?[0-9]+$"#,options:.regularExpression) != nil else{throw RemindersTransportFault("invalid_arguments")}}
                spaces();guard index<bytes.count else{throw RemindersTransportFault("invalid_arguments")};if bytes[index]==125{index+=1;break};guard bytes[index]==44 else{throw RemindersTransportFault("invalid_arguments")};index+=1;spaces()
            }
        }
        spaces();guard index==bytes.count,keys==Set(object.keys) else{throw RemindersTransportFault("invalid_arguments")};return object
    }
    static func privateFile(_ path:String,limit:Int=65536)throws->Data {
        guard path.hasPrefix("/") else{throw RemindersTransportFault("unsafe_config")};var current=""
        for part in path.split(separator:"/") {guard part != ".",part != ".." else{throw RemindersTransportFault("unsafe_config")};current+="/"+part;var st=stat();guard lstat(current,&st)==0,st.st_mode&S_IFMT != S_IFLNK else{throw RemindersTransportFault("unsafe_config")}}
        let fd=open(path,O_RDONLY|O_NOFOLLOW);guard fd>=0 else{throw RemindersTransportFault("unsafe_config")};defer{close(fd)};var st=stat()
        guard fstat(fd,&st)==0,st.st_mode&S_IFMT==S_IFREG,st.st_uid==getuid(),st.st_mode&0o077==0,st.st_nlink==1,st.st_size>0,st.st_size<=limit else{throw RemindersTransportFault("unsafe_config")}
        return try FileHandle(fileDescriptor:fd,closeOnDealloc:false).readToEnd() ?? Data()
    }
    static func privateDirectory(_ path:String)throws {
        var st=stat();guard lstat(path,&st)==0,st.st_mode&S_IFMT==S_IFDIR,st.st_uid==getuid(),st.st_mode&0o077==0 else{throw RemindersTransportFault("unsafe_home")}
        var current="";for part in path.split(separator:"/"){guard part != ".",part != ".." else{throw RemindersTransportFault("unsafe_home")};current+="/"+part;var item=stat();guard lstat(current,&item)==0,item.st_mode&S_IFMT != S_IFLNK else{throw RemindersTransportFault("unsafe_home")}}
    }
    static func writeNew(_ data:Data,to path:String)throws {
        let fd=open(path,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0o600);guard fd>=0 else{throw RemindersTransportFault("outcome_unknown")};defer{close(fd)}
        try data.withUnsafeBytes{raw in var offset=0;while offset<raw.count{let n=write(fd,raw.baseAddress!.advanced(by:offset),raw.count-offset);guard n>0 else{throw RemindersTransportFault("outcome_unknown")};offset+=n}}
        guard fsync(fd)==0 else{throw RemindersTransportFault("outcome_unknown")}
        let dir=open(URL(fileURLWithPath:path).deletingLastPathComponent().path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW);guard dir>=0 else{throw RemindersTransportFault("outcome_unknown")};defer{close(dir)};guard fsync(dir)==0 else{throw RemindersTransportFault("outcome_unknown")}
    }
    static func atomicWrite(_ data:Data,to path:String)throws {
        let tmp=path+".new-"+UUID().uuidString;try writeNew(data,to:tmp);guard rename(tmp,path)==0 else{throw RemindersTransportFault("outcome_unknown")}
        let dir=open(URL(fileURLWithPath:path).deletingLastPathComponent().path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW);guard dir>=0 else{throw RemindersTransportFault("outcome_unknown")};defer{close(dir)};guard fsync(dir)==0 else{throw RemindersTransportFault("outcome_unknown")}
    }
    static func socketAt(_ path:String,listen:Bool)throws->Int32 {
        var address=sockaddr_un();let bytes=Array(path.utf8)+[0];guard bytes.count<=MemoryLayout.size(ofValue:address.sun_path) else{throw RemindersTransportFault("socket_path_too_long")}
        address.sun_family=sa_family_t(AF_UNIX);address.sun_len=UInt8(MemoryLayout<sockaddr_un>.size);withUnsafeMutableBytes(of:&address.sun_path){$0.copyBytes(from:bytes)}
        let fd=socket(AF_UNIX,SOCK_STREAM,0);guard fd>=0 else{throw RemindersTransportFault("transport_unavailable")}
        do {let result=withUnsafePointer(to:&address){$0.withMemoryRebound(to:sockaddr.self,capacity:1){listen ? Darwin.bind(fd,$0,socklen_t(MemoryLayout<sockaddr_un>.size)):Darwin.connect(fd,$0,socklen_t(MemoryLayout<sockaddr_un>.size))}};guard result==0 else{throw RemindersTransportFault("transport_unavailable")}
            var noSignal:Int32=1;guard setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&noSignal,socklen_t(MemoryLayout<Int32>.size))==0,fcntl(fd,F_SETFD,FD_CLOEXEC)==0 else{throw RemindersTransportFault("transport_unavailable")}
            if listen{guard chmod(path,0o600)==0,Darwin.listen(fd,8)==0 else{throw RemindersTransportFault("transport_unavailable")}};return fd
        } catch{close(fd);throw error}
    }
    static func line(_ fd:Int32,limit:Int=16384,seconds:Double=4)throws->Data? {
        let deadline=ProcessInfo.processInfo.systemUptime+seconds;var result=Data()
        while result.count<=limit {let left=deadline-ProcessInfo.processInfo.systemUptime;guard left>0 else{throw RemindersTransportFault("transport_deadline")};var p=pollfd(fd:fd,events:Int16(POLLIN),revents:0);let r=poll(&p,1,Int32(min(ceil(left*1000),30000)));if r==0{continue};if r<0{if errno==EINTR{continue};throw RemindersTransportFault("transport_unavailable")};var byte:UInt8=0;let n=read(fd,&byte,1);if n<0 && errno==EINTR{continue};if n==0{if result.isEmpty{return nil};throw RemindersTransportFault("transport_truncated")};guard n==1 else{throw RemindersTransportFault("transport_unavailable")};if byte==10{return result};guard result.count<limit else{throw RemindersTransportFault("transport_size_exceeded")};result.append(byte)}
        throw RemindersTransportFault("transport_size_exceeded")
    }
    static func send(_ data:Data,_ fd:Int32,limit:Int=16384)throws {
        guard (1...262144).contains(limit),data.count<=limit else{throw RemindersTransportFault("transport_size_exceeded")};let flags=fcntl(fd,F_GETFL);guard flags>=0,fcntl(fd,F_SETFL,flags|O_NONBLOCK)==0 else{throw RemindersTransportFault("transport_unavailable")};defer{_=fcntl(fd,F_SETFL,flags)}
        var all=data;all.append(10);var offset=0;let deadline=ProcessInfo.processInfo.systemUptime+5
        while offset<all.count{let left=deadline-ProcessInfo.processInfo.systemUptime;guard left>0 else{throw RemindersTransportFault("transport_deadline")};var p=pollfd(fd:fd,events:Int16(POLLOUT),revents:0);guard poll(&p,1,Int32(min(left*1000,5000)))>0 else{throw RemindersTransportFault("transport_deadline")};let n=all.withUnsafeBytes{write(fd,$0.baseAddress!.advanced(by:offset),all.count-offset)};if n<0 && (errno==EAGAIN || errno==EINTR){continue};guard n>0 else{throw RemindersTransportFault("transport_unavailable")};offset+=n}
    }
    static func disconnected(_ fd:Int32)->Bool {var b:UInt8=0;return recv(fd,&b,1,MSG_PEEK|MSG_DONTWAIT)==0}
    struct Peer: Sendable {
        let fd:Int32;let token:Data;let requirement:String
        init(_ fd:Int32,requirement:String)throws {
            guard requirement==RemindersStablePeerIdentity.controlRequirement || requirement==RemindersStablePeerIdentity.helperRequirement || requirement.range(of:#"^cdhash H"[a-fA-F0-9]{40,64}"$"#,options:.regularExpression) != nil || requirement.range(of:#"^identifier "[A-Za-z0-9.-]+" and anchor apple generic and certificate leaf\[subject\.OU\] = "[A-Z0-9]{10}"$"#,options:.regularExpression) != nil else{throw RemindersTransportFault("identity_unverified")}
            self.fd=fd;self.requirement=requirement;var raw=[UInt8](repeating:0,count:32);var size:socklen_t=32;guard getsockopt(fd,0,6,&raw,&size)==0,size==32 else{throw RemindersTransportFault("identity_unverified")};token=Data(raw)
            let uid=token.withUnsafeBytes{$0.loadUnaligned(fromByteOffset:4,as:UInt32.self)};guard uid==getuid(),current() else{throw RemindersTransportFault("identity_unverified")}
        }
        func current()->Bool {
            var raw=[UInt8](repeating:0,count:32);var size:socklen_t=32;guard getsockopt(fd,0,6,&raw,&size)==0,size==32,Data(raw)==token else{return false}
            return signatureCurrent()
        }
        // LOCAL_PEERTOKEN may cease to be available after orderly remote EOF.
        // Revalidate the original *kernel-derived* token, including pidversion,
        // through Security after the bounded final response. Never fall back to
        // a PID string, claimed identity, or a token supplied in JSON.
        func signatureCurrent()->Bool {
            var rule:SecRequirement?;var guest:SecCode?
            guard SecRequirementCreateWithString(requirement as CFString,[],&rule)==errSecSuccess,let rule,SecCodeCopyGuestWithAttributes(nil,[kSecGuestAttributeAudit as String:token] as CFDictionary,[],&guest)==errSecSuccess,let guest else{return false}
            return SecCodeCheckValidity(guest,SecCSFlags(rawValue:kSecCSStrictValidate),rule)==errSecSuccess
        }
    }
}
