import Foundation
import CryptoKit
import Darwin

// Compiled seal generated from the proposal and isolated launcher, not stdin/env.
func remindersAccountHome() -> String {
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
func sealedReview(_ home:String,_ args:[String:Any],allowConsumed:Bool=false)->String? {
    var dir=stat()
    guard lstat(home,&dir)==0,dir.st_uid==getuid(),dir.st_mode&S_IFMT==S_IFDIR,dir.st_mode&0o077==0,
          nativePathHasNoSymlink(home) else{return "unsafe_review_file"}
    guard let raw=privateNativeFile(home+"/review.json",limit:16384),
          let review=(try? JSONSerialization.jsonObject(with:raw)) as? [String:Any],Set(review.keys)==Set(["args","expires_at_ms"]),
          let actual=args as? [String:String],actual==remindersSealedArgs,
          let approved=review["args"] as? [String:String],approved==remindersSealedArgs,
          let expires=review["expires_at_ms"] as? NSNumber,CFGetTypeID(expires) != CFBooleanGetTypeID() else{return "review_not_authorized"}
    let expiry=expires.doubleValue;let now=Date().timeIntervalSince1970*1000
    guard expiry.isFinite,expiry.rounded()==expiry,expiry>now,expiry<=now+600000 else{return "review_expired"}
    // A one-use marker belongs to this exact one-event package. Existence (even
    // uncertain or malformed) refuses replay; no unlink/reset path is provided.
    var s=stat()
    if !allowConsumed && lstat((home+"/native-consumed.json"),&s)==0{return "operation_consumed"}
    return nil
}
func consumeReminderOperation(_ home:String)->String? {
    let fd=open(home+"/native-consumed.json",O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0o600)
    guard fd>=0 else{return errno==EEXIST ? "operation_consumed":"unsafe_review_file"}
    let record=Data(("{\"operation_id\":\""+remindersSealedArgs["operation_id"]!+"\",\"state\":\"consumed_or_uncertain\"}\n").utf8)
    let size=record.withUnsafeBytes{write(fd,$0.baseAddress,record.count)}
    let durable=size==record.count && fsync(fd)==0;close(fd)
    let dir=open(home,O_RDONLY|O_DIRECTORY);let dirDurable=dir>=0 && fsync(dir)==0
    if dir>=0{close(dir)}
    return durable && dirDurable ? nil:"outcome_unknown"
}
func nativeSealedEffect(_ request:[String:Any],home:String,commit:()->Bool)->[String:Any] {
    guard Set(request.keys)==Set(["tool","args"]),request["tool"] as? String=="apple.reminders.create.v1",
          let args=request["args"] as? [String:Any],validReminderArgs(args) else{return ["status":"review_not_authorized"]}
    // Identity is the fixed native broker's owned, hash-sealed child/pipe, not
    // caller-declared appId or arbitrary schema-valid stdin.
    if let error=sealedReview(home,args){return ["status":error]}
    #if REMINDERS_EFFECT_FIXTURE
    let mode=ProcessInfo.processInfo.environment["ARL_REMINDER_FIXTURE_MODE"] ?? "saved_local"
    if mode=="needs_permission"{return ["status":"needs_permission"]}
    if mode=="needs_unlock"{return ["status":"needs_unlock"]}
    if mode=="lock_state_unknown"{return ["status":"lock_state_unknown"]}
    #else
    guard reminderAuthorization()=="full_access" else{return ["status":"needs_permission"]}
    let unlocked=reminderUnlockState()
    guard unlocked=="unlocked" else{return ["status":unlocked=="locked" ? "needs_unlock":"lock_state_unknown"]}
    #endif
    // Durable admission is consumed before list metadata/UI/store access. Crash,
    // timeout, cancel or uncertain save can never trigger an automatic replay.
    if let error=consumeReminderOperation(home){return ["status":error]}
    #if REMINDERS_EFFECT_FIXTURE
    let store:ReminderStore=FixtureReminderStore(home:home,mode:mode)
    #else
    let store:ReminderStore=EventKitReminderStore()
    #endif
    guard let target=store.defaultTarget() else{return ["status":"no_default_list"]}
    guard store.confirm(target,title:remindersSealedArgs["title"]!) else{return ["status":"user_cancelled"]}
    // Confirmed target stays exact. Default-list drift is refusal, never fallback.
    guard let current=store.defaultTarget(),current.identifier==target.identifier else{return ["status":"target_changed"]}
    // After native user review, the owned host rechecks job cancellation before
    // allowing the synchronous effect. Missing/malformed commit always refuses.
    guard commit() else{return ["status":"user_cancelled"]}
    if let error=sealedReview(home,args,allowConsumed:true){return ["status":error]}
    #if !REMINDERS_EFFECT_FIXTURE
    guard reminderAuthorization()=="full_access" else{return ["status":"needs_permission"]}
    let nowUnlocked=reminderUnlockState()
    guard nowUnlocked=="unlocked" else{return ["status":nowUnlocked=="locked" ? "needs_unlock":"lock_state_unknown"]}
    #endif
    let result=store.save(target,title:remindersSealedArgs["title"]!)
    guard result=="saved_local" else{return ["status":result]}
    return ["status":"saved_local","operation_id":remindersSealedArgs["operation_id"]!,
            "target_identifier_sha256":digest(Data(target.identifier.utf8))]
}
func stopOwned(_ process:Process) {
    if process.isRunning{process.terminate()}
    let deadline=Date().addingTimeInterval(1)
    while process.isRunning && Date()<deadline{Thread.sleep(forTimeInterval:0.01)}
    if process.isRunning{kill(process.processIdentifier,SIGKILL)}
}
func runNativeBroker(home:String,launcher:String,launcherSHA:String,fixture:Bool=false)->Never {
    guard privateNativeFile(launcher).map({digest($0)==launcherSHA})==true else{emit(["status":"launcher_changed"])}
    if let error=sealedReview(home,remindersSealedArgs){emit(["status":error])}
    let process=Process();process.executableURL=URL(fileURLWithPath:"/usr/bin/python3")
    process.arguments=["-I",launcher,"--native-broker","--approved-sha256",remindersProposalSHA]
    process.currentDirectoryURL=URL(fileURLWithPath:home)
    process.environment=["PATH":"/usr/bin:/bin:/usr/sbin:/sbin"]
    #if REMINDERS_EFFECT_FIXTURE
    if fixture,let value=ProcessInfo.processInfo.environment["ARL_REMINDER_FIXTURE_MODE"]{process.environment?["ARL_REMINDER_FIXTURE_MODE"]=value}
    #endif
    let input=Pipe(),output=Pipe();process.standardInput=input;process.standardOutput=output;process.standardError=FileHandle.nullDevice
    do{try process.run()}catch{emit(["status":"native_host_unavailable"])}
    // EventKit's synchronous reminder save is not cooperatively cancelable. Bound this
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
                let result=nativeSealedEffect(request,home:home,commit:{
                    guard pending.isEmpty else{return false}
                    let acknowledgement:[String:Any]=["status":"awaiting_commit","operation_id":remindersSealedArgs["operation_id"]!]
                    guard let encoded=try? JSONSerialization.data(withJSONObject:acknowledgement,options:.sortedKeys) else{return false}
                    input.fileHandleForWriting.write(encoded);input.fileHandleForWriting.write(Data([10]))
                    return readNativeCommit(output.fileHandleForReading.fileDescriptor)
                })
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

func readNativeCommit(_ fd:Int32)->Bool {
    var raw=Data();let deadline=Date().addingTimeInterval(3)
    while Date()<deadline {
        var event=pollfd(fd:fd,events:Int16(POLLIN),revents:0)
        guard poll(&event,1,100)>=0 else{return false}
        if event.revents==0{continue}
        var bytes=[UInt8](repeating:0,count:4097);let count=read(fd,&bytes,bytes.count)
        guard count>0 else{return false};raw.append(contentsOf:bytes.prefix(count))
        guard raw.count<=4096 else{return false}
        if raw.contains(10) {
            guard raw.last==10,raw.filter({$0==10}).count==1,
                  let object=(try? JSONSerialization.jsonObject(with:raw)) as? [String:Any],
                  Set(object.keys)==Set(["native_commit","operation_id"]),
                  object["operation_id"] as? String==remindersSealedArgs["operation_id"],
                  let allowed=object["native_commit"] as? NSNumber,
                  CFGetTypeID(allowed)==CFBooleanGetTypeID() else{return false}
            return allowed.boolValue
        }
    }
    return false
}
