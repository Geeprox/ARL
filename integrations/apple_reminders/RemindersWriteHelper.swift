import Foundation
import EventKit
import AppKit
import CoreFoundation

func emit(_ value: [String: Any]) -> Never {
    let data=(try? JSONSerialization.data(withJSONObject:value,options:[.sortedKeys])) ?? Data()
    FileHandle.standardOutput.write(data);FileHandle.standardOutput.write(Data([10]));exit(0)
}
func reminderAuthorization() -> String {
    switch EKEventStore.authorizationStatus(for:.reminder) {
    case .notDetermined:return "not_determined"
    case .denied:return "denied"
    case .restricted:return "restricted"
    case .fullAccess:return "full_access"
    case .writeOnly:return "unknown" // Events-only; never accepted for Reminders.
    @unknown default:return "unknown"
    }
}
final class ConsentState: @unchecked Sendable {
    private let lock=NSLock();private var completed=false;private var granted=false
    func complete(_ allowed:Bool){lock.lock();granted=allowed;completed=true;lock.unlock()}
    func snapshot()->(Bool,Bool){lock.lock();defer{lock.unlock()};return (completed,granted)}
}
if CommandLine.arguments.count==2,["--review-client","--isolated-review-client"].contains(CommandLine.arguments[1]) {
    runReviewedClient(isolated:CommandLine.arguments[1]=="--isolated-review-client")
}
// Standalone, explicit consent action only. Job execution never requests TCC.
if CommandLine.arguments == [CommandLine.arguments[0],"--request-full-access"] {
    #if REMINDERS_EFFECT_FIXTURE
    emit(["status":"fixture_cannot_use_eventkit"])
    #else
    guard Bundle.main.bundleIdentifier=="local.arl.remindersbridge",
          Bundle.main.object(forInfoDictionaryKey:"NSRemindersFullAccessUsageDescription") is String else {
        emit(["status":"permission_frontend_not_packaged"])
    }
    let app=NSApplication.shared;app.setActivationPolicy(.accessory);app.activate(ignoringOtherApps:true)
    let consent=ConsentState();let store=EKEventStore()
    store.requestFullAccessToReminders{allowed,_ in consent.complete(allowed)}
    let deadline=Date().addingTimeInterval(60)
    while !consent.snapshot().0 && Date()<deadline{RunLoop.main.run(until:Date().addingTimeInterval(0.05))}
    let (done,allowed)=consent.snapshot()
    emit(["status":done ? (allowed ? "authorized":"denied"):"permission_pending","authorization":reminderAuthorization()])
    #endif
}
#if REMINDERS_EFFECT_FIXTURE
if CommandLine.arguments.count==5,CommandLine.arguments[1]=="--fixture-broker" {
    runNativeBroker(home:CommandLine.arguments[2],launcher:CommandLine.arguments[3],launcherSHA:CommandLine.arguments[4],fixture:true)
}
#endif
if CommandLine.arguments == [CommandLine.arguments[0],"--run-approved-reminder"] {
    let home=remindersAccountHome()+"/Library/Application Support/ARL/reminders-once"
    runNativeBroker(home:home,launcher:home+"/launch_reminders.py",launcherSHA:remindersLauncherSHA)
}
let validateOnly=CommandLine.arguments == [CommandLine.arguments[0],"--validate-only"]
guard validateOnly || CommandLine.arguments.count==1 else{emit(["status":"invalid_arguments"])}
let input=FileHandle.standardInput.readData(ofLength:16385)
guard input.count<=16384,let request=(try? JSONSerialization.jsonObject(with:input)) as? [String:Any],
      Set(request.keys)==Set(["tool","args"]),let tool=request["tool"] as? String,
      let args=request["args"] as? [String:Any] else{emit(["status":"invalid_arguments"])}
if tool=="apple.reminders.authorization.v1",args.isEmpty,!validateOnly {
    #if REMINDERS_EFFECT_FIXTURE
    emit(["status":"fixture_cannot_use_eventkit"])
    #else
    emit(["status":"ok","authorization":reminderAuthorization(),"prompts_requested":false,"data_read":false])
    #endif
}
guard tool=="apple.reminders.create.v1",validReminderArgs(args) else{emit(["status":"invalid_arguments"])}
if validateOnly{emit(["status":"valid","operation_id":args["operation_id"]!])}
// Even schema-valid direct stdin cannot reach authorization, store or save.
emit(["status":"native_broker_required"])

func validReminderArgs(_ args:[String:Any])->Bool {
    guard Set(args.keys)==Set(["operation_id","title","target_policy"]),
          let id=args["operation_id"] as? String,let uuid=UUID(uuidString:id),uuid.uuidString.lowercased()==id,
          let title=args["title"] as? String,!title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
          title.unicodeScalars.count<=300,
          !title.unicodeScalars.contains(where:{$0.value<32 || (127...159).contains($0.value)}),
          args["target_policy"] as? String=="system_default_at_confirmation" else{return false}
    return true
}
