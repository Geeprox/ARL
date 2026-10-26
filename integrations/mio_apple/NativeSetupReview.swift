import Foundation
import AppKit

// AppKit owns NSAlert's button target/actions and normal mouse, keyboard and
// accessibility activation. Only the local modal result can confirm this step;
// no JSON/RPC input constructs the alert or supplies its response.
@MainActor func nativeMioSetupReview(_ title:String,_ text:String,_ button:String)throws->MioSetupDecision {
    guard Thread.isMainThread else{throw ReviewFault("native_review_not_main")}
    let app=NSApplication.shared
    app.setActivationPolicy(.accessory);app.activate(ignoringOtherApps:true)
    let alert=NSAlert();alert.messageText=title;alert.informativeText=text
    alert.addButton(withTitle:button);alert.addButton(withTitle:"取消")
    let end=ProcessInfo.processInfo.systemUptime+20
    let timer=Timer(timeInterval:20,repeats:false){_ in
        MainActor.assumeIsolated{app.abortModal()}
    }
    RunLoop.main.add(timer,forMode:.modalPanel)
    RunLoop.main.add(timer,forMode:.eventTracking)
    defer{timer.invalidate();alert.window.orderOut(nil)}
    MioStartupDiagnostics.record("native_review_displayed")
    let response=alert.runModal()
    let now=ProcessInfo.processInfo.systemUptime
    guard now<end else{
        MioStartupDiagnostics.record("native_review_expired");return .expired
    }
    guard response == .alertFirstButtonReturn else{
        MioStartupDiagnostics.record("native_review_cancelled");return .cancelled
    }
    MioStartupDiagnostics.record("native_review_confirmed")
    return .confirmed(now)
}
