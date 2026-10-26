import Foundation
import ARLRemindersCore

final class DefaultRepository: ReminderRepository {
    var queried:[String]=[]
    var created:[String]=[]
    var rows:[String:[ReminderSnapshot]]=[:]
    var afterQuery:(()->Void)?
    let readOnly:Set<String>=["read-only"]
    func sources(ids:Set<String>)throws->[ReminderSource] {ids.sorted().map{.init(id:$0,title:$0,type:2)}}
    func lists(ids:Set<String>)throws->[ReminderList] {ids.sorted().map{.init(id:$0,title:$0,sourceID:"account",writable:!readOnly.contains($0))}}
    func createList(title:String,sourceID:String,beforeCommit:()throws->Void)throws->ReminderList {try beforeCommit();return .init(id:"new-list",title:title,sourceID:sourceID,writable:true)}
    func query(listID:String,includeCompleted:Bool,dueWindow:DueWindow?,checkRead:()throws->Void)throws->[ReminderSnapshot] {
        try checkRead();queried.append(listID);afterQuery?();return rows[listID] ?? []
    }
    func get(id:String,listID:String)throws->ReminderSnapshot {.init(id:id,listID:listID,title:"synthetic")}
    func create(listID:String,title:String,patch:Patch,beforeCommit:()throws->Void)throws->ReminderSnapshot {
        guard !readOnly.contains(listID) else {throw AdapterFault("list_not_writable")}
        try beforeCommit();created.append(listID);return .init(id:UUID().uuidString,listID:listID,title:title)
    }
    func update(id:String,listID:String,revision:String,patch:Patch?,completed:Bool?,beforeCommit:()throws->Void)throws->ReminderSnapshot {try beforeCommit();return .init(id:id,listID:listID,title:"synthetic")}
}

@main struct RemindersDefaultCoreTests {
    static func main()throws {
        let out=URL(fileURLWithPath:CommandLine.arguments[1])
        try FileManager.default.createDirectory(at:out,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        let repo=DefaultRepository()
        let journal=try OperationJournal(directory:out.appendingPathComponent("journal"))
        let adapter=RemindersAdapter(repository:repo,journal:journal)
        var checks:[String]=[]
        func expect(_ condition:Bool,_ label:String)throws {
            guard condition else {throw AdapterFault("TEST_FAILED: "+label)}
            checks.append(label)
        }
        func request(_ op:String,_ args:[String:Any])throws->Request {
            try Request.decode(JSONSerialization.data(withJSONObject:["tool":"apple.reminders."+op+".v3","args":args]))
        }
        func authority(_ request:Request,lists:Set<String>=["a","b","read-only"],defaultList:String?=nil,cancel:@escaping()throws->Void={})throws->HostAuthority {
            .init(owner:"synthetic",requestDigest:try digest(request),key:request.args.operation_id ?? "read",expires:Date().addingTimeInterval(120),allowedTools:[request.tool],listIDs:lists,sourceIDs:["account"],defaultListID:defaultList,checkCancelled:cancel)
        }
        func fault(_ expected:String,_ label:String,_ run:()throws->Void)throws {
            do{try run();throw AdapterFault("TEST_FAILED: expected "+expected+" "+label)}
            catch let value as AdapterFault {try expect(value.code==expected,label+" -> "+expected)}
        }
        let query=try request("query",[:])
        try expect(query.args.list_id==nil,"query permits omitted list")
        try expect(try repo.defaultListID()==nil,"older repository default remains nil")
        repo.rows=["a":[.init(id:"a1",listID:"a",title:"a")],"b":[.init(id:"b1",listID:"b",title:"b")],"read-only":[.init(id:"r1",listID:"read-only",title:"r")]]
        let digestBefore=try digest(query)
        let full=try adapter.execute(query,authority:authority(query,defaultList:"a"))
        try expect(repo.queried==["a","b","read-only"],"unscoped query reads every authorized list including readonly")
        try expect(full.reminders?.count==3,"unscoped query complete cardinality")
        try expect(try digest(query)==digestBefore,"read resolution does not rewrite request digest")
        repo.queried=[]
        let fullWithoutDefault=try adapter.execute(query,authority:authority(query))
        try expect(fullWithoutDefault.reminders==full.reminders,"unscoped query does not require default")
        let explicit=try request("query",["list_id":"b"])
        repo.queried=[]
        let narrow=try adapter.execute(explicit,authority:authority(explicit,defaultList:"a"))
        try expect(repo.queried==["b"],"explicit query takes priority over different default")
        try expect(narrow.reminders?.first?.list_id=="b","explicit query result belongs to requested list")
        let empty=try adapter.execute(query,authority:authority(query,lists:[]))
        try expect(empty.reminders==[],"empty authorized read scope returns empty result")
        try fault("target_not_authorized","explicit query cannot exceed host list grants") {_ = try adapter.execute(explicit,authority:authority(explicit,lists:["a"]))}
        let create=try request("create",["operation_id":UUID().uuidString.lowercased(),"title":"new synthetic"])
        try expect(create.args.list_id==nil,"create permits omitted list")
        let createDigest=try digest(create)
        let created=try adapter.execute(create,authority:authority(create,defaultList:"a"))
        try expect(created.reminder?.list_id=="a","omitted create resolves native default")
        try expect(created.persistence=="saved_local" && created.cloud_sync=="not_checked","default create preserves persistence receipt")
        try expect(try digest(create)==createDigest,"default create does not rewrite canonical request digest")
        try expect(create.args.list_id==nil,"resolved default never injected into wire args")
        let other=try request("create",["operation_id":UUID().uuidString.lowercased(),"list_id":"b","title":"explicit synthetic"])
        let otherResult=try adapter.execute(other,authority:authority(other,defaultList:"a"))
        try expect(otherResult.reminder?.list_id=="b","explicit create ignores different default")
        let explicitBadDefault=try request("create",["operation_id":UUID().uuidString.lowercased(),"list_id":"b","title":"explicit synthetic"])
        let explicitWithBad=try adapter.execute(explicitBadDefault,authority:authority(explicitBadDefault,defaultList:"outside"))
        try expect(explicitWithBad.reminder?.list_id=="b","explicit create ignores stale unauthorized default")
        let missing=try request("create",["operation_id":UUID().uuidString.lowercased(),"title":"no default"])
        let beforeMissing=repo.created.count
        try fault("default_list_required","omitted create with no default") {_ = try adapter.execute(missing,authority:authority(missing))}
        try expect(repo.created.count==beforeMissing,"missing default has zero saves")
        try expect(!FileManager.default.fileExists(atPath:out.appendingPathComponent("journal/"+missing.args.operation_id!+".json").path),"missing default rejected before journal admission")
        try fault("target_not_authorized","default must be within host grant") {_ = try adapter.execute(missing,authority:authority(missing,defaultList:"outside"))}
        try expect(repo.created.count==beforeMissing,"unauthorized default has zero saves")
        let readonly=try request("create",["operation_id":UUID().uuidString.lowercased(),"title":"readonly default"])
        try fault("list_not_writable","readonly default does not permit write") {_ = try adapter.execute(readonly,authority:authority(readonly,defaultList:"read-only"))}
        try expect(repo.created.count==beforeMissing,"readonly default has zero saves")
        repo.rows=["a":(0..<60).map{.init(id:"a\($0)",listID:"a",title:"synthetic")},"b":(0..<60).map{.init(id:"b\($0)",listID:"b",title:"synthetic")}]
        let firstPage=try adapter.execute(query,authority:authority(query,lists:["a","b"],defaultList:"a"))
        try expect(firstPage.next_offset != nil && firstPage.total_count==120,"aggregate query exposes continuation")
        let nextQuery=try request("query",["offset":firstPage.next_offset!,"limit":100])
        let secondPage=try adapter.execute(nextQuery,authority:authority(nextQuery,lists:["a","b"],defaultList:"a"))
        try expect((firstPage.reminders!.map(\.id)+secondPage.reminders!.map(\.id)).count==120 && secondPage.next_offset==nil,"all authorized reminders reachable")
        repo.rows=["a":(0..<100).map{.init(id:"a\($0)",listID:"a",title:"synthetic")}]
        let hundred=try adapter.execute(query,authority:authority(query,lists:["a","b"]))
        try expect(hundred.reminders?.count==100,"aggregate query admits exact100")
        repo.rows=["a":(0..<101).map{.init(id:"a\($0)",listID:"a",title:"synthetic")}]
        let singlePage=try adapter.execute(query,authority:authority(query,lists:["a"]))
        try expect(singlePage.next_offset != nil && singlePage.total_count==101,"single-list query pages rather than rejecting inventory")
        repo.rows=["a":[.init(id:"bad",listID:"outside",title:"synthetic")]]
        try fault("target_not_authorized","repository response cannot escape requested list") {_ = try adapter.execute(query,authority:authority(query,lists:["a"]))}
        repo.rows=[:];repo.queried=[]
        var cancelled=false
        repo.afterQuery={cancelled=true}
        try fault("cancelled","cross-list query stops on cancellation") {_ = try adapter.execute(query,authority:authority(query,lists:["a","b"],cancel:{if cancelled {throw AdapterFault("cancelled")}}))}
        try expect(repo.queried==["a"],"cancelled query never enters next list")
        repo.afterQuery=nil
        let get=try request("get",["list_id":"b","reminder_id":"b1"])
        let got=try adapter.execute(get,authority:authority(get,defaultList:"a"))
        try expect(got.reminder?.list_id=="b","get uses exact supplied list")
        for op in ["get","update","complete","uncomplete","delete"] {
            var args:[String:Any]=["reminder_id":"r"]
            if op != "get" {args["operation_id"]=UUID().uuidString.lowercased();args["expected_revision"]=String(repeating:"a",count:64)}
            if op=="update" {args["patch"]=["title":["action":"set","value":"title"]]}
            try fault("invalid_arguments",op+" still requires list_id") {_ = try request(op,args)}
        }
        try fault("invalid_arguments","caller cannot inject native default authority") {_ = try request("query",["defaultListID":"a"])}
        let oldSource=try JSONDecoder().decode(ReminderSource.self,from:Data(#"{"id":"account","title":"Source","type":2}"#.utf8))
        try expect(oldSource.reminder_list_count==nil && oldSource.is_delegate==nil && oldSource.is_system_default_account==nil,"legacy source JSON remains decodable")
        let oldList=try JSONDecoder().decode(ReminderList.self,from:Data(#"{"id":"a","title":"List","source_id":"account","writable":true}"#.utf8))
        try expect(oldList.calendar_type==nil && oldList.subscribed==nil && oldList.immutable==nil && oldList.is_system_default==nil,"legacy list JSON remains decodable")
        let source=ReminderSource(id:"account",title:"Source",type:2,reminderListCount:3,isDelegate:false,isSystemDefaultAccount:true)
        let list=ReminderList(id:"a",title:"List",sourceID:"account",writable:true,calendarType:2,subscribed:false,immutable:false,isSystemDefault:true)
        try expect(try JSONDecoder().decode(ReminderSource.self,from:JSONEncoder().encode(source))==source,"source public metadata roundtrip")
        try expect(try JSONDecoder().decode(ReminderList.self,from:JSONEncoder().encode(list))==list,"list public metadata roundtrip")
        for suffix in ["\n","\r\n","\r","\u{2028}","\u{2029}","\0"] {
            try fault("invalid_arguments","revision rejects terminal U+"+String(suffix.unicodeScalars.first!.value,radix:16)) {_ = try request("delete",["operation_id":UUID().uuidString.lowercased(),"list_id":"a","reminder_id":"r","expected_revision":String(repeating:"a",count:64)+suffix])}
        }
        let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        try encoder.encode(checks).write(to:out.appendingPathComponent("checks.json"))
        print("RemindersDefaultCoreTests: \(checks.count) PASS; synthetic repository only, Apple effects 0")
    }
}
