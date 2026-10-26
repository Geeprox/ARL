import Foundation
import Darwin

private final class CleanupGate: @unchecked Sendable {
    static let shared=CleanupGate()
    let reached=DispatchSemaphore(value:0),resume=DispatchSemaphore(value:0)
    var target:String?
}
// Select the same legal interleaving as the independent review; the syscall is real.
func unlinkat(_ fd:Int32,_ name:String,_ flag:Int32)->Int32 {
    let gate=CleanupGate.shared
    if gate.target==name {gate.reached.signal();precondition(gate.resume.wait(timeout:.now()+15) == .success)}
    return name.withCString {Darwin.unlinkat(fd,$0,flag)}
}
private final class FsyncGate: @unchecked Sendable {
    static let shared=FsyncGate()
    private let lock=NSLock();private var armed=false
    func arm(){lock.withLock{armed=true}}
    func consume()->Bool {lock.withLock{if !armed{return false};armed=false;return true}}
}
func fsync(_ fd:Int32)->Int32 {
    if FsyncGate.shared.consume(){errno=EIO;return -1}
    return Darwin.fsync(fd)
}
private final class OutcomeBox: @unchecked Sendable {
    private let lock=NSLock();private var stored:Error?
    func set(_ error:Error){lock.withLock{stored=error}}
    var error:Error? {lock.withLock{stored}}
}
@main enum MusicBusinessJournalBoundaryTests {
    static func segments(_ root:URL)throws->[URL] {
        try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil).filter {
            $0.lastPathComponent.hasPrefix("business-") && $0.lastPathComponent.hasSuffix(".jsonl.noindex")
        }
    }
    static func rows(_ root:URL)throws->([[String:Any]],Int) {
        var result:[[String:Any]]=[],invalid=0
        for file in try segments(root) {
            for line in try Data(contentsOf:file).split(separator:10) {
                if let row=try? JSONSerialization.jsonObject(with:Data(line)) as? [String:Any] {result.append(row)}
                else {invalid += 1}
            }
        }
        return (result,invalid)
    }
    static func emit(_ value:[String:Any])throws {
        print(String(decoding:try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]),as:UTF8.self))
    }
    static func main()throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let partialRoot=root.appendingPathComponent("partial-write.noindex")
        let journal=MusicBusinessJournal(directory:partialRoot,minimumFreeBytes:0)
        try journal.append(["event":"initial"],requestID:nil,callID:nil)
        let segment=try segments(partialRoot)[0]
        var meta=stat();precondition(lstat(segment.path,&meta)==0)
        var saved=rlimit();precondition(getrlimit(RLIMIT_FSIZE,&saved)==0)
        var limited=saved;limited.rlim_cur=rlim_t(meta.st_size+64)
        signal(SIGXFSZ,SIG_IGN);precondition(setrlimit(RLIMIT_FSIZE,&limited)==0)
        var failed=false
        do {try journal.append(["event":"disk_error","body":String(repeating:"X",count:20000)],requestID:nil,callID:nil)}
        catch is MusicBusinessLogFailure {failed=true}
        precondition(setrlimit(RLIMIT_FSIZE,&saved)==0)
        try journal.append(["event":"AFTER_WRITE_ERROR"],requestID:nil,callID:nil)
        let (parsed,invalid)=try rows(partialRoot)
        let recovered=parsed.contains{$0["event"] as? String == "AFTER_WRITE_ERROR"}
        let isolated=try segments(partialRoot).contains{$0.lastPathComponent.hasSuffix("-incomplete.jsonl.noindex")}
        let partialCount=try segments(partialRoot).count
        precondition(failed && invalid==1 && recovered && isolated && partialCount==2)
        try emit(["case":"partial_disk_write","PASS":true,"initial_failure_explicit":failed,"incomplete_tail_preserved":invalid==1,"next_successful_row_recoverable":recovered,"damaged_segment_isolated":isolated])

        let syncRoot=root.appendingPathComponent("fsync-failure.noindex"),sync=MusicBusinessJournal(directory:syncRoot,minimumFreeBytes:0)
        try sync.append(["event":"initial"],requestID:nil,callID:nil)
        FsyncGate.shared.arm();var syncFailed=false
        do {try sync.append(["event":"sync_failed"],requestID:nil,callID:nil)}catch is MusicBusinessLogFailure {syncFailed=true}
        try sync.append(["event":"AFTER_FSYNC_ERROR"],requestID:nil,callID:nil)
        let syncRecovered=try rows(syncRoot).0.contains{$0["event"] as? String == "AFTER_FSYNC_ERROR"}
        let syncCount=try segments(syncRoot).count
        precondition(syncFailed && syncRecovered && syncCount==2)
        try emit(["case":"fsync_failure","PASS":true,"initial_failure_explicit":syncFailed,"next_successful_row_recoverable":syncRecovered,"damaged_segment_isolated":true])

        let concurrentRoot=root.appendingPathComponent("concurrent-cleanup.noindex"),clock=Date()
        let first=MusicBusinessJournal(directory:concurrentRoot,minimumFreeBytes:0,now:{clock})
        try first.append(["event":"idle_old_segment"],requestID:nil,callID:nil)
        let active=try segments(concurrentRoot)[0]
        try FileManager.default.setAttributes([.modificationDate:clock.addingTimeInterval(-9*86400)],ofItemAtPath:active.path)
        let gate=CleanupGate.shared;gate.target=active.lastPathComponent
        let other=MusicBusinessJournal(directory:concurrentRoot,minimumFreeBytes:0,now:{clock})
        let cleaning=OutcomeBox(),appending=OutcomeBox(),cleaned=DispatchSemaphore(value:0),appended=DispatchSemaphore(value:0),started=DispatchSemaphore(value:0)
        DispatchQueue.global().async {do {try other.append(["event":"other_instance"],requestID:nil,callID:nil)}catch{cleaning.set(error)};cleaned.signal()}
        precondition(gate.reached.wait(timeout:.now()+10) == .success)
        let lockFile=open(concurrentRoot.appendingPathComponent("business.lock.noindex").path,O_RDWR|O_NOFOLLOW)
        precondition(lockFile>=0)
        let directoryLocked=flock(lockFile,LOCK_EX|LOCK_NB) != 0 && errno==EWOULDBLOCK
        close(lockFile)
        DispatchQueue.global().async {started.signal();do {try first.append(["event":"FRESH_SUCCESSFUL_APPEND"],requestID:nil,callID:nil)}catch{appending.set(error)};appended.signal()}
        precondition(started.wait(timeout:.now()+5) == .success)
        let writerWaited=appended.wait(timeout:.now()+0.1) == .timedOut
        gate.resume.signal()
        precondition(cleaned.wait(timeout:.now()+10) == .success && appended.wait(timeout:.now()+10) == .success)
        gate.target=nil
        let retained=try rows(concurrentRoot).0.contains{$0["event"] as? String == "FRESH_SUCCESSFUL_APPEND"}
        precondition(directoryLocked && writerWaited && cleaning.error==nil && appending.error==nil && retained)
        try emit(["case":"concurrent_expiry_cleanup","PASS":true,"common_OS_directory_lock_held":directoryLocked,"writer_waited_for_cleanup":writerWaited,"fresh_record_retained":retained,"real_network":0,"real_credentials":0])
    }
}
