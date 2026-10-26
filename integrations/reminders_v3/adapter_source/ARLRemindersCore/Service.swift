import Foundation

public protocol ReminderRepository: AnyObject {
    func defaultListID() throws -> String?
    func sources(ids: Set<String>) throws -> [ReminderSource]
    func lists(ids: Set<String>) throws -> [ReminderList]
    func createList(title: String, sourceID: String, beforeCommit: () throws -> Void) throws -> ReminderList
    func query(listID: String, includeCompleted: Bool, dueWindow: DueWindow?, checkRead: () throws -> Void) throws -> [ReminderSnapshot]
    func get(id: String, listID: String) throws -> ReminderSnapshot
    func create(listID: String, title: String, patch: Patch, beforeCommit: () throws -> Void) throws -> ReminderSnapshot
    func update(id: String, listID: String, revision: String, patch: Patch?, completed: Bool?, beforeCommit: () throws -> Void) throws -> ReminderSnapshot
    func delete(id: String, listID: String, revision: String, beforeCommit: () throws -> Void) throws -> ReminderDeletion
}

// Older/test repositories remain closed to deletion unless they implement it.
public extension ReminderRepository {
    func defaultListID() throws -> String? { nil }
    func delete(id:String,listID:String,revision:String,beforeCommit:() throws -> Void) throws -> ReminderDeletion {
        throw AdapterFault("delete_not_supported")
    }
}

/// Host-owned authority. Never deserialize this type from the request or accept it from model output.
/// The embedding must verify transport identity, the exact reviewed digest, expiry and registered grants.
public struct HostAuthority {
    public let owner: String
    public let requestDigest: String
    public let key: String
    public let expires: Date
    public let allowedTools: Set<String>
    public let listIDs: Set<String>
    public let sourceIDs: Set<String>
    /// Native host resolution for a create request that omitted list_id. It never narrows reads.
    public let defaultListID: String?
    public let checkCancelled: () throws -> Void
    public init(owner: String, requestDigest: String, key: String, expires: Date, allowedTools: Set<String>, listIDs: Set<String>, sourceIDs: Set<String>, defaultListID: String? = nil, checkCancelled: @escaping () throws -> Void) {
        self.owner=owner;self.requestDigest=requestDigest;self.key=key;self.expires=expires;self.allowedTools=allowedTools;self.listIDs=listIDs;self.sourceIDs=sourceIDs;self.defaultListID=defaultListID;self.checkCancelled=checkCancelled
    }
    public func check(_ request: Request) throws {
        guard !owner.isEmpty, owner.utf8.count <= 256, expires > Date(), allowedTools.contains(request.tool), requestDigest == (try digest(request)) else { throw AdapterFault("review_not_authorized") }
        if request.isMutation, key != request.args.operation_id { throw AdapterFault("operation_key_mismatch") }
        if let list = request.args.list_id, !listIDs.contains(list) { throw AdapterFault("target_not_authorized") }
        if let source = request.args.source_id, !sourceIDs.contains(source) { throw AdapterFault("target_not_authorized") }
        if request.operation == "create", request.args.list_id == nil {
            guard let list=defaultListID else {throw AdapterFault("default_list_required")}
            guard listIDs.contains(list) else {throw AdapterFault("target_not_authorized")}
        }
        try checkCancelled()
    }
}

public final class RemindersAdapter {
    private let repository: ReminderRepository
    private let journal: OperationJournal
    private let lock = NSRecursiveLock()
    public init(repository: ReminderRepository, journal: OperationJournal) {self.repository=repository;self.journal=journal}
    public func execute(_ request: Request, authority: HostAuthority) throws -> Response {
        lock.lock(); defer { lock.unlock() }
        // Revalidate typed values. A decoded Request is the only public wire constructor.
        try request.validate(); try authority.check(request)
        if request.isMutation {
            return try journal.perform(operationID:request.args.operation_id!, owner:authority.owner, requestDigest:try digest(request)) {
                // Check again immediately before repository entry. Repository rechecks revisions immediately before save.
                try authority.check(request)
                var response = try run(request, authority:authority)
                response.operation_id=request.args.operation_id;response.persistence=request.operation == "delete" ? "deleted_local":"saved_local";response.cloud_sync="not_checked"
                return response
            }
        }
        let response = try run(request, authority:authority)
        try authority.check(request)
        return response
    }
    private func run(_ request: Request, authority: HostAuthority) throws -> Response {
        let a=request.args; var response=Response()
        switch request.operation {
        case "sources": response.sources=try repository.sources(ids:authority.sourceIDs).filter {authority.sourceIDs.contains($0.id)}
        case "lists": response.lists=try repository.lists(ids:authority.listIDs).filter {authority.listIDs.contains($0.id)}
        case "list.lookup":
            let s=a.selector!
            if let id=s.id, !authority.listIDs.contains(id) {throw AdapterFault("target_not_authorized")}
            if let source=s.source_id, !authority.sourceIDs.contains(source) {throw AdapterFault("target_not_authorized")}
            let matches=try repository.lists(ids:authority.listIDs).filter { list in
                authority.listIDs.contains(list.id) && (s.id.map {$0 == list.id} ?? (s.title == list.title && (s.source_id == nil || s.source_id == list.source_id)))
            }
            guard matches.count == 1 else {throw AdapterFault(matches.isEmpty ? "list_not_found" : "ambiguous_list")}
            response.list=matches[0]
        case "list.create": response.list=try repository.createList(title:a.title!,sourceID:a.source_id!,beforeCommit:{try authority.check(request)})
        case "query":
            let listIDs=a.list_id.map {[$0]} ?? authority.listIDs.sorted()
            var items:[ReminderSnapshot]=[]
            for listID in listIDs {
                try authority.check(request)
                let rows=try repository.query(listID:listID,includeCompleted:a.include_completed ?? false,dueWindow:a.due_window,checkRead:{try authority.check(request)})
                guard rows.allSatisfy({$0.list_id==listID}) else {throw AdapterFault("target_not_authorized")}
                items.append(contentsOf:rows)
            }
            let offset=a.offset ?? 0,limit=a.limit ?? 100
            guard offset>=0,(1...100).contains(limit) else {throw AdapterFault("invalid_arguments")}
            items.sort { ($0.list_id,$0.id)<($1.list_id,$1.id) }
            response.reminders=[];response.offset=offset;response.total_count=items.count
            for item in items.dropFirst(offset).prefix(limit) {
                var candidate=response;candidate.reminders!.append(item)
                if try JSONEncoder().encode(candidate).count>24000 {
                    guard !(response.reminders?.isEmpty ?? true) else {throw AdapterFault("item_frame_exceeded")}
                    break
                }
                response=candidate
            }
            let end=offset+(response.reminders?.count ?? 0)
            response.next_offset=end<items.count ? end:nil
        case "get": response.reminder=try repository.get(id:a.reminder_id!,listID:a.list_id!)
        case "create":
            // Authority already checked this resolution before journal admission.
            guard let listID=a.list_id ?? authority.defaultListID else {throw AdapterFault("default_list_required")}
            response.reminder=try repository.create(listID:listID,title:a.title!,patch:a.patch ?? Patch(),beforeCommit:{try authority.check(request)})
        case "update": response.reminder=try repository.update(id:a.reminder_id!,listID:a.list_id!,revision:a.expected_revision!,patch:a.patch,completed:nil,beforeCommit:{try authority.check(request)})
        case "complete","uncomplete": response.reminder=try repository.update(id:a.reminder_id!,listID:a.list_id!,revision:a.expected_revision!,patch:nil,completed:request.operation == "complete",beforeCommit:{try authority.check(request)})
        case "delete":
            let deleted=try repository.delete(id:a.reminder_id!,listID:a.list_id!,revision:a.expected_revision!,beforeCommit:{try authority.check(request)})
            guard deleted.id==a.reminder_id,deleted.list_id==a.list_id,deleted.expected_revision==a.expected_revision else {throw AdapterFault("outcome_unknown")}
            response.deletion=deleted
        default: throw AdapterFault("unknown_tool")
        }
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        guard try encoder.encode(response).count <= 60_000 else { throw AdapterFault(request.isMutation ? "outcome_unknown" : "result_limit_exceeded") }
        return response
    }
}

/// Shared preflight is also used by the fixture. Unsupported fields may be left untouched but never replaced/cleared.
public func validatePatch(_ patch: Patch, existing: ReminderSnapshot) throws {
    try patch.validate()
    if let action=patch.recurrence?.action, action != .keep, !existing.recurrence.editable {throw AdapterFault("unsupported_recurrence_preserved")}
    if let action=patch.alert?.action, action != .keep, !existing.alerts.editable {throw AdapterFault("unsupported_alarm_preserved")}
    let start: Due? = patch.start?.action == .clear ? nil : (patch.start?.value ?? existing.start)
    if let r=patch.recurrence?.value {
        guard let start else {throw AdapterFault("recurrence_requires_start")}
        if let until=r.until {
            let components=try start.components();let calendar=components.calendar ?? Calendar(identifier:.gregorian)
            guard let date=calendar.date(from:components), try parseInstant(until) >= date else {throw AdapterFault("invalid_recurrence")}
        }
    }
    if patch.start?.action == .clear, !existing.recurrence.descriptors.isEmpty, patch.recurrence?.action != .clear {throw AdapterFault("recurrence_requires_start")}
    if let alarm=patch.alert?.value, alarm.kind == "relative", start?.kind != "date_time" {throw AdapterFault("relative_alarm_requires_timed_start")}
    let startChanged = patch.start?.action == .clear ? (existing.start != nil || !existing.start_components.isEmpty) : (patch.start?.action == .set && start != existing.start)
    if startChanged, patch.recurrence?.action == nil || patch.recurrence?.action == .keep, !existing.recurrence.descriptors.isEmpty {
        guard let start else {throw AdapterFault("recurrence_requires_start")}
        let c=try start.components();let calendar=c.calendar ?? Calendar(identifier:.gregorian)
        guard let date=calendar.date(from:c) else {throw AdapterFault("invalid_recurrence")}
        for rule in existing.recurrence.descriptors {
            let end:Date?
            if let raw=rule["until_reference_seconds"], raw != "null" {
                guard let seconds=Double(raw), seconds.isFinite else {throw AdapterFault("unsupported_recurrence_preserved")}
                end=Date(timeIntervalSinceReferenceDate:seconds)
            } else if let until=rule["until"], until != "null" {end=try parseInstant(until)} else {end=nil}
            if let end, date > end {throw AdapterFault("invalid_recurrence")}
        }
    }
    if startChanged, existing.alerts.descriptors.contains(where: {$0["kind"] == "relative"}), patch.alert?.action != .clear && patch.alert?.action != .set {
        throw AdapterFault(start?.kind == "date_time" ? "relative_alarm_requires_replacement" : "relative_alarm_requires_timed_start")
    }
}

/// Delete one non-repeating reminder only; never silently remove a recurrence.
public func validateDelete(_ existing:ReminderSnapshot,id:String,listID:String,revision:String) throws {
    guard existing.id==id,existing.list_id==listID else {throw AdapterFault("reminder_not_found")}
    guard existing.revision==revision else {throw AdapterFault("revision_conflict")}
    guard existing.recurrence.descriptors.isEmpty else {throw AdapterFault("recurring_delete_unsupported")}
}
