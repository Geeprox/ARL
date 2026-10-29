import Foundation

@MainActor final class OwnerDeleteUnusedCalendar: CalendarBusinessBackend {
    var access: CalendarBusinessAccess { .full_access }
    func calendars() throws -> [CalendarBusinessCalendar] { preconditionFailure("calendar must not be touched") }
    func query(_ value: CalendarBusinessQuery) throws -> (events: [CalendarBusinessEvent], truncated: Bool) { preconditionFailure("calendar must not be touched") }
    func get(_ target: CalendarBusinessTarget) throws -> CalendarBusinessEvent { preconditionFailure("calendar must not be touched") }
    func prepare(_ request: CalendarBusinessRequest) throws -> CalendarBusinessClaim { preconditionFailure("calendar must not be touched") }
    func commit(_ claim: CalendarBusinessClaim) throws -> CalendarBusinessOperation { preconditionFailure("calendar must not be touched") }
}

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

@main enum AppleOwnerDefaultFlowTests {
 @MainActor static func main()async throws {
  let home=URL(fileURLWithPath:CommandLine.arguments[1]);try FileManager.default.createDirectory(at:home,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
  let repo=DefaultRepository();var allowed=true;var checks=0;var ensureCalls=0;var confirmations=0
  func expect(_ ok:Bool,_ label:String){precondition(ok,label);checks+=1}
  repo.fixture.sourceItems=[.init(id:"a",title:"Cloud A",type:2),.init(id:"b",title:"Cloud B",type:2)]
  repo.fixture.listItems=[.init(id:"la",title:"A",sourceID:"a",writable:true),.init(id:"lb",title:"B",sourceID:"b",writable:true),.init(id:"ro",title:"Read only",sourceID:"b",writable:false,subscribed:true)]
  for (id,list) in [("a0","la"),("b0","lb"),("r0","ro")] {var row=ReminderSnapshot(id:id,listID:list,title:"Synthetic");try row.revise();repo.fixture.reminderItems.append(row)}
  let identity=RemindersFirstIdentity(helper_bundle_id:"local.arl.remindersbridge",executable_sha256:String(repeating:"a",count:64),designated_requirement_sha256:String(repeating:"b",count:64))
  let helper=RemindersProductHandler(home:home.path,identity:identity,policy:String(repeating:"c",count:64),repository:repo,catalog:{.init(sources:repo.fixture.sourceItems.map{.init(id:$0.id,title:$0.title,type:$0.type)},lists:repo.fixture.listItems.map{.init(id:$0.id,title:$0.title,source_id:$0.source_id,writable:$0.writable)})},permission:{allowed ? "full_access":"denied"})
  let controller=RemindersProductController(port:.init(begin:{_ in true},end:{_ in},ensureService:{ensureCalls+=1},send:{helper.handle($0,check:{})},record:{_,_,_,_ in}))
  let calendar=CalendarBusinessHandler(backend:OwnerDeleteUnusedCalendar(),port:.init(verify:{},lookup:{_ in nil},claim:{_ in preconditionFailure()},finish:{_ in preconditionFailure()},record:{_,_ in preconditionFailure()}))
  let owner=AppleProductOwnerExecutor(home:home,events:AppleDirectExecutor(),reminders:controller,calendar:calendar,port:.init(begin:{_ in true},end:{_ in},verify:{},notesFolder:{nil},messagesAccount:{nil}),confirmation:{_,_ in confirmations+=1;return false})
  func call(_ tool:String,_ args:[String:Any])async throws->[String:Any] {let raw=try JSONSerialization.data(withJSONObject:args,options:[.sortedKeys]);return try OwnerReadJSON.object(await owner.execute(tool:tool,argumentsJSON:raw,callID:UUID()),limit:262144)}
  func payload(_ result:[String:Any])->[String:Any] {result["result"] as! [String:Any]}
  func receipt(_ result:[String:Any])throws->[String:Any] {try JSONSerialization.jsonObject(with:Data((payload(result)["result_json"] as! String).utf8)) as! [String:Any]}
  let descriptors=AppleProductCapability.descriptors
  let q=descriptors.first{$0["name"] as? String=="mio_reminders_query"}!["inputSchema"] as! [String:Any]
  let cr=descriptors.first{$0["name"] as? String=="mio_reminders_create_item"}!["inputSchema"] as! [String:Any]
  expect(q["required"] as! [String]==[],"public query list optional")
  expect(cr["required"] as! [String]==["task_id","title"],"public create list optional")
  let all=try await call("mio_reminders_query",[:])
  expect((try receipt(all)["reminders"] as! [[String:Any]]).count==3,"public owner to actual helper queries all without default")
  expect(try AppleProductCapability.admit(all,tool:"mio_reminders_query",arguments:[:]),"real public query result admitted")
  _=try await controller.execute(.init(.select,sourceID:"a",listID:"la"))
  expect(controller.defaultTarget?.list?.id=="la","controller preference A")
  let exactArgs:[String:Any]=["list_id":"lb"]
  let exact=try await call("mio_reminders_query",exactArgs)
  expect((try receipt(exact)["reminders"] as! [[String:Any]]).first?["list_id"] as? String=="lb","public explicit read B")
  expect(controller.defaultTarget?.list?.id=="la","Mio read B does not mutate default A")
  let explicitArgs:[String:Any]=["task_id":UUID().uuidString.lowercased(),"list_id":"lb","title":"Synthetic explicit"]
  let explicit=try await call("mio_reminders_create_item",explicitArgs)
  expect((try receipt(explicit)["reminder"] as! [String:Any])["list_id"] as? String=="lb","public explicit create B")
  expect(try AppleProductCapability.admit(explicit,tool:"mio_reminders_create_item",arguments:explicitArgs),"exact explicit receipt admitted")
  expect(controller.defaultTarget?.list?.id=="la","Mio create B does not mutate default A")
  let implicitArgs:[String:Any]=["task_id":UUID().uuidString.lowercased(),"title":"Synthetic implicit"]
  let implicit=try await call("mio_reminders_create_item",implicitArgs)
  expect((try receipt(implicit)["reminder"] as! [String:Any])["list_id"] as? String=="la","public implicit create uses A")
  expect(try AppleProductCapability.admit(implicit,tool:"mio_reminders_create_item",arguments:implicitArgs),"omitted-list original intent receipt admitted")
  _=try await controller.execute(.init(.select,sourceID:"b",listID:"lb"));allowed=false
  let before=repo.fixture.saveAttempts;let repeated=try await call("mio_reminders_create_item",implicitArgs)
  expect(payload(repeated)["result_json"] as? String==payload(implicit)["result_json"] as? String && repo.fixture.saveAttempts==before,"original A receipt replay with default B and permission denied")
  expect(controller.defaultTarget?.list?.id=="lb","replay A leaves default B")
  allowed=true
  let readOnly=try await call("mio_reminders_query",["list_id":"ro"])
  expect((try receipt(readOnly)["reminders"] as! [[String:Any]]).count==1,"public read-only target readable")
  expect(confirmations==0,"no native confirmation or Apple event for fixture")
  expect(ensureCalls>0,"actual controller service boundary exercised")
  print("PASS \(checks) public Owner/Controller/Handler/default checks; Apple=0 permissions=0 real_writes=0")
 }
}
