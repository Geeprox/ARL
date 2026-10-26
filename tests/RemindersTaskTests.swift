import Foundation
import Darwin
import ARLRemindersCore

@MainActor @main enum RemindersTaskTests {
    enum Failure: Error { case assertion(String) }
    static var checks = 0
    static let identity = RemindersFirstIdentity(helper_bundle_id: "local.arl.remindersbridge", executable_sha256: String(repeating: "a", count: 64), designated_requirement_sha256: String(repeating: "b", count: 64))
    static let target = RemindersSelectedSource(id: "fixture-source", title: "Synthetic local", type: 0, default_list_id: "fixture-list", default_list_title: "Synthetic list")
    static let legacy = "00000000-0000-4000-8000-000000000001"
    static let policy = RemindersUpgradeReview.targetPolicy
    static func expect(_ value: Bool, _ name: String) throws { guard value else { throw Failure.assertion(name) }; checks += 1 }
    static func reject(_ name: String, _ body: () throws -> Void) throws {
        do { try body() } catch { checks += 1; return }
        throw Failure.assertion(name)
    }
    static func id() -> String { UUID().uuidString.lowercased() }
    static func bytes<T: Encodable>(_ value: T) throws -> Data { let e=JSONEncoder(); e.outputFormatting=[.sortedKeys]; return try e.encode(value) }
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { throw Failure.assertion("new isolated directory required") }
        let root=URL(fileURLWithPath:CommandLine.arguments[1])
        guard !FileManager.default.fileExists(atPath:root.path) else { throw Failure.assertion("existing fixture forbidden") }
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        let oldMetadata=try bytes(RemindersFrozenSourceMetadata(source:target,identity:RemindersUpgradeReview.oldIdentity,policy_sha256:RemindersUpgradeReview.oldPolicy))
        let oldBinding=try bytes(RemindersSourceBinding(source:target,identity:RemindersUpgradeReview.oldIdentity,policy_sha256:RemindersUpgradeReview.oldPolicy,expires_at_ms:1))
        let oldSmoke=try bytes(RemindersSmokeRecord(run_id:legacy,policy_sha256:RemindersUpgradeReview.oldPolicy,source_sha256:RemindersNativeIO.hash(oldBinding),state:"pending"))
        let oldReceipt=RemindersUpgradeReceipt(schema:1,identity:identity,policySHA256:policy,runID:legacy,disposition:.unknown,source:nil,evidence:RemindersUpgradeReview.evidence(metadata:oldMetadata,binding:oldBinding,smoke:oldSmoke))
        let historical:[String:Data]=["source-metadata.json":oldMetadata,"source.json":oldBinding,"smoke.json":oldSmoke,"upgrade-review-v1.json":try bytes(oldReceipt)]
        for (name,data) in historical {try RemindersNativeIO.writeNew(data,to:root.appendingPathComponent(name).path)}
        let store=RemindersTaskStore(home:root.path,identity:identity,policy:policy,legacyRunID:legacy,sessionID:id())
        let legacyAdmission=root.appendingPathComponent("admissions")
        try FileManager.default.createDirectory(at:legacyAdmission,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        let oldAdmissionName=id()+".json"
        let oldAdmission=try bytes(RemindersNativeAdmissionRecord(request_id:id(),action:"run_smoke",frame_sha256:String(repeating:"d",count:64),state:"pending",outcome:"needs_review",code:"request_outcome_unknown"))
        try RemindersNativeIO.writeNew(oldAdmission,to:legacyAdmission.appendingPathComponent(oldAdmissionName).path)
        let legacyStore=RemindersUpgradeStore(home:root.path,identity:identity,policy:policy,runID:legacy)
        try expect(try legacyStore.receipt()?.disposition == .unknown && !legacyStore.needsReview(),"actual history consumer accepts retained unknown receipt")
        try expect(try store.admissionDirectory()==root.appendingPathComponent("tasks-v1/admissions").path,"new requests never consume historical admission ledger")
        let now=Int64(Date().timeIntervalSince1970*1000), uptime=ProcessInfo.processInfo.systemUptime
        func draft(_ title:String="Synthetic task") throws -> RemindersTaskRecord {try store.prepare(id:id(),title:title)}
        func scoped(_ value:RemindersTaskRecord) throws -> RemindersTaskRecord {try store.grant(id:value.task_id,expected:value.digest,source:target,nowMS:now,uptime:uptime)}
        let a=try draft()
        try expect(a.state == .draft && a.scope == nil,"legacy unknown does not grant or block a separate draft")
        try expect(try store.prepare(id:a.task_id,title:a.title).digest == a.digest,"same task prepare is idempotent")
        try reject("changed title cannot replace task") {_=try store.prepare(id:a.task_id,title:"Changed")}
        try reject("legacy run cannot become new task") {_=try store.prepare(id:legacy,title:"Synthetic")}
        try reject("invalid title is rejected") {_=try draft("bad\u{202e}title")}
        var effects=0
        try reject("no scope cannot enter effect") {_=try store.submit(id:a.task_id,expected:a.digest,nowMS:now,uptime:uptime,validate:{_ in},effect:{_ in effects+=1;return "synthetic"})}
        try expect(effects==0,"no implicit scope or save")
        try reject("stale proposal cannot grant scope") {_=try store.grant(id:a.task_id,expected:String(repeating:"d",count:64),source:target,nowMS:now,uptime:uptime)}
        let selected=try scoped(a)
        try expect(selected.state == .scoped && selected.scope?.source == target,"exact independent target grant")
        try expect(selected.scope?.expires_uptime == uptime+300 && selected.scope?.expires_at_ms == now+300000,"finite scope")
        try reject("expired scope cannot execute") {_=try store.submit(id:a.task_id,expected:selected.digest,nowMS:now+300001,uptime:uptime+301,validate:{_ in},effect:{_ in effects+=1;return "synthetic"})}
        try reject("wall rollback cannot revive monotonic expiry") {_=try store.submit(id:a.task_id,expected:selected.digest,nowMS:now-1000,uptime:uptime+301,validate:{_ in},effect:{_ in effects+=1;return "synthetic"})}
        let restarted=RemindersTaskStore(home:root.path,identity:identity,policy:policy,legacyRunID:legacy,sessionID:id())
        try reject("restart or revoke invalidates grant") {_=try restarted.submit(id:a.task_id,expected:selected.digest,nowMS:now,uptime:uptime,validate:{_ in},effect:{_ in effects+=1;return "synthetic"})}
        let newIdentity=RemindersFirstIdentity(helper_bundle_id:identity.helper_bundle_id,executable_sha256:String(repeating:"d",count:64),designated_requirement_sha256:identity.designated_requirement_sha256)
        let upgraded=RemindersTaskStore(home:root.path,identity:newIdentity,policy:policy,legacyRunID:legacy,sessionID:store.sessionID)
        try expect(try upgraded.read(a.task_id).digest == selected.digest,"record remains inspectable across same-subject upgrade")
        try reject("upgrade does not inherit live task scope") {_=try upgraded.submit(id:a.task_id,expected:selected.digest,nowMS:now,uptime:uptime,validate:{_ in},effect:{_ in effects+=1;return "synthetic"})}
        try reject("target failure before admission has no effect") {_=try store.submit(id:a.task_id,expected:selected.digest,nowMS:now,uptime:uptime,validate:{_ in throw RemindersTransportFault("target_changed")},effect:{_ in effects+=1;return "synthetic"})}
        try expect(effects==0 && (try store.read(a.task_id)).state == .scoped,"failed preflight does not consume a save")
        let repository=FixtureRepository()
        func effect(_ task:RemindersTaskRecord) throws -> String {
            try expect(try store.read(task.task_id).state == .attempting,"durable consumption precedes real adapter entry")
            let result=try RemindersTaskRunner.create(task,home:root.path,repository:repository,check:{})
            effects+=1;return result
        }
        let saved=try store.submit(id:a.task_id,expected:selected.digest,nowMS:now,uptime:uptime,validate:{_ in},effect:effect)
        try expect(saved.state == .saved && repository.saveAttempts==1,"actual production adapter performs one synthetic save")
        _=try store.submit(id:a.task_id,expected:selected.digest,nowMS:now,uptime:uptime,validate:{_ in throw Failure.assertion("terminal validation")},effect:{_ in throw Failure.assertion("terminal effect")})
        try expect(repository.saveAttempts==1 && effects==1,"new request id does not replay saved operation")
        let b=try scoped(draft("Synthetic uncertain task"));repository.failAfterSave=true
        try reject("adapter failure after commit stays unknown") {_=try store.submit(id:b.task_id,expected:b.digest,nowMS:now,uptime:uptime,validate:{_ in},effect:effect)}
        let unknown=try store.read(b.task_id)
        try expect(unknown.state == .unknown && repository.saveAttempts==2,"unknown is attached to just its operation")
        _=try store.submit(id:b.task_id,expected:b.digest,nowMS:now,uptime:uptime,validate:{_ in},effect:effect)
        try expect(repository.saveAttempts==2 && (try store.read(b.task_id)).digest==unknown.digest,"unknown retry is read-only")
        try reject("unknown cannot regain scope") {_=try scoped(unknown)}
        try reject("unknown cannot be cancelled away") {_=try store.cancel(id:b.task_id,expected:unknown.digest)}
        repository.failAfterSave=false
        let c=try scoped(draft("Separate synthetic task"))
        _=try store.submit(id:c.task_id,expected:c.digest,nowMS:now,uptime:uptime,validate:{_ in},effect:effect)
        try expect(repository.saveAttempts==3 && (try store.read(b.task_id)).digest==unknown.digest,"independent new task proceeds without changing unknown")
        let d=try scoped(draft("Synthetic interrupted task"));var validations=0
        try reject("cancel after admission is conservatively consumed") {_=try store.submit(id:d.task_id,expected:d.digest,nowMS:now,uptime:uptime,validate:{_ in validations+=1;if validations==2 {throw RemindersTransportFault("cancelled")}},effect:effect)}
        try expect((try store.read(d.task_id)).state == .unknown && repository.saveAttempts==3,"no effect on post-admission cancel")
        let e=try draft("Synthetic revoked task");let cancelled=try store.cancel(id:e.task_id,expected:e.digest)
        _=try store.submit(id:e.task_id,expected:cancelled.digest,nowMS:now,uptime:uptime,validate:{_ in},effect:effect)
        try expect(repository.saveAttempts==3 && cancelled.scope==nil,"cancelled task never enters save")
        let page=try store.page(offset:0)
        try expect(page.entries.count==5 && page.entries.contains(where:{$0.task_id==b.task_id && $0.state == .unknown}),"durable history lists unknown")
        _=try draft("Sixth task");let first=try store.page(offset:0);let second=try store.page(offset:first.next_offset!)
        try expect(first.entries.count==5 && second.entries.count==1,"bounded history pagination")
        let frame=RemindersFirstFrame(task:.task_prepare,requestID:UUID(),taskID:id(),title:"Synthetic wire task")
        try expect(try RemindersFirstFrame.decode(bytes(frame)).title==frame.title,"actual task frame decoder")
        var wire=try JSONSerialization.jsonObject(with:bytes(frame)) as! [String:Any]
        wire["source_id"]="unreviewed";try reject("caller cannot supply target") {_=try RemindersFirstFrame.decode(JSONSerialization.data(withJSONObject:wire))}
        wire.removeValue(forKey:"source_id");wire["schema_version"]=1;try reject("task protocol cannot enter legacy schema") {_=try RemindersFirstFrame.decode(JSONSerialization.data(withJSONObject:wire))}
        try reject("task fields cannot enter legacy operation capability") {var x=wire;x["schema_version"]=2;x["capability_id"]="apple.reminders.create.v3";_=try RemindersFirstFrame.decode(JSONSerialization.data(withJSONObject:x))}
        let list=RemindersFirstFrame(task:.task_list,requestID:UUID(),offset:0)
        var listWire=try JSONSerialization.jsonObject(with:bytes(list)) as! [String:Any];listWire["offset"]=true
        try reject("boolean cursor rejected") {_=try RemindersFirstFrame.decode(JSONSerialization.data(withJSONObject:listWire))}
        let duplicate=String(decoding:try bytes(frame),as:UTF8.self).replacingOccurrences(of:"\"schema_version\":2",with:"\"schema_version\":2,\"schema_version\":2")
        try reject("duplicate frame keys rejected") {_=try RemindersFirstFrame.decode(Data(duplicate.utf8))}
        let deployment=RemindersNativeDeployment(schema_version:1,helper_bundle_path:root.appendingPathComponent("Synthetic.app").path,host_home:root.path,
            control_requirement:RemindersStablePeerIdentity.controlRequirement,helper_requirement:RemindersStablePeerIdentity.helperRequirement,
            helper_executable_sha256:identity.executable_sha256,helper_designated_requirement_sha256:identity.designated_requirement_sha256,
            closure_sha256:String(repeating:"d",count:64),policy_sha256:policy)
        let status=RemindersFirstFrame(task:.task_status,requestID:UUID(),taskID:saved.task_id)
        let good=RemindersFirstReply(schema_version:1,request_id:status.request_id,action:status.action,outcome:"refreshed",code:"ok",snapshot:nil,task:saved)
        try expect(try RemindersNativeClient.admitReply(bytes(good),for:status,deployment:deployment).task?.task_id==saved.task_id,"production consumer admits bound task")
        var bad=try JSONSerialization.jsonObject(with:bytes(good)) as! [String:Any]
        bad["request_id"]=id();try reject("old response cannot satisfy new request") {_=try RemindersNativeClient.admitReply(JSONSerialization.data(withJSONObject:bad),for:status,deployment:deployment)}
        bad=try JSONSerialization.jsonObject(with:bytes(good)) as! [String:Any];var badTask=bad["task"] as! [String:Any];badTask["task_id"]=id();bad["task"]=badTask
        try reject("another task cannot satisfy response") {_=try RemindersNativeClient.admitReply(JSONSerialization.data(withJSONObject:bad),for:status,deployment:deployment)}
        badTask["task_id"]=saved.task_id;badTask["policy_sha256"]=String(repeating:"f",count:64);bad["task"]=badTask
        try reject("other policy rejected by actual consumer") {_=try RemindersNativeClient.admitReply(JSONSerialization.data(withJSONObject:bad),for:status,deployment:deployment)}
        let listReply=RemindersFirstReply(schema_version:1,request_id:list.request_id,action:list.action,outcome:"refreshed",code:"ok",snapshot:nil,task_page:first)
        try expect(try RemindersNativeClient.admitReply(bytes(listReply),for:list,deployment:deployment).task_page?.entries.count==5,"actual bounded-history consumer")
        let wrongPage=RemindersFirstReply(schema_version:1,request_id:list.request_id,action:list.action,outcome:"refreshed",code:"ok",snapshot:nil,task_page:second)
        try reject("old page cannot replace requested page") {_=try RemindersNativeClient.admitReply(bytes(wrongPage),for:list,deployment:deployment)}
        for (name,data) in historical {try expect(try Data(contentsOf:root.appendingPathComponent(name))==data,"legacy evidence and budget untouched")}
        try expect(try Data(contentsOf:legacyAdmission.appendingPathComponent(oldAdmissionName))==oldAdmission && FileManager.default.contentsOfDirectory(atPath:legacyAdmission.path)==[oldAdmissionName],"historical request ledger bytes and entry set unchanged")
        try expect(try legacyStore.receipt()?.disposition == .unknown && !legacyStore.needsReview(),"new tasks never promote or invalidate historical unknown")
        try expect(repository.listItems.count==1,"new tasks do not create lists")
        print("reminders_tasks_pass checks=\(checks) real_eventkit_calls=0 real_saves=0 synthetic_saves=\(repository.saveAttempts)")
    }
}
