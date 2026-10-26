import Foundation
import EventKit
import ARLRemindersCore

public final class EventKitRepository: ReminderRepository {
    private var eventStore: EKEventStore?
    private let lock=NSRecursiveLock()
    public init() {} // No EventKit store construction, access request or metadata read.
    public static func authorizationStatus() -> String {
        switch EKEventStore.authorizationStatus(for:.reminder) {
        case .fullAccess: return "full_access"
        case .notDetermined: return "not_determined"
        case .denied: return "denied"
        case .restricted: return "restricted"
        default: return "unknown"
        }
    }
    private func store() throws -> EKEventStore {
        guard Self.authorizationStatus() == "full_access" else {throw AdapterFault("needs_permission")}
        if eventStore == nil { eventStore=EKEventStore() }
        return eventStore!
    }
    private func withStore<T>(_ body:(EKEventStore) throws -> T) throws -> T {
        lock.lock();defer{lock.unlock()};return try body(store())
    }
    private func calendar(_ id:String, store:EKEventStore, writable:Bool = false) throws -> EKCalendar {
        guard let c=store.calendar(withIdentifier:id), c.allowedEntityTypes.contains(.reminder) else {throw AdapterFault("list_not_found")}
        if writable && !c.allowsContentModifications {throw AdapterFault("list_not_writable")};return c
    }
    private func list(_ c:EKCalendar, defaultID:String?=nil) -> ReminderList {
        var row=ReminderList(id:c.calendarIdentifier,title:c.title,sourceID:c.source.sourceIdentifier,writable:c.allowsContentModifications)
        row.calendar_type=c.type.rawValue;row.subscribed=c.isSubscribed;row.immutable=c.isImmutable
        row.is_system_default=defaultID.map{$0==c.calendarIdentifier}
        return row
    }
    public func defaultListID() throws -> String? {try withStore {s in s.defaultCalendarForNewReminders()?.calendarIdentifier}}
    public func sources(ids:Set<String>) throws -> [ReminderSource] {try withStore {s in
        let defaultSource=s.defaultCalendarForNewReminders()?.source.sourceIdentifier
        return ids.sorted().compactMap {s.source(withIdentifier:$0)}.map {source in
            var row=ReminderSource(id:source.sourceIdentifier,title:source.title,type:source.sourceType.rawValue)
            row.reminder_list_count=source.calendars(for:.reminder).count
            row.is_delegate=source.isDelegate;row.is_system_default_account=defaultSource.map{$0==source.sourceIdentifier}
            return row
        }
    }}
    public func lists(ids:Set<String>) throws -> [ReminderList] {try withStore {s in
        let defaultID=s.defaultCalendarForNewReminders()?.calendarIdentifier
        return ids.sorted().compactMap {s.calendar(withIdentifier:$0)}.filter {$0.allowedEntityTypes.contains(.reminder)}.map {list($0,defaultID:defaultID)}
    }}
    public func createList(title:String,sourceID:String,beforeCommit:() throws -> Void) throws -> ReminderList {
        try validateTitle(title)
        return try withStore {s in
            defer {s.reset()}
            guard let source=s.source(withIdentifier:sourceID) else {throw AdapterFault("source_not_found")}
            guard [.local,.calDAV,.exchange,.mobileMe].contains(source.sourceType) else {throw AdapterFault("unsupported_source")}
            let c=EKCalendar(for:.reminder,eventStore:s);c.title=title;c.source=source
            guard Self.authorizationStatus() == "full_access" else {throw AdapterFault("needs_permission")}
            try beforeCommit()
            do {try s.saveCalendar(c,commit:true)} catch {s.reset();throw AdapterFault("outcome_unknown")}
            return list(c)
        }
    }
    public func query(listID:String,includeCompleted:Bool,dueWindow:DueWindow?,checkRead:() throws -> Void) throws -> [ReminderSnapshot] {
        try withStore {s in
            let c=try calendar(listID,store:s)
            let bounds=try dueWindow?.bounds()
            guard bounds == nil || !includeCompleted else {throw AdapterFault("query_window_requires_incomplete")}
            let predicate = includeCompleted ? s.predicateForReminders(in:[c]) :
                s.predicateForIncompleteReminders(withDueDateStarting:bounds?.0,ending:bounds?.1,calendars:[c])
            let box=FetchBox();let sem=DispatchSemaphore(value:0);let deadline=DispatchTime.now()+5
            let token=s.fetchReminders(matching:predicate) {items in box.set(items);sem.signal()}
            do {
                while sem.wait(timeout:min(deadline,DispatchTime.now()+0.05)) != .success {
                    try checkRead()
                    guard DispatchTime.now() < deadline else {throw AdapterFault("read_timeout")}
                }
                try checkRead()
                let items=try box.get()
                var snapshots=[ReminderSnapshot]()
                for item in items where item.calendar.calendarIdentifier == listID && (includeCompleted || !item.isCompleted) {
                    if snapshots.count % 64 == 0 {try checkRead()}
                    let snapshot=try NativeMapping.snapshot(item)
                    snapshots.append(snapshot)
                }
                try checkRead()
                return snapshots.sorted {$0.id < $1.id}
            } catch {
                box.discard();s.cancelFetchRequest(token);throw error
            }
        }
    }
    private func reminder(_ id:String,listID:String,store:EKEventStore) throws -> EKReminder {
        _ = try calendar(listID,store:store)
        guard let r=store.calendarItem(withIdentifier:id) as? EKReminder, r.refresh(), r.calendar.calendarIdentifier == listID else {throw AdapterFault("reminder_not_found")};return r
    }
    public func get(id:String,listID:String) throws -> ReminderSnapshot {try withStore {s in try NativeMapping.snapshot(reminder(id,listID:listID,store:s))}}
    public func create(listID:String,title:String,patch:Patch,beforeCommit:() throws -> Void) throws -> ReminderSnapshot {
        try validateTitle(title);try patch.validate()
        guard patch.title == nil else {throw AdapterFault("invalid_arguments")}
        return try withStore {s in
            defer {s.reset()}
            let c=try calendar(listID,store:s,writable:true)
            let r=EKReminder(eventStore:s);r.calendar=c;r.title=title;r.priority=0;r.isCompleted=false
            var empty=ReminderSnapshot(id:"",listID:listID,title:title);try empty.revise()
            try validatePatch(patch,existing:empty);try NativeMapping.apply(patch,to:r)
            guard Self.authorizationStatus() == "full_access" else {throw AdapterFault("needs_permission")}
            _ = try calendar(listID,store:s,writable:true)
            do {try beforeCommit()} catch {s.reset();throw error}
            do {try s.save(r,commit:true)} catch {s.reset();throw AdapterFault("outcome_unknown")}
            return try NativeMapping.snapshot(r)
        }
    }
    public func update(id:String,listID:String,revision:String,patch:Patch?,completed:Bool?,beforeCommit:() throws -> Void) throws -> ReminderSnapshot {
        try withStore {s in
            defer {s.reset()}
            _ = try calendar(listID,store:s,writable:true)
            let r=try reminder(id,listID:listID,store:s)
            var before=try NativeMapping.snapshot(r)
            guard before.revision == revision else {throw AdapterFault("revision_conflict")}
            if let patch {try validatePatch(patch,existing:before)}
            // Refresh again before patching; no whole-object reconstruction, no assignment to omitted fields.
            guard r.refresh(), r.calendar.calendarIdentifier == listID else {throw AdapterFault("reminder_not_found")}
            before=try NativeMapping.snapshot(r)
            guard before.revision == revision else {throw AdapterFault("revision_conflict")}
            if let patch {try validatePatch(patch,existing:before);try NativeMapping.apply(patch,to:r)}
            if let completed, r.isCompleted != completed {r.isCompleted=completed}
            guard Self.authorizationStatus() == "full_access" else {s.reset();throw AdapterFault("needs_permission")}
            _ = try calendar(listID,store:s,writable:true)
            do {try beforeCommit()} catch {s.reset();throw error}
            do {try s.save(r,commit:true)} catch {s.reset();throw AdapterFault("outcome_unknown")}
            return try NativeMapping.snapshot(r)
        }
    }
    public func delete(id:String,listID:String,revision:String,beforeCommit:() throws -> Void) throws -> ReminderDeletion {
        try withStore {s in
            defer {s.reset()}
            _ = try calendar(listID,store:s,writable:true)
            let r=try reminder(id,listID:listID,store:s)
            try validateDelete(NativeMapping.snapshot(r),id:id,listID:listID,revision:revision)
            guard Self.authorizationStatus()=="full_access" else {throw AdapterFault("needs_permission")}
            try beforeCommit()
            // Recheck the exact object and revision after admission, before any removal.
            guard r.refresh(),r.calendar.calendarIdentifier==listID else {throw AdapterFault("reminder_not_found")}
            try validateDelete(NativeMapping.snapshot(r),id:id,listID:listID,revision:revision)
            _ = try calendar(listID,store:s,writable:true)
            guard Self.authorizationStatus()=="full_access" else {throw AdapterFault("needs_permission")}
            try beforeCommit()
            do {try s.remove(r,commit:true)} catch {throw AdapterFault("outcome_unknown")}
            // Any failure from this point is uncertain, never a safe preflight rejection.
            guard Self.authorizationStatus()=="full_access" else {throw AdapterFault("outcome_unknown")}
            s.reset()
            guard s.calendarItem(withIdentifier:id)==nil else {throw AdapterFault("outcome_unknown")}
            return ReminderDeletion(id:id,listID:listID,expectedRevision:revision)
        }
    }
}
private final class FetchBox: @unchecked Sendable {
    private let lock=NSLock();private var value:[EKReminder]?;private var error:AdapterFault?;private var discarded=false
    func set(_ v:[EKReminder]?) {
        lock.lock();defer{lock.unlock()};guard !discarded else{return}
        // EventKit already materialized its callback array. Refuse oversized results before retaining or mapping it.
        if let v {value=v} else {error=AdapterFault("read_failed")}
    }
    func get() throws -> [EKReminder] {lock.lock();defer{lock.unlock()};if let error {throw error};guard let value else {throw AdapterFault("read_failed")};return value}
    func discard() {lock.lock();defer{lock.unlock()};discarded=true;value=nil}
}

/// Public for mapping tests with EKRecurrenceRule/EKAlarm only; tests never construct EKEventStore.
public enum NativeMapping {
    public static func rule(_ spec:Recurrence) throws -> EKRecurrenceRule {
        try spec.validate()
        let frequency: EKRecurrenceFrequency
        switch spec.frequency {case "daily":frequency = .daily;case "weekly":frequency = .weekly;case "monthly":frequency = .monthly;default:frequency = .yearly}
        let end:EKRecurrenceEnd?
        if let count=spec.count {end=EKRecurrenceEnd(occurrenceCount:count)}
        else if let until=spec.until {end=EKRecurrenceEnd(end:try parseInstant(until))} else {end=nil}
        return EKRecurrenceRule(recurrenceWith:frequency,interval:spec.interval,end:end)
    }
    public static func alarm(_ spec:Alarm) throws -> EKAlarm {
        try spec.validate()
        if let at=spec.at {return EKAlarm(absoluteDate:try parseInstant(at))}
        return EKAlarm(relativeOffset:spec.offset_seconds!)
    }
    public static func recurrence(_ rules:[EKRecurrenceRule]) -> RichField {
        var editable=rules.count <= 1
        let descriptors=rules.map {rule -> [String:String] in
            let name:[EKRecurrenceFrequency:String]=[.daily:"daily",.weekly:"weekly",.monthly:"monthly",.yearly:"yearly"]
            var d=["frequency":name[rule.frequency] ?? "unknown", "interval":String(rule.interval),"calendar":rule.calendarIdentifier,"first_day_of_week":String(rule.firstDayOfTheWeek)]
            let advanced:[(String,[NSNumber]?)]=[("days_of_month",rule.daysOfTheMonth),("months_of_year",rule.monthsOfTheYear),("weeks_of_year",rule.weeksOfTheYear),("days_of_year",rule.daysOfTheYear),("set_positions",rule.setPositions)]
            for (key,values) in advanced {
                d[key]=values.map {"["+$0.map {String(describing:$0)}.joined(separator:",")+"]"} ?? "null"
                if !(values ?? []).isEmpty {editable=false}
            }
            d["days_of_week"]=rule.daysOfTheWeek.map {"["+$0.map {"\($0.dayOfTheWeek.rawValue):\($0.weekNumber)"}.joined(separator:",")+"]"} ?? "null"
            if !(1...999).contains(rule.interval) || !(rule.daysOfTheWeek ?? []).isEmpty || ![0,2].contains(rule.firstDayOfTheWeek) || name[rule.frequency] == nil || rule.calendarIdentifier != "gregorian" {editable=false}
            if let end=rule.recurrenceEnd {
                d["count"]=String(end.occurrenceCount);d["until"]=end.endDate.map(instantString) ?? "null";d["until_reference_seconds"]=end.endDate.map {String($0.timeIntervalSinceReferenceDate)} ?? "null"
                if end.occurrenceCount > 9999 {editable=false}
            }
            return d
        }
        return RichField(editable:editable,descriptors:descriptors)
    }
    public static func alerts(_ alarms:[EKAlarm]) -> RichField {
        var editable=alarms.count <= 1
        let descriptors=alarms.map {a -> [String:String] in
            var d=["kind":a.absoluteDate == nil ? "relative":"absolute","type":String(a.type.rawValue),"proximity":String(a.proximity.rawValue),"offset_seconds":String(a.relativeOffset)]
            d["at"]=a.absoluteDate.map(instantString) ?? "null";d["at_reference_seconds"]=a.absoluteDate.map {String($0.timeIntervalSinceReferenceDate)} ?? "null";d["email"]=a.emailAddress ?? "null";d["sound"]=a.soundName ?? "null"
            if let l=a.structuredLocation {d["location_title"]=l.title;d["radius"]=String(l.radius);if let c=l.geoLocation {d["latitude"]=String(c.coordinate.latitude);d["longitude"]=String(c.coordinate.longitude)}}
            if !a.relativeOffset.isFinite || abs(a.relativeOffset) > 31_536_000 || a.type != .display || a.structuredLocation != nil || a.proximity != .none || a.emailAddress != nil || a.soundName != nil {editable=false}
            return d
        }
        return RichField(editable:editable,descriptors:descriptors)
    }
    public static func rawComponents(_ c:DateComponents?) -> [String:String] {
        guard let c else{return [:]};var d=[String:String]()
        for (name,value) in [("era",c.era),("year",c.year),("month",c.month),("day",c.day),("hour",c.hour),("minute",c.minute),("second",c.second),("nanosecond",c.nanosecond),("weekday",c.weekday),("weekday_ordinal",c.weekdayOrdinal),("week_of_month",c.weekOfMonth),("week_of_year",c.weekOfYear),("year_for_week_of_year",c.yearForWeekOfYear),("quarter",c.quarter)] {if let value {d[name]=String(value)}}
        if let cal=c.calendar {d["calendar"]=String(describing:cal.identifier)};d["time_zone"]=c.timeZone?.identifier
        if let leap=c.isLeapMonth {d["leap_month"]=String(leap)};return d
    }
    private static func due(_ c:DateComponents?) -> Due? {
        guard let c, let y=c.year, let m=c.month, let d=c.day, c.calendar == nil || c.calendar?.identifier == .gregorian else{return nil}
        if c.hour == nil && c.minute == nil && c.second == nil {return Due(kind:"date",value:String(format:"%04d-%02d-%02d",y,m,d))}
        guard let zone=c.timeZone, c.hour != nil, c.minute != nil else{return nil}
        var cal=c.calendar ?? Calendar(identifier:.gregorian);cal.timeZone=zone
        guard let date=cal.date(from:c) else{return nil};return Due(kind:"date_time",value:instantString(date),timeZone:zone.identifier)
    }
    public static func snapshot(_ r:EKReminder) throws -> ReminderSnapshot {
        var item=ReminderSnapshot(id:r.calendarItemIdentifier,listID:r.calendar.calendarIdentifier,title:r.title ?? "")
        item.notes=r.notes;item.priority=r.priority;item.completed=r.isCompleted;item.completion_date=r.completionDate.map {String($0.timeIntervalSinceReferenceDate)}
        item.modified=r.lastModifiedDate.map {String($0.timeIntervalSinceReferenceDate)};item.due=due(r.dueDateComponents);item.start=due(r.startDateComponents)
        item.due_components=rawComponents(r.dueDateComponents);item.start_components=rawComponents(r.startDateComponents)
        item.recurrence=recurrence(r.recurrenceRules ?? []);item.alerts=alerts(r.alarms ?? []);item.url=r.url?.absoluteString;item.location=r.location
        try item.revise();return item
    }
    static func apply(_ p:Patch,to r:EKReminder) throws {
        try p.validate()
        if p.title?.action == .set {r.title=p.title!.value!}
        if p.notes?.action == .set {r.notes=p.notes!.value!} else if p.notes?.action == .clear {r.notes=nil}
        if p.priority?.action == .set {r.priority=p.priority!.value!}
        if p.due?.action == .set {r.dueDateComponents=try p.due!.value!.components()} else if p.due?.action == .clear {r.dueDateComponents=nil}
        if p.start?.action == .set {r.startDateComponents=try p.start!.value!.components()} else if p.start?.action == .clear {r.startDateComponents=nil}
        if p.recurrence?.action == .set {r.recurrenceRules=[try rule(p.recurrence!.value!)]} else if p.recurrence?.action == .clear {r.recurrenceRules=[]}
        if p.alert?.action == .set {r.alarms=[try alarm(p.alert!.value!)]} else if p.alert?.action == .clear {r.alarms=[]}
    }
}
