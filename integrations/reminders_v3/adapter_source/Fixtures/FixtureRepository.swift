import Foundation
import ARLRemindersCore

/// Isolated synthetic backend. This target has no EventKit dependency and never constructs an Apple store.
public final class FixtureRepository: ReminderRepository {
    public var sourceItems:[ReminderSource]
    public var listItems:[ReminderList]
    public var reminderItems:[ReminderSnapshot]
    public private(set) var saveAttempts=0
    public var failAfterSave=false
    public var persist:(() throws -> Void)?
    public init() {
        sourceItems=[ReminderSource(id:"fixture-source",title:"Synthetic local",type:0)]
        listItems=[ReminderList(id:"fixture-list",title:"Synthetic list",sourceID:"fixture-source",writable:true)]
        reminderItems=[]
    }
    public func sources(ids:Set<String>) throws -> [ReminderSource] {sourceItems.filter {ids.contains($0.id)}}
    public func lists(ids:Set<String>) throws -> [ReminderList] {listItems.filter {ids.contains($0.id)}}
    private func list(_ id:String,writable:Bool=false) throws -> ReminderList {
        guard let list=listItems.first(where:{$0.id==id}) else {throw AdapterFault("list_not_found")}
        guard !writable || list.writable else {throw AdapterFault("list_not_writable")};return list
    }
    private func didSave() throws {saveAttempts += 1;try persist?();if failAfterSave {throw AdapterFault("outcome_unknown")}}
    public func createList(title:String,sourceID:String,beforeCommit:() throws -> Void) throws -> ReminderList {
        try validateTitle(title)
        guard sourceItems.contains(where:{$0.id == sourceID}) else {throw AdapterFault("source_not_found")}
        let l=ReminderList(id:UUID().uuidString.lowercased(),title:title,sourceID:sourceID,writable:true)
        try beforeCommit();listItems.append(l);try didSave();return l
    }
    public func query(listID:String,includeCompleted:Bool,dueWindow:DueWindow?,checkRead:() throws -> Void) throws -> [ReminderSnapshot] {
        _ = try list(listID);try checkRead()
        return try reminderItems.filter { item in
            guard item.list_id == listID && (includeCompleted || !item.completed) else {return false}
            return try dueWindow?.contains(item.due) ?? true
        }.sorted {$0.id < $1.id}
    }
    public func get(id:String,listID:String) throws -> ReminderSnapshot {
        _ = try list(listID)
        guard let r=reminderItems.first(where:{$0.id == id && $0.list_id == listID}) else {throw AdapterFault("reminder_not_found")};return r
    }
    public func create(listID:String,title:String,patch:Patch,beforeCommit:() throws -> Void) throws -> ReminderSnapshot {
        _ = try list(listID,writable:true);try validateTitle(title)
        guard patch.title == nil else {throw AdapterFault("invalid_arguments")}
        var r=ReminderSnapshot(id:UUID().uuidString.lowercased(),listID:listID,title:title)
        try validatePatch(patch,existing:r);try apply(patch,to:&r);try r.revise()
        try beforeCommit();reminderItems.append(r);try didSave();return r
    }
    public func update(id:String,listID:String,revision:String,patch:Patch?,completed:Bool?,beforeCommit:() throws -> Void) throws -> ReminderSnapshot {
        _ = try list(listID,writable:true);var r=try get(id:id,listID:listID)
        guard r.revision == revision else {throw AdapterFault("revision_conflict")}
        if let patch {try validatePatch(patch,existing:r);try apply(patch,to:&r)}
        if let completed, r.completed != completed {r.completed=completed;r.completion_date=completed ? String(Date().timeIntervalSinceReferenceDate):nil}
        r.modified=String(Date().timeIntervalSinceReferenceDate);try r.revise();try beforeCommit();reminderItems[reminderItems.firstIndex(where:{$0.id==id})!]=r;try didSave();return r
    }
    private func apply(_ p:Patch,to r:inout ReminderSnapshot) throws {
        if p.title?.action == .set {r.title=p.title!.value!}
        if p.notes?.action == .set {r.notes=p.notes!.value!} else if p.notes?.action == .clear {r.notes=nil}
        if p.priority?.action == .set {r.priority=p.priority!.value!}
        if p.due?.action == .set {r.due=p.due!.value!;r.due_components=["fixture_value":r.due!.value]} else if p.due?.action == .clear {r.due=nil;r.due_components=[:]}
        if p.start?.action == .set {r.start=p.start!.value!;r.start_components=["fixture_value":r.start!.value]} else if p.start?.action == .clear {r.start=nil;r.start_components=[:]}
        if p.recurrence?.action == .set {let v=p.recurrence!.value!;r.recurrence=RichField(descriptors:[["frequency":v.frequency,"interval":String(v.interval),"count":v.count.map(String.init) ?? "null","until":v.until ?? "null"]])} else if p.recurrence?.action == .clear {r.recurrence=RichField()}
        if p.alert?.action == .set {let v=p.alert!.value!;r.alerts=RichField(descriptors:[["kind":v.kind,"at":v.at ?? "null","offset_seconds":v.offset_seconds.map(String.init(describing:)) ?? "null"]])} else if p.alert?.action == .clear {r.alerts=RichField()}
    }
}
