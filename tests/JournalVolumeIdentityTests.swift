import Foundation
import Darwin

// The production journal depends only on this finite error envelope in this
// fixture; no Apple Events, permission prompt or user data is accessed.
struct AppleDirectFault: Error {let code:String;init(_ code:String){self.code=code}}

@main struct JournalVolumeIdentityTests {
    static func main() throws {
        let home=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
        try FileManager.default.createDirectory(at:home,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        var checks=0
        func expect(_ value:Bool,_ label:String){precondition(value,label);checks+=1}
        let id=UUID(),hash=String(repeating:"a",count:64)
        var journal:AppleDirectJournal?=try AppleDirectJournal(home:home)
        let anchor=home.appendingPathComponent("apple-direct-once-v1.anchor")
        let original=try String(contentsOf:anchor,encoding:.utf8)
        let fields=original.split(separator:"\n")
        expect(fields.count==3 && fields[0]=="v2" && UUID(uuidString:String(fields[1])) != nil,"new journal persists volume UUID")
        try journal!.claim(id:id,digest:hash)
        journal=nil
        journal=try AppleDirectJournal(home:home)
        do{try journal!.claim(id:id,digest:hash);preconditionFailure("claim replay")}catch let e as AppleDirectFault{expect(e.code=="operation_consumed","unknown claim remains consumed after reopen")}
        journal=nil
        let root=home.appendingPathComponent("apple-direct-once-v1")
        var info=stat();expect(lstat(root.path,&info)==0,"fixture directory exists")
        let legacy="v1\n\(info.st_dev)\n\(info.st_ino)\n"
        try Data(legacy.utf8).write(to:anchor)
        journal=try AppleDirectJournal(home:home)
        journal=nil
        expect(try String(contentsOf:anchor,encoding:.utf8)==legacy,"legacy does not auto-migrate")
        try Data("v1\n\(info.st_dev+1)\n\(info.st_ino)\n".utf8).write(to:anchor)
        do{_=try AppleDirectJournal(home:home);preconditionFailure("unreviewed legacy rebind")}catch let e as AppleDirectFault{expect(e.code=="journal_missing_or_replaced","device drift needs explicit review")}
        try Data(original.utf8).write(to:anchor)
        journal=try AppleDirectJournal(home:home);journal=nil
        let foreign="v2\n00112233-4455-6677-8899-aabbccddeeff\n\(info.st_ino)\n"
        try Data(foreign.utf8).write(to:anchor)
        do{_=try AppleDirectJournal(home:home);preconditionFailure("foreign volume")}catch let e as AppleDirectFault{expect(e.code=="journal_missing_or_replaced","wrong volume UUID rejected")}
        try Data(original.utf8).write(to:anchor)
        var message:MessagesDirectJournal?=try MessagesDirectJournal(home:home)
        let m=home.appendingPathComponent("messages-direct-once-v1.anchor")
        expect(try String(contentsOf:m,encoding:.utf8).hasPrefix("v2\n"),"messages uses persistent volume identity")
        message=nil
        let stable=try RemindersNativeIO.directoryBinding([root.path])
        expect(String(decoding:stable,as:UTF8.self)==original,"helper and main app use identical persistent binding")
        let replaced=home.appendingPathComponent("preserved")
        try FileManager.default.moveItem(at:root,to:replaced)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        do{_=try AppleDirectJournal(home:home);preconditionFailure("directory replacement")}catch let e as AppleDirectFault{expect(e.code=="journal_missing_or_replaced","same volume different inode rejected")}
        expect(FileManager.default.fileExists(atPath:replaced.appendingPathComponent("notes_"+id.uuidString.lowercased()).path),"original consumed record preserved")
        _=message
        print("PASS \(checks) persistent-volume journal checks; real Apple reads=0 writes=0")
    }
}
