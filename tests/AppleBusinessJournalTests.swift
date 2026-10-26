import Foundation
import Darwin
import ARLCredentialOnboarding
@main enum AppleBusinessJournalTests {
    static func main()throws {
        guard CommandLine.arguments.count==2 else{fatalError("isolated root required")}
        let root=URL(fileURLWithPath:CommandLine.arguments[1]);precondition(!FileManager.default.fileExists(atPath:root.path))
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        let directory=root.appendingPathComponent("journal.noindex")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        let recent=directory.appendingPathComponent("business-recent.jsonl.noindex"),expired=directory.appendingPathComponent("business-expired.jsonl.noindex")
        for (file,days) in [(recent,7.5),(expired,9.0)] {try Data("synthetic retention\n".utf8).write(to:file);try FileManager.default.setAttributes([.posixPermissions:0o600,.modificationDate:Date().addingTimeInterval(-days*86400)],ofItemAtPath:file.path)}
        let id=UUID(),call=UUID(),title=String(repeating:"完整原始提醒 🧪 ",count:20)
        let input=try JSONSerialization.data(withJSONObject:["task_id":id.uuidString.lowercased(),"title":title],options:[.prettyPrinted,.sortedKeys])
        let output=try JSONSerialization.data(withJSONObject:["task_id":id.uuidString.lowercased(),"state":"outcome_unknown","diagnostic":String(repeating:"synthetic full result ",count:2000)])
        let journal=AppleBusinessJournal(directory:directory)
        try journal.record(tool:"mio_reminders_create",callID:call,argumentsJSON:input,responseJSON:nil)
        try journal.record(tool:"mio_reminders_create",callID:call,argumentsJSON:input,responseJSON:output)
        precondition(FileManager.default.fileExists(atPath:recent.path) && !FileManager.default.fileExists(atPath:expired.path),"retain at least seven days; expire only after eight")
        let files=try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil).filter{$0.lastPathComponent.hasPrefix("business-") && $0 != recent}
        precondition(files.count==1)
        let rows=try String(contentsOf:files[0],encoding:.utf8).split(separator:"\n").map{try JSONSerialization.jsonObject(with:Data($0.utf8)) as! [String:Any]}
        precondition(rows.count==2 && rows.allSatisfy{$0["arguments_text"] as? String==String(decoding:input,as:UTF8.self) && $0["request_id"] as? String==id.uuidString && $0["call_id"] as? String==call.uuidString})
        precondition(rows[1]["response_text"] as? String==String(decoding:output,as:UTF8.self),"full result is never truncated")
        var info=stat();precondition(stat(files[0].path,&info)==0 && info.st_mode&0o777==0o600)
        let bad=try JSONSerialization.data(withJSONObject:["task_id":id.uuidString,"title":title,"authorization":"synthetic forbidden field"])
        do{try journal.record(tool:"mio_reminders_create",callID:call,argumentsJSON:bad,responseJSON:nil);fatalError("unexpected credential field admitted")}catch is MusicBusinessLogFailure{}
        let unchanged=try String(contentsOf:files[0],encoding:.utf8).split(separator:"\n").count;precondition(unchanged==2)
        for action in ["task_scope","task_submit","task_cancel"] {
            let frame:[String:Any]=["schema_version":2,"capability_id":"reminders.task.create.v1","action":action,"request_id":UUID().uuidString.lowercased(),"task_id":id.uuidString.lowercased(),"expected_digest":String(repeating:"a",count:64)]
            let original=try JSONSerialization.data(withJSONObject:frame,options:[.prettyPrinted,.sortedKeys])
            try journal.record(tool:"arl_ui_reminders_"+action,callID:call,argumentsJSON:original,responseJSON:nil)
            try journal.record(tool:"arl_ui_reminders_"+action,callID:call,argumentsJSON:original,responseJSON:output)
            let retained=try String(contentsOf:files[0],encoding:.utf8).split(separator:"\n").suffix(2).map{try JSONSerialization.jsonObject(with:Data($0.utf8)) as! [String:Any]}
            precondition(retained.count==2 && retained.allSatisfy{$0["arguments_text"] as? String==String(decoding:original,as:UTF8.self)})
            precondition(retained.last?["response_text"] as? String==String(decoding:output,as:UTF8.self),"local UI original frame and full result retained")
        }
        let link=root.appendingPathComponent("symlink.noindex");try FileManager.default.createSymbolicLink(at:link,withDestinationURL:directory)
        do{try AppleBusinessJournal(directory:link).record(tool:"mio_reminders_create",callID:call,argumentsJSON:input,responseJSON:nil);fatalError("symlink admitted")}catch is MusicBusinessLogFailure{}
        print("apple_business_journal_pass exact_input_result=true owner_only=true retention_days=8 secrets_rejected=true local_UI_scope_submit_cancel_logged=true real_business_content=0")
    }
}
