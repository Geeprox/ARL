import Foundation
import EventKit
import AppKit
import CoreGraphics

struct ReminderTarget {
    let identifier:String
    let title:String
}
protocol ReminderStore {
    func defaultTarget()->ReminderTarget?
    func confirm(_ target:ReminderTarget,title:String)->Bool
    func save(_ target:ReminderTarget,title:String)->String
}
func reminderUnlockState()->String {
    guard let session=CGSessionCopyCurrentDictionary() as? [String:Any],
          let locked=session["CGSSessionScreenIsLocked"] as? Bool else{return "unknown"}
    return locked ? "locked":"unlocked"
}
#if !REMINDERS_EFFECT_FIXTURE
// No calendars(for:), predicate, fetchReminders, reminder lookup or account scan.
final class EventKitReminderStore: ReminderStore {
    private let store=EKEventStore()
    func defaultTarget()->ReminderTarget? {
        guard let list=store.defaultCalendarForNewReminders(),list.allowsContentModifications,
              list.allowedEntityTypes.contains(.reminder),list.calendarIdentifier.utf8.count<=1024,
              !list.calendarIdentifier.isEmpty,list.title.unicodeScalars.count<=200 else{return nil}
        return ReminderTarget(identifier:list.calendarIdentifier,title:list.title)
    }
    func confirm(_ target:ReminderTarget,title:String)->Bool {
        let app=NSApplication.shared;app.setActivationPolicy(.accessory);app.activate(ignoringOtherApps:true)
        let alert=NSAlert();alert.messageText="创建一条提醒事项？"
        alert.informativeText="列表：\(target.title)\n提醒：\(title)"
        alert.addButton(withTitle:"创建");alert.addButton(withTitle:"取消")
        // User review has a bounded window. Timeout is cancellation, never Save.
        let window=ConfirmationWindow()
        let timer=modalConfirmationTimer{
            NSApplication.shared.abortModal()
        }
        defer{timer.invalidate();alert.window.orderOut(nil)}
        let confirmed=alert.runModal() == .alertFirstButtonReturn
        return window.permits(confirmed:confirmed)
    }
    func save(_ target:ReminderTarget,title:String)->String {
        // Resolve only the selected identifier, recheck default identity and access.
        guard let current=defaultTarget(),current.identifier==target.identifier,
              let list=store.calendar(withIdentifier:target.identifier),list.allowsContentModifications,
              list.allowedEntityTypes.contains(.reminder) else{return "target_changed"}
        let item=EKReminder(eventStore:store);item.calendar=list;item.title=title
        item.isCompleted=false;item.priority=0;item.startDateComponents=nil;item.dueDateComponents=nil
        item.alarms=[];item.recurrenceRules=[];item.notes=nil;item.url=nil
        do{try store.save(item,commit:true);return "saved_local"}
        catch{return "outcome_unknown"} // No error descriptions or item contents escape.
    }
}
#else
// Compile-time injected store; this executable cannot construct an EventKit store.
final class FixtureReminderStore: ReminderStore {
    let home:String;let mode:String
    private var targets=0
    init(home:String,mode:String){self.home=home;self.mode=mode;record("constructed")}
    func record(_ kind:String) {
        let path=home+"/fixture-"+kind
        if !FileManager.default.fileExists(atPath:path){FileManager.default.createFile(atPath:path,contents:Data(),attributes:[.posixPermissions:0o600])}
    }
    func defaultTarget()->ReminderTarget? {
        record("default-target");targets+=1
        if mode=="no_default_list"{return nil}
        return ReminderTarget(identifier:mode=="target_changed" && targets>1 ? "changed":"synthetic-list",title:"Synthetic list")
    }
    func confirm(_ target:ReminderTarget,title:String)->Bool {
        record("confirmation")
        if mode=="expire_during_confirmation" {
            let review:[String:Any]=["args":remindersSealedArgs,"expires_at_ms":1]
            let data=try! JSONSerialization.data(withJSONObject:review)
            try! data.write(to:URL(fileURLWithPath:home+"/review.json"))
        }
        if mode=="crash_after_consume"{exit(77)}
        if mode=="late_confirmation"{return ConfirmationWindow(started:1000).permits(confirmed:true,now:20_000_001_000)}
        return mode != "user_cancelled"
    }
    func save(_ target:ReminderTarget,title:String)->String {
        record("save-attempt")
        if mode=="outcome_unknown"{return "outcome_unknown"}
        record("effect");return "saved_local"
    }
}
#endif
