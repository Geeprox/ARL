import Foundation
import CryptoKit

public struct AdapterFault: Error, Equatable, Codable {
    public let code: String
    public init(_ code: String) { self.code = code }
}
public func digest<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    return SHA256.hash(data: try encoder.encode(value)).map { String(format: "%02x", $0) }.joined()
}
public struct Change<Value: Codable & Equatable>: Codable, Equatable {
    public enum Action: String, Codable { case keep, clear, set }
    public var action: Action
    public var value: Value?
    public init(_ action: Action = .keep, _ value: Value? = nil) { self.action = action; self.value = value }
    public func validate() throws {
        guard (action == .set) == (value != nil) else { throw AdapterFault("invalid_arguments") }
    }
}
public struct Due: Codable, Equatable {
    public var kind: String
    public var value: String
    public var time_zone: String?
    public init(kind: String, value: String, timeZone: String? = nil) { self.kind = kind; self.value = value; time_zone = timeZone }
    public func components() throws -> DateComponents {
        var calendar = Calendar(identifier: .gregorian)
        if kind == "date" {
            guard time_zone == nil, value.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { throw AdapterFault("invalid_due") }
            let parts = value.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3, (1...9999).contains(parts[0]) else { throw AdapterFault("invalid_due") }
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            var c = DateComponents(year: parts[0], month: parts[1], day: parts[2])
            guard let date = calendar.date(from: c), calendar.dateComponents([.year,.month,.day], from: date) == c else { throw AdapterFault("invalid_due") }
            c.calendar = calendar
            return c
        }
        guard kind == "date_time", let zone = time_zone, let tz = TimeZone(identifier: zone) else { throw AdapterFault("invalid_due") }
        let instant = try parseInstant(value)
        calendar.timeZone = tz
        var c = calendar.dateComponents([.year,.month,.day,.hour,.minute,.second], from: instant)
        c.calendar = calendar; c.timeZone = tz
        // EventKit stores civil components, which cannot disambiguate a fall-back fold.
        // Reject ambiguous wall times instead of silently selecting another occurrence.
        let searchStart = instant.addingTimeInterval(-172800)
        let first = calendar.nextDate(after: searchStart, matching: c, matchingPolicy: .strict, repeatedTimePolicy: .first)
        let last = calendar.nextDate(after: searchStart, matching: c, matchingPolicy: .strict, repeatedTimePolicy: .last)
        guard first == last else { throw AdapterFault("ambiguous_local_time") }
        return c
    }
}
public func parseInstant(_ text: String) throws -> Date {
    guard text.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(Z|[+-]\d{2}:\d{2})$"#, options: .regularExpression) != nil else { throw AdapterFault("invalid_timestamp") }
    // DateFormatter is lenient about some invalid civil dates, so round-trip the civil components in the supplied offset.
    let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian); formatter.isLenient = false
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXXXX"
    guard let date = formatter.date(from: text) else { throw AdapterFault("invalid_timestamp") }
    let suffix = String(text.suffix(6)); let tz: TimeZone?
    if text.hasSuffix("Z") { tz = TimeZone(secondsFromGMT: 0) }
    else {
        let hours = Int(suffix.dropFirst().prefix(2)) ?? 99, mins = Int(suffix.suffix(2)) ?? 99
        guard hours <= 14, mins < 60, hours != 14 || mins == 0 else { throw AdapterFault("invalid_timestamp") }
        tz = TimeZone(secondsFromGMT: (suffix.first == "-" ? -1 : 1) * (hours * 3600 + mins * 60))
    }
    formatter.timeZone = tz
    guard String(formatter.string(from: date).prefix(19)) == String(text.prefix(19)) else { throw AdapterFault("invalid_timestamp") }
    return date
}
public func instantString(_ date: Date) -> String {
    let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f.string(from: date)
}
public struct Recurrence: Codable, Equatable {
    public var frequency: String; public var interval: Int; public var count: Int?; public var until: String?
    public init(frequency: String, interval: Int = 1, count: Int? = nil, until: String? = nil) { self.frequency = frequency; self.interval = interval; self.count = count; self.until = until }
    public func validate() throws {
        guard ["daily","weekly","monthly","yearly"].contains(frequency), (1...999).contains(interval), count == nil || until == nil,
              count.map({ (1...9999).contains($0) }) ?? true else { throw AdapterFault("invalid_recurrence") }
        if let until { _ = try parseInstant(until) }
    }
}
public struct Alarm: Codable, Equatable {
    public var kind: String; public var at: String?; public var offset_seconds: Double?
    public init(kind: String, at: String? = nil, offset: Double? = nil) { self.kind = kind; self.at = at; offset_seconds = offset }
    public func validate() throws {
        if kind == "absolute", let at, offset_seconds == nil { _ = try parseInstant(at); return }
        if kind == "relative", at == nil, let v = offset_seconds, v.isFinite, abs(v) <= 31_536_000 { return }
        throw AdapterFault("invalid_alarm")
    }
}
/// Optional native due-date predicate. It narrows time scope, not maximum matching cardinality.
public struct DueWindow: Codable, Equatable {
    public let start: String
    public let end: String
    public func bounds() throws -> (Date,Date) {
        let a=try parseInstant(start), b=try parseInstant(end)
        guard b > a, b.timeIntervalSince(a) <= 366 * 86400 else {throw AdapterFault("invalid_query_window")}
        return (a,b)
    }
    public func contains(_ due:Due?) throws -> Bool {
        guard let due else {return false}
        let c=try due.components(), cal=c.calendar ?? Calendar(identifier:.gregorian)
        guard let date=cal.date(from:c) else {return false}
        let (a,b)=try bounds();return date >= a && date <= b
    }
}
public struct Patch: Codable, Equatable {
    public var title: Change<String>?; public var notes: Change<String>?; public var priority: Change<Int>?
    public var due: Change<Due>?; public var start: Change<Due>?
    public var recurrence: Change<Recurrence>?; public var alert: Change<Alarm>?
    public init() {}
    public var isEmpty: Bool { [title?.action.rawValue,notes?.action.rawValue,priority?.action.rawValue,due?.action.rawValue,start?.action.rawValue,recurrence?.action.rawValue,alert?.action.rawValue].allSatisfy { $0 == nil || $0 == "keep" } }
    public func validate() throws {
        try title?.validate(); try notes?.validate(); try priority?.validate(); try due?.validate(); try start?.validate(); try recurrence?.validate(); try alert?.validate()
        guard title?.action != .clear, priority?.action != .clear else { throw AdapterFault("invalid_arguments") }
        if let v = title?.value { try validateTitle(v) }
        if let v = notes?.value { guard v.utf8.count <= 4096, !v.contains("\0") else { throw AdapterFault("invalid_arguments") } }
        if let v = priority?.value { guard (0...9).contains(v) else { throw AdapterFault("invalid_arguments") } }
        _ = try due?.value?.components(); _ = try start?.value?.components()
        try recurrence?.value?.validate(); try alert?.value?.validate()
    }
}
public func validateTitle(_ title: String) throws {
    guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.unicodeScalars.count <= 300,
          !title.unicodeScalars.contains(where: { $0.value < 32 || (127...159).contains($0.value) }) else { throw AdapterFault("invalid_arguments") }
}
public struct Selector: Codable, Equatable { public var id: String?; public var title: String?; public var source_id: String? }
public struct Arguments: Codable, Equatable {
    public var operation_id: String?; public var title: String?; public var source_id: String?; public var selector: Selector?
    public var list_id: String?; public var reminder_id: String?; public var expected_revision: String?
    public var include_completed: Bool?; public var due_window: DueWindow?; public var patch: Patch?
    public var offset: Int?; public var limit: Int?
}
public struct Request: Encodable, Equatable {
    private struct WireRequest: Decodable { let tool: String; let args: Arguments }
    public let tool: String; public let args: Arguments
    public var operation: String { String(tool.dropFirst("apple.reminders.".count).dropLast(3)) }
    public var isMutation: Bool { ["list.create","create","update","complete","uncomplete","delete"].contains(operation) }
    public static let operations = ["sources","lists","list.lookup","list.create","query","get","create","update","complete","uncomplete","delete"]
    public static func decode(_ data: Data) throws -> Request {
        guard data.count <= 16_384 else { throw AdapterFault("invalid_arguments") }
        do {
            let object = try JSONSerialization.jsonObject(with: data)
            try StrictInput.validate(object)
            let wire = try JSONDecoder().decode(WireRequest.self, from: data)
            let r = Request(tool: wire.tool, args: wire.args)
            try r.validate(); return r
        } catch let fault as AdapterFault { throw fault }
        catch { throw AdapterFault("invalid_arguments") }
    }
    public func validate() throws {
        guard Self.operations.map({ "apple.reminders.\($0).v3" }).contains(tool) else { throw AdapterFault("unknown_tool") }
        if isMutation {
            guard let id = args.operation_id, let uuid = UUID(uuidString: id), uuid.uuidString.lowercased() == id else { throw AdapterFault("invalid_arguments") }
        }
        if let title = args.title { try validateTitle(title) }
        for id in [args.source_id,args.list_id,args.reminder_id,args.selector?.id,args.selector?.source_id].compactMap({$0}) {
            guard !id.isEmpty, id.utf8.count <= 1024, !id.unicodeScalars.contains(where: {$0.value < 32}) else { throw AdapterFault("invalid_arguments") }
        }
        if let revision = args.expected_revision { guard revision.utf8.count == 64, revision.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw AdapterFault("invalid_arguments") } }
        if operation == "list.lookup" {
            guard let s = args.selector, (s.id != nil) != (s.title != nil), s.id == nil || s.source_id == nil else { throw AdapterFault("invalid_arguments") }
            if let t = s.title { try validateTitle(t) }
        }
        if let window=args.due_window {
            _ = try window.bounds()
            guard args.include_completed != true else {throw AdapterFault("query_window_requires_incomplete")}
        }
        try args.patch?.validate()
        if operation == "create", args.patch?.title != nil { throw AdapterFault("invalid_arguments") }
        if operation == "update", args.patch?.isEmpty != false { throw AdapterFault("empty_patch") }
    }
}

// Codable alone ignores unknown keys. Enforce the complete wire shape before decoding.
enum StrictInput {
    static func object(_ value: Any, allowed: Set<String>, required: Set<String> = []) throws -> [String: Any] {
        guard let d = value as? [String:Any], Set(d.keys).isSubset(of: allowed), required.isSubset(of: Set(d.keys)),
              !d.values.contains(where: { $0 is NSNull }) else { throw AdapterFault("invalid_arguments") }; return d
    }
    static func validate(_ value: Any) throws {
        let top = try object(value, allowed:["tool","args"], required:["tool","args"])
        guard let tool = top["tool"] as? String, Request.operations.map({"apple.reminders.\($0).v3"}).contains(tool) else { throw AdapterFault("unknown_tool") }
        let op = String(tool.dropFirst("apple.reminders.".count).dropLast(3))
        let required: Set<String>
        var optional: Set<String> = []
        switch op {
        case "sources","lists": required = []
        case "list.lookup": required = ["selector"]
        case "list.create": required = ["operation_id","title","source_id"]
        case "query": required = []; optional = ["list_id","include_completed","due_window","offset","limit"]
        case "get": required = ["list_id","reminder_id"]
        case "create": required = ["operation_id","title"]; optional = ["list_id","patch"]
        case "update": required = ["operation_id","list_id","reminder_id","expected_revision","patch"]
        default: required = ["operation_id","list_id","reminder_id","expected_revision"]
        }
        let args = try object(top["args"]!, allowed: required.union(optional), required: required)
        if let window = args["due_window"] { _ = try object(window, allowed:["start","end"], required:["start","end"]) }
        if let s = args["selector"] { _ = try object(s, allowed:["id","title","source_id"]) }
        if let p = args["patch"] {
            let patch = try object(p, allowed:["title","notes","priority","due","start","recurrence","alert"])
            for (field, value) in patch {
                let change = try object(value, allowed:["action","value"], required:["action"])
                if let v = change["value"] {
                    switch field {
                    case "due","start": _ = try object(v, allowed:["kind","value","time_zone"], required:["kind","value"])
                    case "recurrence": _ = try object(v, allowed:["frequency","interval","count","until"], required:["frequency","interval"])
                    case "alert": _ = try object(v, allowed:["kind","at","offset_seconds"], required:["kind"])
                    default: break
                    }
                }
            }
        }
    }
}

public struct ReminderSource: Codable, Equatable {
    public var id: String; public var title: String; public var type: Int
    public var reminder_list_count: Int?; public var is_delegate: Bool?; public var is_system_default_account: Bool?
    public init(id:String,title:String,type:Int,reminderListCount:Int?=nil,isDelegate:Bool?=nil,isSystemDefaultAccount:Bool?=nil) {
        self.id=id;self.title=title;self.type=type;reminder_list_count=reminderListCount;is_delegate=isDelegate;is_system_default_account=isSystemDefaultAccount
    }
}
public struct ReminderList: Codable, Equatable {
    public var id: String; public var title: String; public var source_id: String; public var writable: Bool
    public var calendar_type: Int?; public var subscribed: Bool?; public var immutable: Bool?; public var is_system_default: Bool?
    public init(id:String,title:String,sourceID:String,writable:Bool,calendarType:Int?=nil,subscribed:Bool?=nil,immutable:Bool?=nil,isSystemDefault:Bool?=nil) {
        self.id=id;self.title=title;source_id=sourceID;self.writable=writable;calendar_type=calendarType;self.subscribed=subscribed;self.immutable=immutable;is_system_default=isSystemDefault
    }
}
// Raw public descriptors include fields we cannot author. Native update never reconstructs them.
public struct RichField: Codable, Equatable {
    public var editable: Bool; public var descriptors: [[String:String]]
    public init(editable:Bool = true, descriptors:[[String:String]] = []) {self.editable=editable;self.descriptors=descriptors}
}
public struct ReminderSnapshot: Codable, Equatable {
    public var id: String; public var list_id: String; public var title: String; public var notes: String?; public var priority: Int
    public var completed: Bool; public var completion_date: String?; public var modified: String?
    public var due: Due?; public var start: Due?; public var due_components: [String:String]; public var start_components: [String:String]
    public var recurrence: RichField; public var alerts: RichField; public var url: String?; public var location: String?
    public var revision: String
    public init(id:String,listID:String,title:String) {
        self.id=id;list_id=listID;self.title=title;priority=0;completed=false;due_components=[:];start_components=[:]
        recurrence=RichField();alerts=RichField();revision=""
    }
    public mutating func revise() throws { revision=""; revision=try digest(self) }
}
public struct ReminderDeletion: Codable, Equatable {
    public let id: String; public let list_id: String; public let expected_revision: String
    public init(id:String,listID:String,expectedRevision:String) {self.id=id;list_id=listID;expected_revision=expectedRevision}
}
public struct Response: Codable, Equatable {
    public var schema_version = 3; public var status = "ok"
    public var sources: [ReminderSource]?; public var lists: [ReminderList]?; public var list: ReminderList?
    public var reminders: [ReminderSnapshot]?; public var reminder: ReminderSnapshot?; public var operation_id: String?
    public var deletion: ReminderDeletion?
    public var offset: Int?; public var next_offset: Int?; public var total_count: Int?
    public var persistence: String?; public var cloud_sync: String?
    public init() {}
}
