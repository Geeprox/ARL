import Foundation
import Darwin

/// Durable at-most-once attempt journal. It is not distributed exactly-once EventKit delivery.
public final class OperationJournal {
    private let directory: URL
    private let lock = NSRecursiveLock()
    private struct Record: Codable {var owner:String;var requestDigest:String;var state:String;var result:Response?;var error:String?}
    public init(directory: URL) throws {
        self.directory=directory
        if !FileManager.default.fileExists(atPath:directory.path) {
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        }
        var info=stat()
        guard lstat(directory.path,&info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {throw AdapterFault("unsafe_journal")}
    }
    public func perform(operationID:String,owner:String,requestDigest:String,effect:() throws -> Response) throws -> Response {
        guard let uuid=UUID(uuidString:operationID), uuid.uuidString.lowercased() == operationID else {throw AdapterFault("invalid_arguments")}
        lock.lock();defer {lock.unlock()}
        let lockPath=directory.appendingPathComponent("journal.lock").path
        let fd=open(lockPath,O_CREAT|O_RDWR|O_NOFOLLOW,0o600)
        guard fd >= 0 else {throw AdapterFault("unsafe_journal")}
        defer {close(fd)}
        var info=stat()
        guard fstat(fd,&info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1,
              flock(fd,LOCK_EX|LOCK_NB) == 0 else {throw AdapterFault("journal_busy")}
        defer {flock(fd,LOCK_UN)}
        let url=directory.appendingPathComponent(operationID+".json")
        let readFD=open(url.path,O_RDONLY|O_NOFOLLOW)
        if readFD >= 0 {
            defer {close(readFD)}
            var st=stat()
            guard fstat(readFD,&st) == 0, st.st_uid == getuid(), st.st_mode & 0o077 == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_nlink == 1, st.st_size <= 65_536 else {throw AdapterFault("unsafe_journal")}
            let data=FileHandle(fileDescriptor:readFD,closeOnDealloc:false).readDataToEndOfFile()
            guard let r=try? JSONDecoder().decode(Record.self,from:data) else {throw AdapterFault("outcome_unknown")}
            guard r.owner == owner, r.requestDigest == requestDigest else {throw AdapterFault("idempotency_conflict")}
            if r.state == "succeeded", let result=r.result {return result}
            if r.state == "rejected", let code=r.error {throw AdapterFault(code)}
            throw AdapterFault("outcome_unknown")
        }
        guard errno == ENOENT else {throw AdapterFault("unsafe_journal")}
        let pending=Record(owner:owner,requestDigest:requestDigest,state:"pending",result:nil,error:nil)
        try write(pending,to:url,exclusive:true)
        do {
            let result=try effect()
            try write(Record(owner:owner,requestDigest:requestDigest,state:"succeeded",result:result,error:nil),to:url,exclusive:false)
            return result
        } catch {
            let code=(error as? AdapterFault)?.code ?? "outcome_unknown"
            // Only these preflight failures guarantee no save attempt. All other failures remain pending.
            let safe=["review_not_authorized","operation_key_mismatch","target_not_authorized","cancelled","needs_permission","list_not_found","source_not_found","list_not_writable","reminder_not_found","revision_conflict","unsupported_recurrence_preserved","unsupported_alarm_preserved","recurrence_requires_start","relative_alarm_requires_timed_start","relative_alarm_requires_replacement","invalid_recurrence","unsupported_source","delete_not_supported","recurring_delete_unsupported"]
            if safe.contains(code) {
                try write(Record(owner:owner,requestDigest:requestDigest,state:"rejected",result:nil,error:code),to:url,exclusive:false)
                throw AdapterFault(code)
            }
            throw AdapterFault("outcome_unknown")
        }
    }
    private func write(_ record:Record,to url:URL,exclusive:Bool) throws {
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        let bytes=try encoder.encode(record)
        let target=exclusive ? url : directory.appendingPathComponent(".journal-"+UUID().uuidString)
        let fd=open(target.path,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0o600)
        guard fd >= 0 else {throw AdapterFault("outcome_unknown")}
        defer {close(fd)}
        try bytes.withUnsafeBytes { ptr in
            var total=0
            while total < ptr.count {
                let n=Darwin.write(fd,ptr.baseAddress!.advanced(by:total),ptr.count-total)
                guard n > 0 else {throw AdapterFault("outcome_unknown")};total += n
            }
        }
        guard fsync(fd) == 0 else {throw AdapterFault("outcome_unknown")}
        if !exclusive {guard rename(target.path,url.path) == 0 else {throw AdapterFault("outcome_unknown")}}
        let dirFD=open(directory.path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW)
        guard dirFD >= 0 else {throw AdapterFault("outcome_unknown")}
        defer {close(dirFD)}
        guard fsync(dirFD) == 0 else {throw AdapterFault("outcome_unknown")}
    }
}
