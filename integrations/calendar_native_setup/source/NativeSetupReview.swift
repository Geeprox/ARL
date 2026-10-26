import Foundation
import AppKit

// The real AppKit button action supplies the evidence. A modal return code,
// imported approved=true, stale event or accessibility performClick alone does
// not. No public endpoint constructs this controller or chooses its fields.
@MainActor enum MioNativeInteraction {
    static func accepts(eventTime:Double,now:Double,began:Double,end:Double,
                        eventMatchesWindow:Bool,windowKey:Bool,windowVisible:Bool,
                        appActive:Bool,eventType:NSEvent.EventType,isRepeat:Bool)->Bool {
        eventTime.isFinite && now.isFinite && eventTime>=began && now>=eventTime &&
        now-eventTime<1 && now<end && eventMatchesWindow && windowKey && windowVisible && appActive &&
        (eventType == .leftMouseUp || eventType == .keyDown) && !isRepeat
    }
}
@MainActor private final class MioNativeButtonAction:NSObject {
    let alert:NSAlert;let began:Double;let end:Double
    private(set) var decision:MioSetupDecision = .cancelled
    init(alert:NSAlert,began:Double,end:Double){self.alert=alert;self.began=began;self.end=end}
    @objc func accept(_ sender:NSButton) {
        let now=ProcessInfo.processInfo.systemUptime
        guard sender===alert.buttons.first,let event=NSApplication.shared.currentEvent else{return}
        // Key-up has no per-dialog paired press; repeats can cross dialogs when
        // Return remains held. Query isARepeat only for the keyboard event type.
        let repeated=event.type == .keyDown ? event.isARepeat:false
        guard MioNativeInteraction.accepts(eventTime:event.timestamp,now:now,began:began,end:end,
            eventMatchesWindow:event.windowNumber==alert.window.windowNumber,
            windowKey:alert.window.isKeyWindow,windowVisible:alert.window.isVisible,
            appActive:NSApplication.shared.isActive,eventType:event.type,isRepeat:repeated) else{return}
        decision = .confirmed(now);NSApplication.shared.stopModal(withCode:.alertFirstButtonReturn)
    }
    @objc func cancel(_ sender:NSButton){decision = .cancelled;NSApplication.shared.stopModal(withCode:.alertSecondButtonReturn)}
    func expire(){decision = .expired;NSApplication.shared.abortModal()}
}
@MainActor func nativeMioSetupReview(_ title:String,_ text:String,_ button:String)throws->MioSetupDecision {
    let app=NSApplication.shared;app.setActivationPolicy(.accessory);app.activate(ignoringOtherApps:true)
    let alert=NSAlert();alert.messageText=title;alert.informativeText=text
    alert.addButton(withTitle:button);alert.addButton(withTitle:"取消")
    let began=ProcessInfo.processInfo.systemUptime;let end=began+20
    let action=MioNativeButtonAction(alert:alert,began:began,end:end)
    alert.buttons[0].target=action;alert.buttons[0].action=#selector(MioNativeButtonAction.accept(_:))
    alert.buttons[1].target=action;alert.buttons[1].action=#selector(MioNativeButtonAction.cancel(_:))
    let timer=Timer(timeInterval:20,repeats:false){_ in MainActor.assumeIsolated{action.expire()}}
    RunLoop.main.add(timer,forMode:.modalPanel)
    defer{timer.invalidate();alert.window.orderOut(nil)}
    _=alert.runModal()
    guard ProcessInfo.processInfo.systemUptime<end else{return .expired}
    return action.decision
}
