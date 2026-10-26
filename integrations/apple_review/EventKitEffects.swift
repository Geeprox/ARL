import Foundation
import EventKit
import AppKit
import CoreGraphics

// Real adapter compiles; no TCC request API or existing-item fetch exists here.
final class EventKitEffects:AppleEffects {
    private var store:EKEventStore?=nil
    private func getStore()->EKEventStore{if let store{return store};let value=EKEventStore();store=value;return value}
    func authorization(_ operation:AppleOperation)->String {
        switch EKEventStore.authorizationStatus(for:operation == .calendar ? .event:.reminder) {
        case .fullAccess:return "full_access"
        case .writeOnly:return "write_only"
        case .notDetermined:return "not_determined"
        case .denied:return "denied"
        case .restricted:return "restricted"
        @unknown default:return "unknown"
        }
    }
    func lockState()->String {
        guard let session=CGSessionCopyCurrentDictionary() as? [String:Any],let locked=session["CGSSessionScreenIsLocked"] as? Bool else{return "unknown"}
        return locked ? "locked":"unlocked"
    }
    private func list(_ operation:AppleOperation)->EKCalendar? {
        let source=getStore()
        return operation == .calendar ? source.defaultCalendarForNewEvents:source.defaultCalendarForNewReminders()
    }
    func resolve(_ binding:TargetBinding)throws->ResolvedTarget {
        guard let list=list(binding.operation),list.calendarIdentifier==binding.identifier,list.allowsContentModifications,
              list.allowedEntityTypes.contains(binding.operation == .calendar ? .event:.reminder) else{throw ReviewFault("target_changed")}
        return ResolvedTarget(identifier:list.calendarIdentifier,name:list.title)
    }
    func save(_ proposal:AppleProposal,target:ResolvedTarget)throws->String {
        guard let list=list(proposal.operation),list.calendarIdentifier==target.identifier,list.allowsContentModifications else{throw ReviewFault("target_changed")}
        let source=getStore()
        do {
            if proposal.operation == .calendar {
                let event=EKEvent(eventStore:source);event.calendar=list;event.title=proposal.title;event.startDate=proposal.start;event.endDate=proposal.end
                event.timeZone=TimeZone(identifier:proposal.timeZone);event.isAllDay=false;event.alarms=[];event.recurrenceRules=[];event.notes=nil;event.url=nil
                try source.save(event,span:.thisEvent,commit:true)
            } else {
                let item=EKReminder(eventStore:source);item.calendar=list;item.title=proposal.title;item.isCompleted=false;item.priority=0
                if let due=proposal.due {
                    var calendar=Calendar(identifier:.gregorian);calendar.timeZone=TimeZone(identifier:proposal.timeZone)!
                    var components=calendar.dateComponents([.year,.month,.day,.hour,.minute,.second],from:due);components.timeZone=calendar.timeZone
                    item.dueDateComponents=components
                }
                item.startDateComponents=nil;item.alarms=[];item.recurrenceRules=[];item.notes=nil;item.url=nil
                try source.save(item,commit:true)
            }
            return "saved_local"
        } catch {return "outcome_unknown"}
    }
}
@MainActor final class SystemNativeReviewer:NativeReviewer {
    func confirm(_ display:ReviewDisplay)->Bool {
        let app=NSApplication.shared;app.setActivationPolicy(.accessory);app.activate(ignoringOtherApps:true)
        let alert=NSAlert();alert.messageText=display.proposal.operation == .calendar ? "创建日历事件？":"创建提醒事项？"
        alert.informativeText=display.text;alert.addButton(withTitle:"创建");alert.addButton(withTitle:"取消")
        let timer=Timer(timeInterval:20,repeats:false){_ in MainActor.assumeIsolated{NSApplication.shared.abortModal()}}
        RunLoop.main.add(timer,forMode:.modalPanel)
        defer{timer.invalidate();alert.window.orderOut(nil)}
        return alert.runModal() == .alertFirstButtonReturn
    }
}
