import Foundation

@MainActor final class CalendarBusinessFixture: CalendarBusinessBackend {
    var access: CalendarBusinessAccess = .full_access
    var reads=0, preparations=0, effects=0, claims=0, finishes=0, logs=0
    var failEffect=false, failFinish=false, failClaim=false, permitted=true
    var changed=false, failRead=false
    var rows: [String:CalendarBusinessOperation] = [:]
    var preparationHook: (() -> Void)?
    let calendar = CalendarBusinessCalendar(id:"calendar-a",title:"测试",source:"本机",writable:true,is_default:true)
    func calendars() throws -> [CalendarBusinessCalendar] {
        if failRead { throw CalendarBusinessFault("synthetic_read_error") }
        guard access.canRead else { throw CalendarBusinessFault("needs_full_access") }; reads += 1;return [calendar]
    }
    func query(_ value:CalendarBusinessQuery) throws -> (events:[CalendarBusinessEvent],truncated:Bool) {
        guard access.canRead else { throw CalendarBusinessFault("needs_full_access") }; reads += 1;return ([],false)
    }
    func get(_ target:CalendarBusinessTarget) throws -> CalendarBusinessEvent { throw CalendarBusinessFault("event_missing_or_changed") }
    func prepare(_ request:CalendarBusinessRequest) throws -> CalendarBusinessClaim {
        preparations += 1
        guard access.canCreate else { throw CalendarBusinessFault("needs_permission") }
        if access == .write_only, request.action != .create || request.draft?.calendar_id != nil { throw CalendarBusinessFault("needs_full_access") }
        let selected = changed ? CalendarBusinessCalendar(id:"other",title:"其他",source:"本机",writable:true,is_default:true):calendar
        if preparations == 1 { preparationHook?() }
        return .init(request:request,calendar:selected)
    }
    func commit(_ claim:CalendarBusinessClaim) throws -> CalendarBusinessOperation {
        effects += 1
        if failEffect { throw CalendarBusinessFault("synthetic_save_error") }
        return .init(task_id:claim.request.task_id,digest:claim.request.digest,action:claim.request.action,
            state:access.canRead ? .saved_local:.saved_unreadable,code:"fixture_only",event:nil)
    }
    func handler() -> CalendarBusinessHandler {
        .init(backend:self,port:.init(verify:{
            if !self.permitted { throw CalendarBusinessFault("owner_unavailable") }
        },lookup:{self.rows[$0]},claim:{ claim in
            self.claims += 1
            guard self.rows[claim.request.task_id] == nil else { throw CalendarBusinessFault("operation_consumed") }
            self.rows[claim.request.task_id] = .init(task_id:claim.request.task_id,digest:claim.request.digest,action:claim.request.action,state:.attempting,code:"attempting",event:nil)
            if self.failClaim { throw CalendarBusinessFault("journal_uncertain") }
        },finish:{ value in
            self.finishes += 1
            if self.failFinish { throw CalendarBusinessFault("journal_uncertain") }
            self.rows[value.task_id]=value
        },record:{_,_ in self.logs += 1}))
    }
}
@main enum CalendarBusinessTests {
    static let id="5dbe415c-8762-40cc-aaf3-d15b23af861a"
    static func draft(title:String="测试",calendar:String?=nil) -> CalendarBusinessDraft {
        .init(calendar_id:calendar,title:title,start:"2026-10-20T10:00:00+08:00",end:"2026-10-20T11:00:00+08:00",time_zone:"Asia/Shanghai",all_day:false,alarm_seconds:[300],recurrence:.init(frequency:.weekly,interval:1,count:3,until:nil))
    }
    static func reject(_ body:() throws -> Void) {
        do { try body();preconditionFailure("expected rejection") } catch { }
    }
    @MainActor static func main() async throws {
        try draft().validate()
        let request=CalendarBusinessRequest(taskID:id,action:.create,draft:draft())
        let decoded=try CalendarBusinessRequest.decode(tool:request.action.tool,argumentsJSON:request.argumentsJSON())
        precondition(decoded == request && decoded.digest == request.digest)
        reject { _ = try CalendarBusinessContract.date("2026-02-30T10:00:00Z") }
        reject { _ = try CalendarBusinessContract.date("2026-10-20T24:00:00Z") }
        reject { _ = try CalendarBusinessContract.date("2026-10-20T10:00:00") }
        reject { try CalendarBusinessRecurrence(frequency:.daily,interval:0,count:nil,until:nil).validate(start:Date()) }
        reject { try CalendarBusinessRecurrence(frequency:.daily,interval:1,count:3,until:"2026-11-20T00:00:00Z").validate(start:Date()) }
        reject { try CalendarBusinessQuery(start:"2026-01-01T00:00:00Z",end:"2028-01-01T00:00:00Z",calendar_ids:["a"],limit:10).validate() }
        var object=try JSONSerialization.jsonObject(with:request.argumentsJSON()) as! [String:Any]
        var fields=object["draft"] as! [String:Any];fields["attendees"]=["nobody@example.invalid"];object["draft"]=fields
        reject { _ = try CalendarBusinessRequest.decode(tool:request.action.tool,argumentsJSON:JSONSerialization.data(withJSONObject:object)) }
        reject { _ = try CalendarBusinessRequest.decode(tool:"mio_calendar_get",argumentsJSON:request.argumentsJSON()) }
        reject { try CalendarBusinessDraft(calendar_id:nil,title:"全天",start:"2026-10-20T10:00:00Z",end:"2026-10-21T10:00:00Z",time_zone:"UTC",all_day:true,alarm_seconds:[],recurrence:nil).validate() }
        // A 23-hour DST all-day event is valid, with an exclusive end midnight.
        try CalendarBusinessDraft(calendar_id:nil,title:"全天",start:"2026-03-08T00:00:00-08:00",end:"2026-03-09T00:00:00-07:00",time_zone:"America/Los_Angeles",all_day:true,alarm_seconds:[],recurrence:nil).validate()
        let f=CalendarBusinessFixture(), h=f.handler()
        let first=try await h.execute(request)
        precondition(first.operation?.state == .saved_local && f.effects == 1 && f.claims == 1 && f.logs == 2)
        _ = try await h.execute(request)
        _ = try await h.execute(.init(taskID:id,action:.operation_status))
        precondition(f.effects == 1 && f.preparations == 2)
        do { _ = try await h.execute(.init(taskID:id,action:.create,draft:draft(title:"不同")));preconditionFailure() } catch { }
        precondition(f.effects == 1)
        let unknown=CalendarBusinessFixture();unknown.failEffect=true;let uh=unknown.handler()
        let unknownReply=try await uh.execute(request)
        precondition(unknownReply.operation?.state == .outcome_unknown)
        _ = try await uh.execute(request);precondition(unknown.effects == 1 && unknown.claims == 1)
        let finish=CalendarBusinessFixture();finish.failFinish=true;let fh=finish.handler()
        do { _ = try await fh.execute(request);preconditionFailure() } catch { }
        let finishReply=try await fh.execute(.init(taskID:id,action:.operation_status))
        precondition(finishReply.operation?.state == .attempting)
        _ = try await fh.execute(request);precondition(finish.effects == 1)
        let claim=CalendarBusinessFixture();claim.failClaim=true;let ch=claim.handler()
        do { _ = try await ch.execute(request);preconditionFailure() } catch { }
        _ = try await ch.execute(request);precondition(claim.effects == 0 && claim.rows[id]?.state == .attempting)
        let denied=CalendarBusinessFixture();denied.permitted=false
        do { _ = try await denied.handler().execute(request);preconditionFailure() } catch { }
        precondition(denied.claims == 0 && denied.effects == 0)
        let changed=CalendarBusinessFixture();changed.preparationHook={changed.changed=true}
        do { _ = try await changed.handler().execute(request);preconditionFailure() } catch { }
        precondition(changed.claims == 0 && changed.effects == 0)
        let cancel=CalendarBusinessFixture();cancel.preparationHook={withUnsafeCurrentTask{$0?.cancel()}}
        let work=Task { @MainActor in try await cancel.handler().execute(request) }
        do { _ = try await work.value;preconditionFailure() } catch { }
        precondition(cancel.claims == 0 && cancel.effects == 0)
        let write=CalendarBusinessFixture();write.access = .write_only;let wh=write.handler()
        let writeReply=try await wh.execute(request)
        precondition(writeReply.operation?.state == .saved_unreadable)
        do { _ = try await wh.execute(.init(taskID:UUID().uuidString.lowercased(),action:.calendars));preconditionFailure() } catch { }
        precondition(write.reads == 0)
        let read=CalendarBusinessFixture(), rh=read.handler()
        _ = try await rh.execute(.init(taskID:id,action:.calendars))
        precondition(read.effects == 0 && read.claims == 0 && read.reads == 1)
        // Native controller keeps prior trusted metadata and the exact unresolved
        // task across subsequent actions, with no replacement submission.
        let suite="arl-calendar-controller-test-"+UUID().uuidString
        let preferences=UserDefaults(suiteName:suite)!
        defer { preferences.removePersistentDomain(forName:suite) }
        let permission=CalendarPermissionController(enabled:true,readStatus:{.fullAccess},requestAccess:{preconditionFailure()},
            verifyOwner:{},foreground:{true},preferences:preferences,startAutomatically:false,
            requestReadWrite:{preconditionFailure()},verifyReadWriteUsage:{})
        let native=CalendarBusinessFixture()
        let controller=CalendarBusinessController(permission:permission,handler:native.handler(),preferences:preferences)
        await controller.loadCalendars();precondition(controller.calendars.count == 1 && controller.selectedCalendarID == "calendar-a")
        native.failRead=true;await controller.loadCalendars();precondition(controller.calendars.count == 1)
        await controller.save(draft(),taskID:id);precondition(controller.operation?.state == .saved_local)
        native.failFinish=true
        let secondID=UUID().uuidString.lowercased()
        await controller.save(draft(),taskID:secondID)
        precondition(controller.unresolved && controller.currentTaskID == secondID && controller.operation?.state == .attempting)
        await controller.save(draft(),taskID:UUID().uuidString.lowercased())
        precondition(native.effects == 2 && controller.currentTaskID == secondID)
        controller.selectEvent(nil);precondition(controller.currentTaskID == secondID)
        print("PASS Calendar domain: strict DTO, calendar dates/DST, journal claim/finalize uncertainty, same-ID replay refusal, cancellation/target change before claim, write-only separation. Synthetic ports only; no EventKit store, TCC request or calendar write executed.")
    }
}
