import Foundation
import EventKit

// Private helper protocol; no requestAccess call, no UI, no Notes body write.
// Permission belongs to the final signed helper identity, not the Python process.
func emit(_ value: [String: Any]) -> Never {
    let data = (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data()
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([10]))
    exit(0)
}

let input = FileHandle.standardInput.readDataToEndOfFile()
guard input.count <= 16_384,
      let request = try? JSONSerialization.jsonObject(with: input) as? [String: Any],
      Set(request.keys) == Set(["tool", "args"]),
      let tool = request["tool"] as? String,
      let args = request["args"] as? [String: Any] else {
    emit(["status": "invalid_arguments"])
}

func status(_ type: EKEntityType) -> String {
    switch EKEventStore.authorizationStatus(for: type) {
    case .notDetermined: return "not_determined"
    case .restricted: return "restricted"
    case .denied: return "denied"
    case .fullAccess: return "full_access"
    case .writeOnly: return "write_only"
    @unknown default: return "unknown"
    }
}

if tool == "apple.authorization" && args.isEmpty {
    emit(["status": "ok", "result": ["calendar": status(.event), "reminders": status(.reminder),
         "prompts_requested": false]])
}

guard tool == "apple.calendar.list" || tool == "apple.reminders.list" else {
    emit(["status": "unsupported"])
}
let entity: EKEntityType = tool == "apple.calendar.list" ? .event : .reminder
guard EKEventStore.authorizationStatus(for: entity) == .fullAccess else {
    emit(["status": "needs_permission"])
}
let store = EKEventStore()
let formatter = ISO8601DateFormatter()

if entity == .event {
    guard Set(args.keys) == Set(["start", "end"]),
          let startString = args["start"] as? String, let endString = args["end"] as? String,
          let start = formatter.date(from: startString), let end = formatter.date(from: endString),
          end > start, end.timeIntervalSince(start) <= 31 * 86400 else {
        emit(["status": "invalid_arguments"])
    }
    let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
    let events = store.events(matching: predicate).prefix(100).map { event -> [String: Any] in
        ["id": event.eventIdentifier ?? "", "title": String((event.title ?? "").prefix(300)),
         "start": formatter.string(from: event.startDate), "end": formatter.string(from: event.endDate)]
    }
    emit(["status": "ok", "result": ["items": events, "limit": 100]])
} else {
    guard args.isEmpty else { emit(["status": "invalid_arguments"]) }
    let semaphore = DispatchSemaphore(value: 0)
    var reply: [[String: Any]]?
    store.fetchReminders(matching: store.predicateForIncompleteReminders(
        withDueDateStarting: Date(), ending: Date().addingTimeInterval(31 * 86400), calendars: nil)) { reminders in
        reply = reminders?.prefix(100).map { reminder in
            ["id": reminder.calendarItemIdentifier, "title": String(reminder.title.prefix(300)),
             "completed": reminder.isCompleted]
        }
        semaphore.signal()
    }
    guard semaphore.wait(timeout: .now() + 10) == .success, let items = reply else {
        emit(["status": "unavailable"])
    }
    emit(["status": "ok", "result": ["items": items, "limit": 100,
         "scope": "incomplete reminders due in next 31 days"]])
}
