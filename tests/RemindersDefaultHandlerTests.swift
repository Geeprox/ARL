import Foundation
import ARLRemindersCore

final class DefaultRepository:ReminderRepository {
    let fixture=FixtureRepository()
    var defaultID:String?
    func defaultListID()throws->String? {defaultID}
    func sources(ids:Set<String>)throws->[ReminderSource] {try fixture.sources(ids:ids)}
    func lists(ids:Set<String>)throws->[ReminderList] {try fixture.lists(ids:ids)}
    func createList(title:String,sourceID:String,beforeCommit:()throws->Void)throws->ReminderList {try fixture.createList(title:title,sourceID:sourceID,beforeCommit:beforeCommit)}
    func query(listID:String,includeCompleted:Bool,dueWindow:DueWindow?,checkRead:()throws->Void)throws->[ReminderSnapshot] {try fixture.query(listID:listID,includeCompleted:includeCompleted,dueWindow:dueWindow,checkRead:checkRead)}
    func get(id:String,listID:String)throws->ReminderSnapshot {try fixture.get(id:id,listID:listID)}
    func create(listID:String,title:String,patch:Patch,beforeCommit:()throws->Void)throws->ReminderSnapshot {try fixture.create(listID:listID,title:title,patch:patch,beforeCommit:beforeCommit)}
    func update(id:String,listID:String,revision:String,patch:Patch?,completed:Bool?,beforeCommit:()throws->Void)throws->ReminderSnapshot {try fixture.update(id:id,listID:listID,revision:revision,patch:patch,completed:completed,beforeCommit:beforeCommit)}
}
@main struct RemindersDefaultHandlerTests {
 static func main()throws {
    let home=URL(fileURLWithPath:CommandLine.arguments[1]);try FileManager.default.createDirectory(at:home,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
    let repo=DefaultRepository();var permission="full_access";var count=0
    func expect(_ ok:Bool,_ label:String){precondition(ok,label);count+=1}
    repo.fixture.sourceItems=[.init(id:"a",title:"iCloud",type:2),.init(id:"b",title:"iCloud",type:2),.init(id:"internet",title:"Holiday account",type:2)]
    repo.fixture.listItems=[.init(id:"la",title:"Same",sourceID:"a",writable:true),.init(id:"lb",title:"Same",sourceID:"b",writable:true),.init(id:"ro",title:"Read only",sourceID:"b",writable:false,subscribed:true)]
    for (id,list) in [("ra","la"),("rb","lb"),("rr","ro")] {var item=ReminderSnapshot(id:id,listID:list,title:"Synthetic");try item.revise();repo.fixture.reminderItems.append(item)}
    let identity=RemindersFirstIdentity(helper_bundle_id:"local.arl.remindersbridge",executable_sha256:String(repeating:"a",count:64),designated_requirement_sha256:String(repeating:"b",count:64))
    let handler=RemindersProductHandler(home:home.path,identity:identity,policy:String(repeating:"c",count:64),repository:repo,catalog:{.init(sources:repo.fixture.sourceItems.map{.init(id:$0.id,title:$0.title,type:$0.type)},lists:repo.fixture.listItems.map{.init(id:$0.id,title:$0.title,source_id:$0.source_id,writable:$0.writable)})},permission:{permission})
    func call(_ f:RemindersProductFrame)->RemindersProductReply {handler.handle(f,check:{})}
    func frame(_ op:String,_ args:[String:Any],task:String=UUID().uuidString.lowercased())throws->RemindersProductFrame {var args=args;let write=RemindersProductRequest.mutations.contains(op);if write {args["operation_id"]=try RemindersProductRequest.operationID(task)};return .init(write ? .submit:.read,taskID:write ? task:nil,requestJSON:String(decoding:try JSONSerialization.data(withJSONObject:["tool":"apple.reminders."+op+".v3","args":args],options:[.sortedKeys]),as:UTF8.self))}
    let metadata=call(.init(.catalog))
    expect(metadata.code=="ok" && metadata.default_target==nil,"no name-based iCloud guess")
    expect(metadata.catalog?.sources.first(where:{$0.id=="internet"})?.reminder_list_count==0,"zero reminder account marked")
    expect(metadata.catalog?.lists.first(where:{$0.id=="ro"})?.subscribed==true,"subscription metadata")
    expect(call(try frame("query",[:])).result?.reminders?.count==3,"global read needs no default")
    expect(call(try frame("query",[:])).read_scope=="all_authorized_lists","explicit global scope")
    expect(call(try frame("lists",[:])).result?.lists?.count==3,"lists not narrowed")
    expect(call(try frame("list.lookup",["selector":["title":"Same"]])).code=="ambiguous_list","duplicate names not guessed")
    expect(call(try frame("list.lookup",["selector":["title":"Same","source_id":"b"]])).result?.list?.id=="lb","source disambiguation exact")
    let saves=repo.fixture.saveAttempts
    expect(call(try frame("create",["title":"No guess"])).code=="default_list_required" && repo.fixture.saveAttempts==saves,"no default no save")
    expect(call(.init(.select,sourceID:"a")).code=="default_list_required","source alone not a default list")
    expect(call(.init(.select,sourceID:"a",listID:"la")).code=="target_selected","set default A")
    expect(call(.init(.catalog)).default_target?.list?.id=="la","default exposed separately")
    expect(call(try frame("query",[:])).result?.reminders?.count==3,"default never narrows query")
    expect(call(try frame("query",["list_id":"lb"])).result?.reminders?.first?.id=="rb","explicit B read while default A")
    expect(call(try frame("get",["list_id":"ro","reminder_id":"rr"])).result?.reminder?.id=="rr","read-only readable")
    expect(call(try frame("create",["list_id":"ro","title":"No"])).code=="list_not_writable" && repo.fixture.saveAttempts==saves,"read-only not writable")
    let explicit=call(try frame("create",["list_id":"lb","title":"Explicit B"]))
    expect(explicit.code=="saved_local" && explicit.result?.reminder?.list_id=="lb","explicit B write while default A")
    expect(explicit.task?.target.list?.id=="lb","task freezes explicit B")
    expect(call(.init(.selection)).target?.list?.id=="la","explicit B did not change default A")
    let implicitFrame=try frame("create",["title":"Implicit A"])
    let implicit=call(implicitFrame)
    expect(implicit.code=="saved_local" && implicit.result?.reminder?.list_id=="la","implicit create uses default A")
    expect(implicit.task?.target.list?.id=="la","implicit task records resolved target")
    let original=try JSONSerialization.jsonObject(with:Data(implicit.task!.request_json.utf8)) as! [String:Any]
    expect((original["args"] as! [String:Any])["list_id"]==nil,"original intent digest unchanged")
    expect(call(.init(.select,sourceID:"b",listID:"lb")).code=="target_selected","change default B")
    let beforeReplay=repo.fixture.saveAttempts;permission="denied"
    expect(call(implicitFrame).result_json==implicit.result_json && repo.fixture.saveAttempts==beforeReplay,"replay original A receipt before permission/default")
    expect(call(try frame("query",[:])).code=="needs_permission","default never grants permission")
    permission="full_access"
    expect(call(try frame("create",["list_id":"la","title":"Explicit A"])).result?.reminder?.list_id=="la","changing default does not revoke A")
    repo.fixture.listItems[1].writable=false
    expect(call(.init(.catalog)).code=="ok" && call(.init(.catalog)).default_target==nil,"stale default does not hide catalog")
    expect(call(try frame("query",["list_id":"la"])).code=="ok","stale default does not block explicit reads")
    expect(call(try frame("create",["list_id":"la","title":"Still A"])).code=="saved_local","stale default does not block explicit writes")
    expect(call(try frame("create",["title":"No reroute"])).code=="list_not_writable","stale default never reroutes")
    expect(call(try frame("query",["list_id":"unknown"])).code=="target_not_authorized","unknown ID denied")
    let targetURL=home.appendingPathComponent("product-v1/target.json");try FileManager.default.removeItem(at:targetURL)
    repo.fixture.listItems[1].writable=true;repo.defaultID="lb"
    let native=call(.init(.catalog))
    expect(native.default_target==nil && native.catalog?.system_default_list_id=="lb","system default is metadata, not proof of main iCloud")
    expect(call(try frame("create",["title":"Native B"])).code=="default_list_required","do not adopt possibly Google system default")
    expect(!FileManager.default.fileExists(atPath:targetURL.path),"metadata/default fallback does not persist preference")
    repo.fixture.sourceItems[1].is_delegate=true
    expect(call(try frame("create",["title":"Delegated no guess"])).code=="default_list_required","delegated auto default requires choice")
    expect(call(try frame("query",[:])).code=="ok","delegated read remains OS authorized")
    print("PASS \(count) default handler checks; Apple=0 permissions=0 real_writes=0")
 }
}
