import Foundation
import CryptoKit

// Frozen v1 domain contract. Compile this and CalendarBusinessController into
// the authenticated ARL owner; both native UI and Mio call the same handler.
// Permission is an observation, never an execution grant or a cached admission.
enum CalendarBusinessAccess: String, Codable, Sendable {
    case not_determined, write_only, full_access, denied, restricted, unknown
    var canRead: Bool { self == .full_access }
    var canCreate: Bool { self == .write_only || self == .full_access }
}
struct CalendarBusinessFault: Error, Sendable {
    let code: String
    // Handler-owned evidence only. nil preserves the owner's conservative
    // fallback when original intent/claim state could not be established.
    var consumed: Bool?
    init(_ code: String, consumed: Bool? = nil) { self.code = code; self.consumed = consumed }
}
struct CalendarBusinessCalendar: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let source: String
    let writable: Bool
    let is_default: Bool
    var source_id:String?=nil
    var source_type:Int?=nil
    var subscribed:Bool?=nil
    var source_is_delegate:Bool?=nil
}
enum CalendarBusinessFrequency: String, Codable, CaseIterable, Sendable {
    case daily, weekly, monthly, yearly
    var title: String {
        switch self { case .daily: "每天"; case .weekly: "每周"; case .monthly: "每月"; case .yearly: "每年" }
    }
}
struct CalendarBusinessRecurrence: Codable, Equatable, Sendable {
    let frequency: CalendarBusinessFrequency
    let interval: Int
    let count: Int?
    let until: String?
    func sameRule(as other: Self?) -> Bool {
        guard let other, frequency == other.frequency, interval == other.interval, count == other.count else { return false }
        if until == nil || other.until == nil { return until == other.until }
        return (try? CalendarBusinessContract.date(until!)) == (try? CalendarBusinessContract.date(other.until!))
    }
    func validate(start: Date) throws {
        guard (1...99).contains(interval), count == nil || until == nil,
              count.map({ (1...999).contains($0) }) ?? true else { throw CalendarBusinessFault("invalid_recurrence") }
        if let until { guard try CalendarBusinessContract.date(until) >= start else { throw CalendarBusinessFault("invalid_recurrence") } }
    }
}
struct CalendarBusinessDraft: Codable, Equatable, Sendable {
    // nil means the current default, bound to its exact ID before confirmation.
    let calendar_id: String?
    let title: String
    let start: String
    let end: String
    let time_zone: String
    let all_day: Bool
    // Relative seconds before the event; nil/[] means no reminder. No location
    // alarms, emails, URLs, attachments, attendees or invitations are accepted.
    let alarm_seconds: [Int]
    let recurrence: CalendarBusinessRecurrence?
    func validate() throws {
        if let calendar_id { try CalendarBusinessContract.identifier(calendar_id) }
        try CalendarBusinessContract.text(title, limit: 300)
        let a = try CalendarBusinessContract.date(start), b = try CalendarBusinessContract.date(end)
        guard b > a, b.timeIntervalSince(a) <= 31 * 86400, let zone = TimeZone(identifier: time_zone),
              alarm_seconds.count <= 5, Set(alarm_seconds).count == alarm_seconds.count,
              alarm_seconds.allSatisfy({ (0...31 * 86400).contains($0) }) else { throw CalendarBusinessFault("invalid_draft") }
        if all_day {
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
            guard calendar.startOfDay(for: a) == a, calendar.startOfDay(for: b) == b else { throw CalendarBusinessFault("invalid_all_day") }
        }
        try recurrence?.validate(start: a)
    }
}
struct CalendarBusinessTarget: Codable, Equatable, Sendable {
    let calendar_id: String
    let event_id: String
    let occurrence_start: String
    let revision: String
    func validate() throws {
        try CalendarBusinessContract.identifier(calendar_id); try CalendarBusinessContract.identifier(event_id)
        _ = try CalendarBusinessContract.date(occurrence_start)
        guard revision.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { throw CalendarBusinessFault("invalid_revision") }
    }
}
struct CalendarBusinessEvent: Codable, Equatable, Identifiable, Sendable {
    let target: CalendarBusinessTarget
    let draft: CalendarBusinessDraft
    let editable: Bool
    let recurrence_supported: Bool
    let alarms_supported: Bool
    let repeating: Bool
    var id: String { target.event_id + "@" + target.occurrence_start }
}
struct CalendarBusinessQuery: Codable, Equatable, Sendable {
    let start: String
    let end: String
    let calendar_ids: [String]
    let limit: Int
    var offset: Int? = nil
    func validate() throws {
        let a = try CalendarBusinessContract.date(start), b = try CalendarBusinessContract.date(end)
        guard (offset ?? 0)>=0,b > a, b.timeIntervalSince(a) <= 366 * 86400, (1...500).contains(limit),
              !calendar_ids.isEmpty, calendar_ids.count <= 50, Set(calendar_ids).count == calendar_ids.count else { throw CalendarBusinessFault("invalid_range") }
        for id in calendar_ids { try CalendarBusinessContract.identifier(id) }
    }
}
enum CalendarBusinessAction: String, Codable, Sendable {
    case calendars, query, get, create, update, delete, operation_status
    var writes: Bool { [.create, .update, .delete].contains(self) }
    var tool: String { "mio_calendar_" + rawValue }
}
struct CalendarBusinessRequest: Codable, Equatable, Sendable {
    let task_id: String
    let action: CalendarBusinessAction
    let query: CalendarBusinessQuery?
    let target: CalendarBusinessTarget?
    let draft: CalendarBusinessDraft?
    init(taskID: String, action: CalendarBusinessAction, query: CalendarBusinessQuery? = nil,
         target: CalendarBusinessTarget? = nil, draft: CalendarBusinessDraft? = nil) {
        task_id = taskID; self.action = action; self.query = query; self.target = target; self.draft = draft
    }
    func validate() throws {
        guard let id = UUID(uuidString: task_id), id.uuidString.lowercased() == task_id else { throw CalendarBusinessFault("invalid_task_id") }
        let has = [query != nil, target != nil, draft != nil]
        let expected: [Bool] = switch action {
        case .calendars, .operation_status: [false,false,false]
        case .query: [true,false,false]
        case .get, .delete: [false,true,false]
        case .create: [false,false,true]
        case .update: [false,true,true]
        }
        guard has == expected else { throw CalendarBusinessFault("invalid_arguments") }
        try query?.validate(); try target?.validate(); try draft?.validate()
        if action == .update, draft?.calendar_id != target?.calendar_id { throw CalendarBusinessFault("calendar_move_unsupported") }
    }
    var digest: String { CalendarBusinessContract.hash(try! CalendarBusinessContract.encode(self)) }
    // JSONDecoder alone ignores extra fields. Round-trip every nested object to
    // reject invitees, unknown keys, null optional values and lossy JSON types.
    static func decode(tool: String, argumentsJSON: Data) throws -> Self {
        try CalendarBusinessContract.uniqueKeys(argumentsJSON)
        guard argumentsJSON.count <= 32_768, let action = CalendarBusinessAction(rawValue: String(tool.dropFirst("mio_calendar_".count))),
              action.tool == tool, let object = try JSONSerialization.jsonObject(with: argumentsJSON) as? [String: Any] else { throw CalendarBusinessFault("invalid_arguments") }
        var internalObject = object
        guard internalObject["action"] == nil else { throw CalendarBusinessFault("invalid_arguments") }
        internalObject["action"] = action.rawValue
        let data = try JSONSerialization.data(withJSONObject: internalObject)
        let result = try JSONDecoder().decode(Self.self, from: data)
        let canonical = try JSONSerialization.jsonObject(with: CalendarBusinessContract.encode(result))
        guard (internalObject as NSDictionary).isEqual(canonical) else { throw CalendarBusinessFault("invalid_arguments") }
        try result.validate(); return result
    }
    func argumentsJSON() throws -> Data {
        var value = try JSONSerialization.jsonObject(with: CalendarBusinessContract.encode(self)) as! [String: Any]
        value.removeValue(forKey: "action")
        return try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }
}
enum CalendarBusinessOperationState: String, Codable, Sendable {
    case attempting, saved_local, saved_unreadable, deleted_local, outcome_unknown
}
struct CalendarBusinessOperation: Codable, Equatable, Sendable {
    let task_id: String
    let digest: String
    let action: CalendarBusinessAction
    let state: CalendarBusinessOperationState
    let code: String
    let event: CalendarBusinessEvent?
    // No implicit retries or cloud-sync claims. This record survives app exit.
    var automatic_replay: Bool = false
}
struct CalendarBusinessClaim: Codable, Equatable, Sendable {
    let request: CalendarBusinessRequest
    let calendar: CalendarBusinessCalendar
    var digest: String { CalendarBusinessContract.hash(try! CalendarBusinessContract.encode(self)) }
}
struct CalendarBusinessReply: Codable, Sendable {
    var schema_version: Int = 1
    let task_id: String
    let access: CalendarBusinessAccess
    let code: String
    var calendars: [CalendarBusinessCalendar] = []
    var events: [CalendarBusinessEvent] = []
    var truncated: Bool = false
    var next_offset: Int? = nil
    var operation: CalendarBusinessOperation?
    var cloud_sync: String = "not_checked"
    var businessLogAvailable:Bool = true
}
enum CalendarBusinessContract {
    static func uniqueKeys(_ data: Data) throws {
        guard data.count <= 32_768,
              (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
            throw CalendarBusinessFault("invalid_arguments")
        }
        let b = Array(data); var i = 0; var depth = 0; var objects: [Set<String>] = []
        func whitespace(_ byte: UInt8) -> Bool { [9, 10, 13, 32].contains(byte) }
        while i < b.count {
            switch b[i] {
            case 123: depth += 1; objects.append([]); i += 1
            case 91: depth += 1; i += 1
            case 125: depth -= 1; guard !objects.isEmpty else { throw CalendarBusinessFault("invalid_arguments") }; objects.removeLast(); i += 1
            case 93: depth -= 1; i += 1
            case 34:
                let start = i; i += 1; var escaped = false; var ended = false
                while i < b.count {
                    let byte = b[i]; i += 1
                    if escaped { escaped = false; continue }
                    if byte == 92 { escaped = true; continue }
                    if byte == 34 { ended = true; break }
                }
                guard ended else { throw CalendarBusinessFault("invalid_arguments") }
                var next = i; while next < b.count && whitespace(b[next]) { next += 1 }
                if next < b.count && b[next] == 58 {
                    guard !objects.isEmpty,
                          let key = try JSONSerialization.jsonObject(with: Data(b[start..<i]), options: .fragmentsAllowed) as? String,
                          objects[objects.count - 1].insert(key).inserted else {
                        throw CalendarBusinessFault("duplicate_product_key")
                    }
                }
            default: i += 1
            }
            guard depth >= 0 && depth <= 32 else { throw CalendarBusinessFault("invalid_arguments") }
        }
        guard depth == 0 && objects.isEmpty else { throw CalendarBusinessFault("invalid_arguments") }
    }

    static func identifier(_ value: String) throws {
        guard !value.isEmpty, value.utf8.count <= 2048, !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw CalendarBusinessFault("invalid_target") }
    }
    static func text(_ value: String, limit: Int) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.unicodeScalars.count <= limit,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw CalendarBusinessFault("invalid_text") }
    }
    static func date(_ value: String) throws -> Date {
        guard value.count <= 40, value.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]{1,6})?(?:Z|[+-][0-9]{2}:[0-9]{2})$"#, options: .regularExpression) != nil else { throw CalendarBusinessFault("invalid_date") }
        let f = ISO8601DateFormatter(); f.formatOptions = value.contains(".") ? [.withInternetDateTime,.withFractionalSeconds] : [.withInternetDateTime]
        guard let date = f.date(from: value) else { throw CalendarBusinessFault("invalid_date") }
        // ISO8601DateFormatter normalizes nonexistent days (e.g. February 30).
        let prefix = String(value.prefix(19)), components = prefix.split(whereSeparator: { "-T:".contains($0) }).compactMap { Int($0) }
        guard components.count == 6, (0...23).contains(components[3]), (0...59).contains(components[4]), (0...59).contains(components[5]) else { throw CalendarBusinessFault("invalid_date") }
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(secondsFromGMT: 0)!
        let local = DateComponents(year: components[0], month: components[1], day: components[2], hour: components[3], minute: components[4], second: components[5])
        guard let parsed = c.date(from: local), c.dateComponents([.year,.month,.day,.hour,.minute,.second], from: parsed) == local else { throw CalendarBusinessFault("invalid_date") }
        return date
    }
    static func string(_ date: Date) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime,.withFractionalSeconds]; return f.string(from: date)
    }
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys,.withoutEscapingSlashes]; return try e.encode(value)
    }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
