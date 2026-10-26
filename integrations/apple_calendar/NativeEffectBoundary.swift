import Foundation
import CryptoKit
import Darwin

// Compiled seal generated from the proposal and isolated launcher, not stdin/env.
func calendarAccountHome() -> String {
    guard let entry=getpwuid(getuid()) else { emit(["status":"unsafe_review_file"]) }
    return String(cString:entry.pointee.pw_dir)
}
func digest(_ data:Data)->String { SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined() }
func nativePathHasNoSymlink(_ path:String)->Bool {
    guard path.hasPrefix("/") else{return false}
    var current=""
    for part in path.split(separator:"/") {
        guard part != ".",part != ".." else{return false}
        current+="/"+part;var info=stat()
        guard lstat(current,&info)==0,info.st_mode&S_IFMT != S_IFLNK else{return false}
    }
    return true
}
func privateNativeFile(_ path:String, limit:Int=65536)->Data? {
    guard nativePathHasNoSymlink(path) else {return nil}
    let fd=open(path,O_RDONLY|O_NOFOLLOW);guard fd>=0 else{return nil};defer{close(fd)}
    var info=stat();guard fstat(fd,&info)==0,info.st_uid==getuid(),info.st_mode&S_IFMT==S_IFREG,info.st_mode&0o077==0,info.st_size<=limit else{return nil}
    var buffer=[UInt8](repeating:0,count:limit+1);let size=read(fd,&buffer,buffer.count)
    guard size>=0,size<=limit else{return nil};return Data(buffer.prefix(size))
}
func sealedReview(_ home:String,_ args:[String:Any])->String? {
    var dir=stat()
    guard lstat(home,&dir)==0,dir.st_uid==getuid(),dir.st_mode&S_IFMT==S_IFDIR,dir.st_mode&0o077==0,
          nativePathHasNoSymlink(home) else{return "unsafe_review_file"}
    guard let raw=privateNativeFile(home+"/review.json",limit:16384),
          let review=(try? JSONSerialization.jsonObject(with:raw)) as? [String:Any],Set(review.keys)==Set(["args","expires_at_ms"]),
          let actual=args as? [String:String],actual==calendarSealedArgs,
          let approved=review["args"] as? [String:String],approved==calendarSealedArgs,
          let expires=review["expires_at_ms"] as? NSNumber,CFGetTypeID(expires) != CFBooleanGetTypeID() else{return "review_not_authorized"}
    let expiry=expires.doubleValue;let now=Date().timeIntervalSince1970*1000
    guard expiry.isFinite,expiry.rounded()==expiry,expiry>now,expiry<=now+600000 else{return "review_expired"}
    // A one-use marker belongs to this exact one-event package. Existence (even
    // uncertain or malformed) refuses replay; no unlink/reset path is provided.
    var s=stat()
    if lstat((home+"/native-consumed.json"),&s)==0{return "operation_consumed"}
    return nil
}
func nativeSealedEffect(_ request:[String:Any],home:String)->[String:Any] {
    guard Set(request.keys)==Set(["tool","args"]),request["tool"] as? String=="apple.calendar.create.v1",
          let args=request["args"] as? [String:Any] else {return ["status":"review_not_authorized"]}
    if let error=sealedReview(home,args){return ["status":error]}
    #if !CALENDAR_EFFECT_FIXTURE
    guard ["write_only","full_access"].contains(auth()) else{return ["status":"needs_permission"]}
    #endif
    let marker=home+"/native-consumed.json";let fd=open(marker,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0o600)
    guard fd>=0 else{return ["status":errno==EEXIST ? "operation_consumed":"unsafe_review_file"]}
    let record=Data(("{\"operation_id\":\""+calendarSealedArgs["operation_id"]!+"\",\"state\":\"consumed_or_uncertain\"}\n").utf8)
    let written=record.withUnsafeBytes{write(fd,$0.baseAddress,record.count)}
    let durable=written==record.count && fsync(fd)==0;close(fd)
    let directory=open(home,O_RDONLY|O_DIRECTORY);let dirDurable=directory>=0 && fsync(directory)==0;if directory>=0{close(directory)}
    guard durable,dirDurable else{return ["status":"outcome_unknown"]}
    // Recheck expiry after the durable consume, immediately before any EventKit
    // construction/save. A late expiry stays consumed, never replayed.
    guard let raw=privateNativeFile(home+"/review.json",limit:16384),
          let sealed=(try? JSONSerialization.jsonObject(with:raw)) as? [String:Any],
          sealed["args"] as? [String:String]==calendarSealedArgs,
          let expiry=sealed["expires_at_ms"] as? NSNumber,expiry.doubleValue>Date().timeIntervalSince1970*1000 else{return ["status":"review_expired"]}
    #if CALENDAR_EFFECT_FIXTURE
    // Test executable cannot reach EventKit, even with a grant. This independent
    // compile mode is never packaged/installed as the production helper.
    if ProcessInfo.processInfo.environment["ARL_FIXTURE_CRASH_AFTER_CONSUME"]=="1"{exit(77)}
    let fixture=home+"/fixture-effect";let out=open(fixture,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0o600)
    guard out>=0 else{return ["status":"outcome_unknown"]};close(out)
    return ["status":"saved_local","operation_id":calendarSealedArgs["operation_id"]!]
    #else
    return saveCalendarEvent(args)
    #endif
}
func stopOwned(_ process:Process) {
    if process.isRunning{process.terminate()}
    let deadline=Date().addingTimeInterval(1)
    while process.isRunning && Date()<deadline{Thread.sleep(forTimeInterval:0.01)}
    if process.isRunning{kill(process.processIdentifier,SIGKILL)}
}
func runNativeBroker(home:String,launcher:String,launcherSHA:String,fixture:Bool=false)->Never {
    guard privateNativeFile(launcher).map({digest($0)==launcherSHA})==true else{emit(["status":"launcher_changed"])}
    if let error=sealedReview(home,calendarSealedArgs){emit(["status":error])}
    let process=Process();process.executableURL=URL(fileURLWithPath:"/usr/bin/python3")
    process.arguments=["-I",launcher,"--native-broker","--approved-sha256",calendarProposalSHA]
    process.currentDirectoryURL=URL(fileURLWithPath:home)
    process.environment=["PATH":"/usr/bin:/bin:/usr/sbin:/sbin"]
    #if CALENDAR_EFFECT_FIXTURE
    if fixture,let value=ProcessInfo.processInfo.environment["ARL_FIXTURE_CRASH_AFTER_CONSUME"]{process.environment?["ARL_FIXTURE_CRASH_AFTER_CONSUME"]=value}
    #endif
    let input=Pipe(),output=Pipe();process.standardInput=input;process.standardOutput=output;process.standardError=FileHandle.nullDevice
    do{try process.run()}catch{emit(["status":"native_host_unavailable"])}
    // EventKit's synchronous save is not cooperatively cancelable. Bound this
    // owned invocation even if that call blocks; durable consumption remains
    // uncertain. Process stop is never represented as an event undo.
    let watchdog=DispatchSource.makeTimerSource(queue:DispatchQueue.global())
    watchdog.schedule(deadline:.now()+30)
    watchdog.setEventHandler {stopOwned(process);emit(["status":"outcome_unknown"])}
    watchdog.resume()
    defer { watchdog.cancel() }
    // Only this owned child has the anonymous output pipe. No public native
    // effect socket, arbitrary stdin entry or helper-path dispatch remains.
    let deadline=Date().addingTimeInterval(30);var pending=Data();var effectRequested=false
    while Date()<deadline {
        var poller=pollfd(fd:output.fileHandleForReading.fileDescriptor,events:Int16(POLLIN),revents:0)
        let available=poll(&poller,1,100)
        if available<0{break};if available==0{continue}
        var bytes=[UInt8](repeating:0,count:4096);let count=read(poller.fd,&bytes,bytes.count)
        if count<=0{break};pending.append(contentsOf:bytes.prefix(count))
        if pending.count>16384{break}
        while let newline=pending.firstIndex(of:10) {
            let line=Data(pending[..<newline]);pending.removeSubrange(...newline)
            guard let object=(try? JSONSerialization.jsonObject(with:line)) as? [String:Any] else{stopOwned(process);emit(["status":"native_host_protocol_error"])}
            if Set(object.keys)==Set(["native_effect"]),let request=object["native_effect"] as? [String:Any] {
                guard !effectRequested else{stopOwned(process);emit(["status":"operation_consumed"])};effectRequested=true
                let result=nativeSealedEffect(request,home:home)
                guard let reply=try? JSONSerialization.data(withJSONObject:result,options:.sortedKeys) else{break}
                input.fileHandleForWriting.write(reply);input.fileHandleForWriting.write(Data([10]))
            } else if Set(object.keys)==Set(["broker_receipt"]),let receipt=object["broker_receipt"] as? [String:Any] {
                input.fileHandleForWriting.closeFile();stopOwned(process)
                // Result JSON comes only from the verified host; bounded runtime
                // receipt is separate from native save/no-sync acknowledgement.
                emit(["status":"host_completed","receipt":receipt])
            } else {stopOwned(process);emit(["status":"native_host_protocol_error"])}
        }
    }
    stopOwned(process)
    emit(["status":"outcome_unknown"])
}
