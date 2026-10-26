import Foundation
import Darwin

// Trusted host fixes this home. No RPC paths, content, key or reset API.
final class ConsumptionJournal {
    private let fd:Int32
    init(home:String)throws {
        guard home.hasPrefix("/") else{throw ReviewFault("unsafe_journal")}
        var path=""
        for part in home.split(separator:"/") {
            guard part != ".",part != ".." else{throw ReviewFault("unsafe_journal")}
            path+="/"+part;var info=stat()
            guard lstat(path,&info)==0,info.st_mode&S_IFMT != S_IFLNK else{throw ReviewFault("unsafe_journal")}
        }
        fd=open(home,O_RDONLY|O_DIRECTORY|O_NOFOLLOW)
        guard fd>=0 else{throw ReviewFault("unsafe_journal")}
        var info=stat()
        guard fstat(fd,&info)==0,info.st_uid==getuid(),info.st_mode&0o077==0 else{close(fd);throw ReviewFault("unsafe_journal")}
    }
    deinit{close(fd)}
    private func claim(_ name:String)throws {
        let file=openat(fd,name,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0o600)
        guard file>=0 else{throw ReviewFault(errno==EEXIST ? "operation_consumed":"journal_uncertain")}
        let record=Data("consumed_or_uncertain\n".utf8)
        let size=record.withUnsafeBytes{write(file,$0.baseAddress,record.count)}
        let durable=size==record.count && fsync(file)==0;close(file)
        guard durable,fsync(fd)==0 else{throw ReviewFault("journal_uncertain")}
    }
    func consume(operationID:String,permitID:String,subject:String,epoch:Int64,budget:Int)throws {
        guard uuid(operationID),uuid(permitID),identifier(subject),epoch>=1,(1...16).contains(budget) else{throw ReviewFault("invalid_policy")}
        try claim("op_"+operationID)
        try claim("permit_"+permitID)
        let prefix="budget_"+digest(Data((subject+":"+String(epoch)).utf8))+"_"
        for slot in 0..<budget {
            do{try claim(prefix+String(slot));return}
            catch let error as ReviewFault where error.code=="operation_consumed"{continue}
        }
        throw ReviewFault("effect_budget_exceeded")
    }
}
