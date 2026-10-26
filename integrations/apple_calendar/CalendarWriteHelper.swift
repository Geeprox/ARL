import Foundation
import EventKit
import AppKit
import CoreFoundation

func emit(_ value: [String: Any]) -> Never {
    let data = (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data()
    FileHandle.standardOutput.write(data);FileHandle.standardOutput.write(Data([10]));exit(0)
}
func auth() -> String {
    switch EKEventStore.authorizationStatus(for: .event) {
    case .notDetermined:return "not_determined"
    case .denied:return "denied"
    case .restricted:return "restricted"
    case .writeOnly:return "write_only"
    case .fullAccess:return "full_access"
    @unknown default:return "unknown"
    }
}
final class ConsentState: @unchecked Sendable {
    private let lock=NSLock()
    private var completed=false
    private var granted=false
    func complete(_ allowed:Bool) {lock.lock();granted=allowed;completed=true;lock.unlock()}
    func snapshot()->(Bool,Bool) {lock.lock();defer{lock.unlock()};return (completed,granted)}
}
if CommandLine.arguments.count==2 && ["--review-client","--isolated-review-client"].contains(CommandLine.arguments[1]) {
    runReviewedClient(isolated:CommandLine.arguments[1]=="--isolated-review-client")
}
// Explicit standalone consent route only. RPC can never request permission.
if CommandLine.arguments == [CommandLine.arguments[0], "--request-write-access"] {
    #if CALENDAR_EFFECT_FIXTURE
    emit(["status":"fixture_cannot_use_eventkit"])
    #endif
    guard Bundle.main.bundleIdentifier == "local.arl.calendarbridge",
          Bundle.main.object(forInfoDictionaryKey:"NSCalendarsWriteOnlyAccessUsageDescription") is String else {
        emit(["status":"permission_frontend_not_packaged"])
    }
    let app=NSApplication.shared;app.setActivationPolicy(.accessory);app.activate(ignoringOtherApps:true)
    let store=EKEventStore();let consent=ConsentState()
    store.requestWriteOnlyAccessToEvents { allowed,_ in
        consent.complete(allowed)
    }
    let deadline=Date().addingTimeInterval(60)
    while !consent.snapshot().0 && Date()<deadline { RunLoop.main.run(until:Date().addingTimeInterval(0.05)) }
    let (completed,granted)=consent.snapshot()
    emit(["status":completed ? (granted ? "authorized":"denied") : "permission_pending","authorization":auth()])
}
#if CALENDAR_EFFECT_FIXTURE
if CommandLine.arguments.count==5,CommandLine.arguments[1]=="--fixture-broker" {
    runNativeBroker(home:CommandLine.arguments[2],launcher:CommandLine.arguments[3],launcherSHA:CommandLine.arguments[4],fixture:true)
}
#endif
if CommandLine.arguments == [CommandLine.arguments[0],"--run-approved-event"] {
    let home=calendarAccountHome()+"/Library/Application Support/ARL/calendar-once"
    runNativeBroker(home:home,launcher:home+"/launch_calendar.py",launcherSHA:calendarLauncherSHA)
}
let validateOnly = CommandLine.arguments == [CommandLine.arguments[0], "--validate-only"]
guard validateOnly || CommandLine.arguments.count == 1 else { emit(["status":"invalid_arguments"]) }
let input=FileHandle.standardInput.readData(ofLength:16_385)
guard input.count<=16_384,
      let req=(try? JSONSerialization.jsonObject(with:input)) as? [String:Any],
      Set(req.keys)==Set(["tool","args"]),let tool=req["tool"] as? String,
      let args=req["args"] as? [String:Any] else {emit(["status":"invalid_arguments"])}
if tool=="apple.calendar.authorization.v1" && args.isEmpty && !validateOnly {
    emit(["status":"ok","authorization":auth(),"prompts_requested":false,"data_read":false])
}
guard tool=="apple.calendar.create.v1",Set(args.keys)==Set(["operation_id","title","start","end"]),
      let id=args["operation_id"] as? String,let uuid=UUID(uuidString:id),uuid.uuidString.lowercased()==id,
      let title=args["title"] as? String,!title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
      title.unicodeScalars.count<=300,
      !title.unicodeScalars.contains(where:{$0.value<32 || (127...159).contains($0.value)}),
      let startRaw=args["start"] as? String,let endRaw=args["end"] as? String else {emit(["status":"invalid_arguments"])}
func date(_ text:String)->Date? {
    guard text.count<=40,text.range(of:#"^[0-9]{4}-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9](?:\.[0-9]{1,6})?(?:Z|[+-][0-9][0-9]:[0-9][0-9])\z"#,options:.regularExpression) != nil else {return nil}
    let formatter=ISO8601DateFormatter()
    formatter.formatOptions=text.contains(".") ? [.withInternetDateTime,.withFractionalSeconds]:[.withInternetDateTime]
    return formatter.date(from:text)
}
guard let start=date(startRaw),let end=date(endRaw),end>start,end.timeIntervalSince(start)<=86400 else {emit(["status":"invalid_arguments"])}
if validateOnly {emit(["status":"valid","operation_id":id])}
// Schema validity is not authority. Ordinary stdin can NEVER reach EventKit save.
emit(["status":"native_broker_required"])

func saveCalendarEvent(_ args:[String:Any])->[String:Any] {
    #if CALENDAR_EFFECT_FIXTURE
    return ["status":"fixture_cannot_use_eventkit"]
    #else
    guard let startRaw=args["start"] as? String,let endRaw=args["end"] as? String,
          let start=date(startRaw),let end=date(endRaw),let title=args["title"] as? String,
          let id=args["operation_id"] as? String else{return ["status":"invalid_arguments"]}
    let store=EKEventStore()
    guard let calendar=store.defaultCalendarForNewEvents,calendar.allowsContentModifications else{return ["status":"no_default_calendar"]}
    let event=EKEvent(eventStore:store);event.calendar=calendar;event.title=title;event.startDate=start;event.endDate=end;event.isAllDay=false;event.alarms=[];event.notes=nil;event.url=nil
    do{try store.save(event,span:.thisEvent,commit:true);return ["status":"saved_local","operation_id":id]}
    catch{return ["status":"outcome_unknown"]}
    #endif
}
