import AppKit
import EventKit
import Foundation
import Observation

@MainActor protocol CalendarBusinessBackend {
    var access: CalendarBusinessAccess { get }
    func calendars() throws -> [CalendarBusinessCalendar]
    func query(_ value: CalendarBusinessQuery) throws -> (events: [CalendarBusinessEvent], truncated: Bool)
    func get(_ target: CalendarBusinessTarget) throws -> CalendarBusinessEvent
    func prepare(_ request: CalendarBusinessRequest) throws -> CalendarBusinessClaim
    func commit(_ claim: CalendarBusinessClaim) throws -> CalendarBusinessOperation
}

/// The only EventKit business implementation. No permission request, UI,
/// transport, environment override or separate helper identity is used here.
@MainActor final class CalendarEventKitBackend: CalendarBusinessBackend {
    private let preferences: UserDefaults
    init(preferences: UserDefaults = .standard) { self.preferences = preferences }
    private func selectedDefault() throws -> EKCalendar {
        if let id=preferences.string(forKey:"calendarSelectedCalendarV1") { return try calendar(id) }
        guard let value=store.defaultCalendarForNewEvents else { throw CalendarBusinessFault("calendar_missing") }
        return value
    }
    private var cachedStore: EKEventStore?
    private var store: EKEventStore {
        if let cachedStore { return cachedStore }
        let value = EKEventStore(); cachedStore = value; return value
    }
    var access: CalendarBusinessAccess {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .notDetermined: .not_determined
        case .writeOnly: .write_only
        case .fullAccess: .full_access
        case .denied: .denied
        case .restricted: .restricted
        @unknown default: .unknown
        }
    }
    private func readAdmission() throws {
        guard access.canRead else { throw CalendarBusinessFault("needs_full_access") }
    }
    private func calendar(_ id: String) throws -> EKCalendar {
        guard let calendar = store.calendar(withIdentifier: id), calendar.allowedEntityTypes.contains(.event) else { throw CalendarBusinessFault("calendar_missing") }
        return calendar
    }
    private func row(_ calendar: EKCalendar) -> CalendarBusinessCalendar {
        .init(id: calendar.calendarIdentifier, title: calendar.title, source: calendar.source.title, writable: calendar.allowsContentModifications,
              is_default: store.defaultCalendarForNewEvents?.calendarIdentifier == calendar.calendarIdentifier,
              source_id:calendar.source.sourceIdentifier,source_type:calendar.source.sourceType.rawValue,
              subscribed:calendar.isSubscribed,source_is_delegate:calendar.source.isDelegate)
    }
    func calendars() throws -> [CalendarBusinessCalendar] {
        try readAdmission()
        return store.calendars(for: .event).map(row).sorted { ($0.source, $0.title, $0.id) < ($1.source, $1.title, $1.id) }
    }
    func query(_ value: CalendarBusinessQuery) throws -> (events: [CalendarBusinessEvent], truncated: Bool) {
        try value.validate(); try readAdmission()
        let calendars = try value.calendar_ids.map(calendar)
        let predicate = store.predicateForEvents(withStart: try CalendarBusinessContract.date(value.start), end: try CalendarBusinessContract.date(value.end), calendars: calendars)
        // Sort the authorized result before taking a resumable delivery page.
        var rows: [CalendarBusinessEvent] = []
        store.enumerateEvents(matching: predicate) { event, stop in
            rows.append(self.snapshot(event))
        }
        try readAdmission()
        rows.sort { ($0.draft.start,$0.id)<($1.draft.start,$1.id) }
        let offset=min(value.offset ?? 0,rows.count)
        var page:[CalendarBusinessEvent]=[]
        for item in rows.dropFirst(offset).prefix(value.limit) {
            if try CalendarBusinessContract.encode(page+[item]).count>24000 {
                guard !page.isEmpty else {throw CalendarBusinessFault("item_frame_exceeded")}
                break
            }
            page.append(item)
        }
        return (page,offset+page.count<rows.count)
    }
    private func event(_ target: CalendarBusinessTarget, revision: Bool = true) throws -> EKEvent {
        try target.validate(); try readAdmission()
        let cal = try calendar(target.calendar_id)
        let occurrence = try CalendarBusinessContract.date(target.occurrence_start)
        if let direct = store.event(withIdentifier: target.event_id), direct.calendar.calendarIdentifier == target.calendar_id,
           abs((direct.occurrenceDate ?? direct.startDate).timeIntervalSince(occurrence)) < 0.001 {
            guard direct.refresh() else { throw CalendarBusinessFault("event_missing_or_changed") }
            guard !revision || snapshot(direct).target.revision == target.revision else { throw CalendarBusinessFault("revision_changed") }
            return direct
        }
        // event(withIdentifier:) may return the series' first occurrence. Query
        // the exact original occurrence, never silently edit a series or neighbor.
        let predicate = store.predicateForEvents(withStart: occurrence.addingTimeInterval(-1), end: occurrence.addingTimeInterval(1), calendars: [cal])
        let matches = store.events(matching: predicate).filter {
            $0.eventIdentifier == target.event_id && abs(($0.occurrenceDate ?? $0.startDate).timeIntervalSince(occurrence)) < 0.001
        }
        guard matches.count == 1, let event = matches.first else { throw CalendarBusinessFault("event_missing_or_changed") }
        guard !revision || snapshot(event).target.revision == target.revision else { throw CalendarBusinessFault("revision_changed") }
        return event
    }
    func get(_ target: CalendarBusinessTarget) throws -> CalendarBusinessEvent { snapshot(try event(target)) }
    private func recurrence(_ event: EKEvent) -> (CalendarBusinessRecurrence?, Bool) {
        let rules = event.recurrenceRules ?? []
        guard !rules.isEmpty else { return (nil, true) }
        guard rules.count == 1, let r = rules.first,
              [r.daysOfTheWeek?.count ?? 0, r.daysOfTheMonth?.count ?? 0, r.monthsOfTheYear?.count ?? 0,
               r.weeksOfTheYear?.count ?? 0, r.daysOfTheYear?.count ?? 0, r.setPositions?.count ?? 0].allSatisfy({ $0 == 0 }) else { return (nil, false) }
        let frequency: CalendarBusinessFrequency
        switch r.frequency { case .daily: frequency = .daily; case .weekly: frequency = .weekly; case .monthly: frequency = .monthly; case .yearly: frequency = .yearly; @unknown default: return (nil, false) }
        let value = CalendarBusinessRecurrence(frequency: frequency, interval: r.interval,
            count: r.recurrenceEnd.flatMap { $0.occurrenceCount > 0 ? $0.occurrenceCount : nil },
            until: r.recurrenceEnd?.endDate.map(CalendarBusinessContract.string))
        return (value, (try? value.validate(start: event.startDate)) != nil)
    }
    private func snapshot(_ event: EKEvent) -> CalendarBusinessEvent {
        let (repeatRule, supported) = recurrence(event)
        let alarms = event.alarms ?? []
        let alarmsSupported = alarms.allSatisfy { $0.absoluteDate == nil && $0.structuredLocation == nil && $0.relativeOffset <= 0 && $0.relativeOffset >= -31 * 86400 && $0.relativeOffset.rounded() == $0.relativeOffset && $0.emailAddress == nil && $0.type == .display && $0.soundName == nil }
        let draft = CalendarBusinessDraft(calendar_id: event.calendar.calendarIdentifier, title: event.title ?? "", start: CalendarBusinessContract.string(event.startDate), end: CalendarBusinessContract.string(event.endDate),
            time_zone: (event.timeZone ?? TimeZone.current).identifier, all_day: event.isAllDay,
            alarm_seconds: alarmsSupported ? alarms.map { Int(-$0.relativeOffset) }.sorted() : [], recurrence: repeatRule)
        // Include fields deliberately not exposed by this editor in the revision
        // so concurrent external changes cannot be silently overwritten.
        let rulesFingerprint = (event.recurrenceRules ?? []).map(Self.ruleFingerprint).joined(separator: "\n")
        let alarmFingerprint = alarms.map(Self.alarmFingerprint).joined(separator: "\n")
        let extra = [event.calendarItemIdentifier, event.lastModifiedDate.map(CalendarBusinessContract.string) ?? "",
                     event.notes ?? "", event.location ?? "", event.url?.absoluteString ?? "", rulesFingerprint, alarmFingerprint]
        let revision = CalendarBusinessContract.hash((try! CalendarBusinessContract.encode(draft)) + (try! CalendarBusinessContract.encode(extra)))
        let target = CalendarBusinessTarget(calendar_id: event.calendar.calendarIdentifier, event_id: event.eventIdentifier ?? "", occurrence_start: CalendarBusinessContract.string(event.occurrenceDate ?? event.startDate), revision: revision)
        return .init(target: target, draft: draft, editable: event.calendar.allowsContentModifications && !event.hasAttendees && event.organizer == nil && supported && alarmsSupported,
                     recurrence_supported: supported, alarms_supported: alarmsSupported, repeating: event.hasRecurrenceRules || event.isDetached)
    }
    private static func ruleFingerprint(_ r: EKRecurrenceRule) -> String {
        let weekdays = (r.daysOfTheWeek ?? []).map { String($0.dayOfTheWeek.rawValue) + ":" + String($0.weekNumber) }.joined(separator: ",")
        let lists: [[NSNumber]?] = [r.daysOfTheMonth, r.monthsOfTheYear, r.weeksOfTheYear, r.daysOfTheYear, r.setPositions]
        let numbers = lists.map { ($0 ?? []).map(\.stringValue).joined(separator: ",") }.joined(separator: ";")
        let parts: [String] = [r.calendarIdentifier, String(r.frequency.rawValue), String(r.interval), String(r.firstDayOfTheWeek),
            weekdays, numbers, r.recurrenceEnd?.endDate.map(CalendarBusinessContract.string) ?? "", String(r.recurrenceEnd?.occurrenceCount ?? 0)]
        return parts.joined(separator: "|")
    }
    private static func alarmFingerprint(_ a: EKAlarm) -> String {
        var parts = [String(a.relativeOffset), a.absoluteDate.map(CalendarBusinessContract.string) ?? "", String(a.type.rawValue),
                     a.emailAddress ?? "", a.soundName ?? "", String(a.proximity.rawValue), a.structuredLocation?.title ?? ""]
        if let location = a.structuredLocation?.geoLocation {
            parts += [String(location.coordinate.latitude), String(location.coordinate.longitude)]
        }
        parts.append(String(a.structuredLocation?.radius ?? 0))
        return parts.joined(separator: "|")
    }
    func prepare(_ request: CalendarBusinessRequest) throws -> CalendarBusinessClaim {
        try request.validate()
        guard request.action.writes else { throw CalendarBusinessFault("invalid_arguments") }
        guard access.canCreate else { throw CalendarBusinessFault("needs_permission") }
        let selected: EKCalendar
        if request.action == .create {
            if access == .write_only {
                guard request.draft?.calendar_id == nil else { throw CalendarBusinessFault("write_only_default_only") }
                guard let value = store.defaultCalendarForNewEvents else { throw CalendarBusinessFault("calendar_missing") }; selected = value
            } else if let id = request.draft?.calendar_id { selected = try calendar(id) }
            else { selected = try selectedDefault() }
        } else {
            guard let target = request.target else { throw CalendarBusinessFault("invalid_arguments") }
            let current = snapshot(try event(target))
            guard request.action == .delete || current.editable else { throw CalendarBusinessFault("event_edit_unsupported") }
            if request.action == .update, current.repeating, !Self.sameRecurrence(request.draft?.recurrence,current.draft.recurrence) { throw CalendarBusinessFault("recurrence_scope_unsupported") }
            selected = try calendar(target.calendar_id)
        }
        guard selected.allowsContentModifications, selected.allowedEntityTypes.contains(.event) else { throw CalendarBusinessFault("calendar_read_only") }
        return .init(request: request, calendar: row(selected))
    }
    private static func sameRecurrence(_ a:CalendarBusinessRecurrence?,_ b:CalendarBusinessRecurrence?)->Bool {
        if a == nil || b == nil { return a == b }
        return a!.sameRule(as:b)
    }
    private func apply(_ draft: CalendarBusinessDraft, to event: EKEvent, setRecurrence: Bool) throws {
        event.title = draft.title; event.startDate = try CalendarBusinessContract.date(draft.start); event.endDate = try CalendarBusinessContract.date(draft.end)
        event.timeZone = TimeZone(identifier: draft.time_zone); event.isAllDay = draft.all_day
        event.alarms = draft.alarm_seconds.map { EKAlarm(relativeOffset: -Double($0)) }
        if setRecurrence {
            event.recurrenceRules = nil
            if let r = draft.recurrence {
                let frequency: EKRecurrenceFrequency = switch r.frequency { case .daily: .daily; case .weekly: .weekly; case .monthly: .monthly; case .yearly: .yearly }
                let end: EKRecurrenceEnd?
                if let count = r.count { end = EKRecurrenceEnd(occurrenceCount: count) }
                else if let until = r.until { end = EKRecurrenceEnd(end: try CalendarBusinessContract.date(until)) }
                else { end = nil }
                event.recurrenceRules = [EKRecurrenceRule(recurrenceWith: frequency, interval: r.interval, end: end)]
            }
        }
    }
    func commit(_ claim: CalendarBusinessClaim) throws -> CalendarBusinessOperation {
        // Revalidate permission, default calendar and revision after approval and
        // durable claim. A changed target never falls back to another calendar.
        guard try prepare(claim.request) == claim else { throw CalendarBusinessFault("target_changed") }
        let request = claim.request
        let event: EKEvent
        if request.action == .create {
            event = EKEvent(eventStore: store)
            if request.draft?.calendar_id == nil {
                let current = access == .write_only ? store.defaultCalendarForNewEvents : try selectedDefault()
                guard let current,current.calendarIdentifier == claim.calendar.id else { throw CalendarBusinessFault("target_changed") }
                event.calendar = current
            } else { event.calendar = try calendar(claim.calendar.id) }
        }
        else { event = try self.event(request.target!) }
        if request.action == .delete {
            try store.remove(event, span: .thisEvent, commit: true)
            // Result resolution is local only; any ambiguous readback is unknown.
            try readAdmission()
            let target=request.target!,calendar=try calendar(request.target!.calendar_id)
            let occurrence=try CalendarBusinessContract.date(target.occurrence_start)
            let predicate=store.predicateForEvents(withStart:occurrence.addingTimeInterval(-1),end:occurrence.addingTimeInterval(1),calendars:[calendar])
            let remaining=store.events(matching:predicate).filter {
                $0.eventIdentifier==target.event_id && abs(($0.occurrenceDate ?? $0.startDate).timeIntervalSince(occurrence))<0.001
            }
            try readAdmission()
            guard remaining.isEmpty else{throw CalendarBusinessFault("readback_mismatch")}
            return .init(task_id: request.task_id, digest: request.digest, action: request.action, state: .deleted_local, code: "deleted_local", event: nil)
        }
        let wasRepeating = event.hasRecurrenceRules || event.isDetached
        try apply(request.draft!, to: event, setRecurrence: request.action == .create || !wasRepeating)
        try store.save(event, span: .thisEvent, commit: true)
        guard access.canRead else {
            return .init(task_id: request.task_id, digest: request.digest, action: request.action, state: .saved_unreadable, code: "saved_without_readback", event: nil)
        }
        let saved = snapshot(event)
        let actual = snapshot(try self.event(saved.target, revision: false))
        let expected = request.draft!
        guard actual.draft.title == expected.title, actual.draft.calendar_id == claim.calendar.id,
              actual.draft.start == CalendarBusinessContract.string(try CalendarBusinessContract.date(expected.start)),
              actual.draft.end == CalendarBusinessContract.string(try CalendarBusinessContract.date(expected.end)),
              actual.draft.all_day == expected.all_day, actual.draft.time_zone == expected.time_zone,
              actual.draft.alarm_seconds == expected.alarm_seconds.sorted(), actual.alarms_supported,
              wasRepeating || Self.sameRecurrence(actual.draft.recurrence,expected.recurrence) else { throw CalendarBusinessFault("readback_mismatch") }
        return .init(task_id: request.task_id, digest: request.digest, action: request.action, state: .saved_local, code: "saved_and_read_back", event: actual)
    }
}

/// Shared owner supplies its existing identity, durable tasks and business log.
/// There is deliberately no in-memory/default journal or implicit consent port.
@MainActor final class CalendarBusinessHandler {
    struct Port {
        let verify: () throws -> Void
        let lookup: (String) async throws -> CalendarBusinessOperation?
        let approve: (CalendarBusinessClaim) async throws -> Bool
        // Atomic O_EXCL/locked + fsynced claim. Same task ID never overwrites a
        // previous request. An unresolved attempt must not be silently retried.
        let claim: (CalendarBusinessClaim) async throws -> Void
        let finish: (CalendarBusinessOperation) async throws -> Void
        let record: (CalendarBusinessRequest, CalendarBusinessReply?) async throws -> Void
    }
    private let backend: any CalendarBusinessBackend
    private let port: Port
    private(set) var busy = false
    private(set) var businessLogAvailable = true
    private var held = false
    init(backend: any CalendarBusinessBackend, port: Port) { self.backend = backend; self.port = port }
    func suspendForExit() { held = true }
    func resumeAfterCancelledExit() { held = false }
    func execute(tool: String, argumentsJSON: Data) async throws -> CalendarBusinessReply {
        let request: CalendarBusinessRequest
        do { request = try CalendarBusinessRequest.decode(tool: tool, argumentsJSON: argumentsJSON) }
        catch {
            // Invalid wire input never reaches task lookup or durable admission.
            throw CalendarBusinessFault((error as? CalendarBusinessFault)?.code ?? "invalid_arguments", consumed: false)
        }
        return try await execute(request)
    }
    func execute(_ request: CalendarBusinessRequest) async throws -> CalendarBusinessReply {
        try request.validate(); try port.verify(); try Task.checkCancellation()
        guard !held, !busy else { throw CalendarBusinessFault("owner_busy") }
        busy = true; defer { busy = false }
        businessLogAvailable = true
        var reply = CalendarBusinessReply(task_id: request.task_id, access: backend.access, code: "ok")
        // A failed original-task lookup cannot prove that no prior claim exists.
        var claimMayExist = request.action.writes
        await record(request, nil)
        do {
            if request.action == .operation_status || request.action.writes {
                if let existing = try await port.lookup(request.task_id) {
                    guard existing.task_id == request.task_id,
                          request.action == .operation_status || existing.digest == request.digest else { throw CalendarBusinessFault("task_changed") }
                    reply.operation = existing
                } else if request.action == .operation_status { reply = .init(task_id: request.task_id, access: backend.access, code: "task_not_found") }
                else { claimMayExist = false }
            }
            if reply.operation == nil, request.action != .operation_status {
                try Task.checkCancellation();try port.verify()
                guard !held else { throw CalendarBusinessFault("owner_busy") }
                switch request.action {
                case .calendars: reply.calendars = try backend.calendars()
                case .query:
                    let value = try backend.query(request.query!); reply.events = value.events; reply.truncated = value.truncated
                    reply.next_offset = value.truncated ? (request.query!.offset ?? 0) + value.events.count:nil
                case .get: reply.events = [try backend.get(request.target!)]
                case .create, .update, .delete:
                    let claim = try backend.prepare(request)
                    guard try await port.approve(claim) else { throw CalendarBusinessFault("user_cancelled") }
                    try Task.checkCancellation(); try port.verify()
                    guard !held, try backend.prepare(request) == claim else { throw CalendarBusinessFault("target_changed") }
                    // A status call/repeated task can only observe; it never resumes
                    // a claim. No await occurs between the durable claim and effect
                    // admission except the claim itself, which is rechecked below.
                    // Claim failure can itself leave a partial durable intent.
                    claimMayExist = true
                    try await port.claim(claim)
                    let operation: CalendarBusinessOperation
                    do {
                        try Task.checkCancellation(); try port.verify()
                        guard !held else { throw CalendarBusinessFault("owner_busy") }
                        operation = try backend.commit(claim)
                    } catch {
                        operation = .init(task_id: request.task_id, digest: request.digest, action: request.action, state: .outcome_unknown, code: "outcome_unknown", event: nil)
                    }
                    // Failed finalization leaves the durable attempting marker. It
                    // never converts an uncertain save to an available fresh task.
                    try await port.finish(operation); reply.operation = operation
                case .operation_status: break
                }
            }
            reply.businessLogAvailable = businessLogAvailable
            await record(request, reply)
            reply.businessLogAvailable = businessLogAvailable
            return reply
        } catch {
            // Optional logging must preserve both the original business fault
            // and the mandatory claim/finish outcome. Never retry either here.
            let code = (error as? CalendarBusinessFault)?.code ?? (error is CancellationError ? "cancelled" : "owner_unavailable")
            var failure = CalendarBusinessReply(task_id: request.task_id, access: backend.access, code: code)
            failure.businessLogAvailable = businessLogAvailable
            await record(request, failure)
            if var fault = error as? CalendarBusinessFault {
                fault.consumed = claimMayExist; throw fault
            }
            if error is CancellationError { throw CalendarBusinessFault(code, consumed: claimMayExist) }
            throw error
        }
    }
    private func record(_ request: CalendarBusinessRequest, _ reply: CalendarBusinessReply?) async {
        do { try await port.record(request, reply) }
        catch { businessLogAvailable = false }
    }
}

@MainActor @Observable final class CalendarBusinessController {
    let permission: CalendarPermissionController
    private let handler: CalendarBusinessHandler
    private let preferences: UserDefaults
    private(set) var calendars: [CalendarBusinessCalendar] = []
    private(set) var events: [CalendarBusinessEvent] = []
    private(set) var selectedCalendarID: String?
    private(set) var selectedEvent: CalendarBusinessEvent?
    private(set) var operation: CalendarBusinessOperation?
    private(set) var observedAt: Date?
    private(set) var busy = false
    private(set) var held = false
    private(set) var message: String?
    private(set) var truncated = false
    private(set) var businessLogAvailable=true
    private(set) var archivedTaskIDs:[String]=[]
    private(set) var currentTaskID: String?
    private(set) var displayedQuery: CalendarBusinessQuery?
    init(permission: CalendarPermissionController, handler: CalendarBusinessHandler, preferences: UserDefaults = .standard) {
        self.permission = permission; self.handler = handler; self.preferences = preferences
        selectedCalendarID = preferences.string(forKey: "calendarSelectedCalendarV1")
        currentTaskID = preferences.string(forKey: "calendarCurrentTaskV1")
        archivedTaskIDs=(preferences.stringArray(forKey:"calendarArchivedTasksV1") ?? []).filter{UUID(uuidString:$0)?.uuidString.lowercased()==$0}
    }
    var canAct: Bool { permission.canAct && !busy && !held }
    var canRead: Bool { canAct && permission.state == .fullAccess }
    // A stale event selection or an empty result card never hides default creation.
    var offersDefaultCreate: Bool { permission.state == .writeOnly }
    func suspendForExit() { held = true; handler.suspendForExit() }
    func resumeAfterCancelledExit() { held = false; handler.resumeAfterCancelledExit() }
    func selectCalendar(_ id: String?) {
        guard !busy, !unresolved else { return }
        selectedCalendarID = id; selectedEvent = nil
        preferences.set(id, forKey: "calendarSelectedCalendarV1")
    }
    var unresolved: Bool { currentTaskID != nil && (operation == nil || operation?.state == .attempting || operation?.state == .outcome_unknown) }
    func selectEvent(_ event: CalendarBusinessEvent?) {
        guard !busy, !unresolved else { return }
        selectedEvent = event; operation = nil; currentTaskID = nil
        preferences.removeObject(forKey:"calendarCurrentTaskV1")
    }
    func prepareForDisplay() async {
        permission.refresh()
        if let currentTaskID { await status(taskID:currentTaskID) }
        await loadCalendars()
    }
    @discardableResult private func run(_ request: CalendarBusinessRequest) async -> CalendarBusinessReply? {
        guard canAct else { return nil }
        busy = true; defer { busy = false }
        if request.action.writes {
            if currentTaskID != request.task_id { operation=nil }
            currentTaskID=request.task_id;preferences.set(request.task_id,forKey:"calendarCurrentTaskV1")
        }
        do {
            let reply = try await handler.execute(request)
            businessLogAvailable=reply.businessLogAvailable
            if reply.code == "task_not_found" {
                currentTaskID=nil;operation=nil;preferences.removeObject(forKey:"calendarCurrentTaskV1")
                message="原记录未开始，可继续编辑。"
            }
            operation = reply.operation ?? operation
            if let result = reply.operation {
                message = switch result.state {
                case .attempting, .outcome_unknown: "结果待核，请查看原记录。"
                case .saved_local: "已保存并回读，云同步待核。"
                case .saved_unreadable: "已保存，当前权限无法回读。"
                case .deleted_local: "已删除本次日程。"
                }
                if let event = result.event { selectedEvent = event }
                if result.state == .deleted_local { selectedEvent = nil }
            }
            return reply
        } catch {
            businessLogAvailable = handler.businessLogAvailable
            let code = (error as? CalendarBusinessFault)?.code ?? "owner_unavailable"
            if request.action.writes {
                // Resolve the same durable ID after preflight/cancel/log failures.
                // This status read cannot repeat or resume a business effect.
                if let status = try? await handler.execute(.init(taskID:request.task_id,action:.operation_status)) {
                    if status.code == "task_not_found" {
                        currentTaskID=nil;operation=nil;preferences.removeObject(forKey:"calendarCurrentTaskV1")
                    } else { operation=status.operation ?? operation }
                }
            }
            message = switch code {
            case "needs_full_access": "查看日程需要读写权限。"
            case "revision_changed", "event_missing_or_changed", "target_changed": "日程已变化，请重新查看。"
            case "user_cancelled": "已取消本次操作。"
            case "event_edit_unsupported": "此日程暂不支持编辑。"
            case "recurrence_scope_unsupported": "重复日程仅支持修改本次。"
            case "task_changed": "原记录内容不同，请先核对。"
            default: unresolved ? "结果待核，请查看原记录。":"操作未完成，请稍后再试。"
            }
            return nil
        }
    }
    func loadCalendars() async {
        guard canRead else { return }
        if let reply = await run(.init(taskID: UUID().uuidString.lowercased(), action: .calendars)) {
            calendars = reply.calendars; observedAt = Date()
            // Keep a removed selection visible until the user chooses again.
            if selectedCalendarID == nil { selectCalendar(calendars.first(where: \.is_default)?.id) }
        }
    }
    func query(start: Date, end: Date) async {
        guard canRead, let id = selectedCalendarID else { return }
        let query = CalendarBusinessQuery(start: CalendarBusinessContract.string(start), end: CalendarBusinessContract.string(end), calendar_ids: [id], limit: 100)
        if let reply = await run(.init(taskID: UUID().uuidString.lowercased(), action: .query, query: query)) {
            events = reply.events; truncated = reply.truncated; observedAt = Date(); displayedQuery=query
        }
    }
    func save(_ draft: CalendarBusinessDraft, taskID: String) async {
        guard !unresolved || currentTaskID == taskID else { return }
        let request = CalendarBusinessRequest(taskID: taskID, action: selectedEvent == nil ? .create : .update, target: selectedEvent?.target, draft: draft)
        _ = await run(request)
    }
    func delete(taskID: String) async {
        guard !unresolved || currentTaskID == taskID else { return }
        guard let selectedEvent else { return }
        _ = await run(.init(taskID: taskID, action: .delete, target: selectedEvent.target))
    }
    func startNewIntent() {
        guard !busy else{return}
        if unresolved,let id=currentTaskID,!archivedTaskIDs.contains(id) {
            archivedTaskIDs.append(id);preferences.set(archivedTaskIDs,forKey:"calendarArchivedTasksV1")
        }
        currentTaskID=nil;operation=nil;selectedEvent=nil
        preferences.removeObject(forKey:"calendarCurrentTaskV1")
    }
    func status(taskID: String) async {
        guard !busy else{return}
        if currentTaskID != taskID {startNewIntent();currentTaskID=taskID;preferences.set(taskID,forKey:"calendarCurrentTaskV1")}
        _ = await run(.init(taskID: taskID, action: .operation_status))
    }
}
