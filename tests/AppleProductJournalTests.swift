import Foundation
import ARLCredentialOnboarding

@main enum AppleProductJournalTests {
    static func main()throws {
        var count=0
        func expect(_ value:Bool,_ label:String){precondition(value,label);count+=1}
        func rejects(_ body:()throws->Void)->Bool{do{try body();return false}catch{return true}}
        let home=URL(fileURLWithPath:CommandLine.arguments[1])
        try FileManager.default.createDirectory(at:home,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        let journal=AppleBusinessJournal(directory:home.appendingPathComponent("business.noindex"))
        let task=UUID().uuidString.lowercased(),call=UUID()
        let response=Data("{\"state\":\"outcome_unknown\",\"full\":\"synthetic response\"}".utf8)
        let cases:[(String,[String:Any])]=[
            ("mio_reminders_catalog",[:]),("mio_reminders_query",["list_id":"fixture"]),
            ("mio_reminders_get",["list_id":"fixture","reminder_id":"fixture"]),
            ("mio_reminders_create_list",["task_id":task,"source_id":"fixture","title":"Synthetic"]),
            ("mio_reminders_create_item",["task_id":task,"list_id":"fixture","title":"Synthetic","patch":["notes":["action":"set","value":"full synthetic"]]]),
            ("mio_reminders_update_item",["task_id":task,"list_id":"fixture","reminder_id":"fixture","expected_revision":"opaque","patch":[:]]),
            ("mio_reminders_complete_item",["task_id":task,"list_id":"fixture","reminder_id":"fixture","expected_revision":"opaque"]),
            ("mio_reminders_uncomplete_item",["task_id":task,"list_id":"fixture","reminder_id":"fixture","expected_revision":"opaque"]),
            ("mio_reminders_product_operation_status",["task_id":task]),
            ("mio_calendar_calendars",["task_id":task]),("mio_calendar_query",["task_id":task,"query":[:]]),
            ("mio_calendar_get",["task_id":task,"target":[:]]),("mio_calendar_create",["task_id":task,"draft":[:]]),
            ("mio_calendar_update",["task_id":task,"target":[:],"draft":[:]]),("mio_calendar_delete",["task_id":task,"target":[:]]),
            ("mio_calendar_operation_status",["task_id":task])]
        var originals=[String]()
        for (tool,args) in cases {
            let data=try JSONSerialization.data(withJSONObject:args,options:[.sortedKeys])
            originals.append(String(decoding:data,as:UTF8.self))
            try journal.recordProduct(tool:tool,callID:call,argumentsJSON:data,responseJSON:nil)
            try journal.recordProduct(tool:tool,callID:call,argumentsJSON:data,responseJSON:response)
        }
        let ui=try JSONSerialization.data(withJSONObject:["schema_version":3,"capability_id":"reminders.product.v1","request_id":call.uuidString.lowercased(),"action":"selection"])
        try journal.recordProduct(tool:"reminders.product",callID:call,argumentsJSON:ui,responseJSON:response)
        let files=try FileManager.default.contentsOfDirectory(at:home.appendingPathComponent("business.noindex"),includingPropertiesForKeys:nil).filter{$0.lastPathComponent.hasSuffix(".jsonl.noindex")}
        let rows=try files.flatMap{try String(contentsOf:$0,encoding:.utf8).split(separator:"\n").map{try JSONSerialization.jsonObject(with:Data($0.utf8)) as! [String:Any]}}
        expect(rows.count==cases.count*2+1,"all product request/response rows retained")
        expect(rows.filter{$0["response_text"] as? String==String(decoding:response,as:UTF8.self)}.count==cases.count+1,"full response and error bytes retained")
        expect(originals.allSatisfy{original in rows.contains{$0["arguments_text"] as? String==original}},"complete original arguments retained")
        expect(rejects{try journal.record(tool:"mio_calendar_create",callID:call,argumentsJSON:Data("{\"task_id\":\"\(task)\",\"draft\":{}}".utf8),responseJSON:nil)},"legacy whitelist remains closed")
        expect(rejects{try journal.recordProduct(tool:"generic_exec",callID:call,argumentsJSON:Data("{}".utf8),responseJSON:nil)},"no generic journal tool contract")
        expect(rejects{try journal.recordProduct(tool:"mio_calendar_create",callID:call,argumentsJSON:Data("{\"task_id\":\"\(task)\",\"draft\":{},\"command\":\"x\"}".utf8),responseJSON:nil)},"unknown product field rejected")
        expect(rejects{try journal.recordProduct(tool:"reminders.product",callID:UUID(),argumentsJSON:ui,responseJSON:nil)},"UI request bound to call UUID")
        print("PASS "+String(count)+" product business-journal checks for 16 tools; real_business=0")
    }
}
