import Foundation
import Darwin
@main enum MusicBusinessAuditTests {
    static func require(_ value: Bool, _ reason: String) { precondition(value, reason) }
    static func main() throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let now=Date(), requestID=UUID(), callID=UUID()
        let journal=MusicBusinessJournal(directory:root,minimumFreeBytes:0,now:{now})
        let long=String(repeating:"complete business body ",count:15000)+"TAIL"
        try journal.append(["event":"fixture","body":["message":long,"code":200,"subCode":10007,
            "data":[["songId":String(repeating:"2",count:32),"code":"PER_ITEM_FAILURE"]],
            "accessToken":"SYNTHETIC-SECRET","nested":["privateKey":"SYNTHETIC-KEY"]]],requestID:requestID,callID:callID)
        let files=try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil).filter { $0.lastPathComponent.hasPrefix("business-") && $0.lastPathComponent.hasSuffix(".jsonl.noindex") }
        require(files.count==1,"one segment")
        let data=try Data(contentsOf:files[0]),text=String(decoding:data,as:UTF8.self)
        require(text.contains("SYNTHETIC-SECRET") && text.contains("SYNTHETIC-KEY"),"synthetic business contents must remain unmodified locally")
        let row=try JSONSerialization.jsonObject(with:data) as! [String:Any]
        require((row["body"] as! [String:Any])["message"] as? String == long,"no truncation")
        require(row["request_id"] as? String == requestID.uuidString,"request correlation")
        var st=stat();require(lstat(files[0].path,&st)==0 && st.st_mode & 0o777 == 0o600,"protected file")
        require(lstat(root.path,&st)==0 && st.st_mode & 0o777 == 0o700,"protected directory")
        let young=root.appendingPathComponent("business-fixture-young.jsonl.noindex"),expired=root.appendingPathComponent("business-fixture-expired.jsonl.noindex")
        for p in [young,expired] {try Data("fixture".utf8).write(to:p);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:p.path)}
        try FileManager.default.setAttributes([.modificationDate:now.addingTimeInterval(-7*86400-60)],ofItemAtPath:young.path)
        try FileManager.default.setAttributes([.modificationDate:now.addingTimeInterval(-9*86400)],ofItemAtPath:expired.path)
        try MusicBusinessJournal(directory:root,minimumFreeBytes:0,now:{now}).append(["event":"cleanup"],requestID:requestID,callID:callID)
        require(FileManager.default.fileExists(atPath:young.path),"at least seven days retained")
        require(!FileManager.default.fileExists(atPath:expired.path),"expired segment cleaned")
        do {try MusicBusinessJournal(directory:root,minimumFreeBytes:UInt64.max,now:{now}).append(["event":"must_fail"],requestID:nil,callID:nil);preconditionFailure("disk quota accepted")}
        catch is MusicBusinessLogFailure {}
        require(FileManager.default.fileExists(atPath:young.path),"capacity pressure cannot evict young logs")
        try FileManager.default.createSymbolicLink(at:root.appendingPathComponent("business-fixture-link.jsonl.noindex"),withDestinationURL:young)
        do {try MusicBusinessJournal(directory:root,minimumFreeBytes:0,now:{now}).append(["event":"refuse_symlink"],requestID:nil,callID:nil);preconditionFailure("symlink accepted")}
        catch is MusicBusinessLogFailure {}
        print("{\"status\":\"PASS\",\"full_body_bytes\":\(data.count),\"retention_days_minimum\":7,\"capacity_failure_explicit\":true,\"real_credentials\":false,\"business_calls\":0}")
    }
}
