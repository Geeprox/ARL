import Foundation
import AppKit

struct ConfirmationWindow {
    let started:UInt64
    init(started:UInt64=DispatchTime.now().uptimeNanoseconds){self.started=started}
    func permits(confirmed:Bool,now:UInt64=DispatchTime.now().uptimeNanoseconds)->Bool {
        confirmed && now>=started && now-started<20_000_000_000
    }
}
func modalConfirmationTimer(interval:TimeInterval=20,onTimeout:@escaping @Sendable ()->Void)->Timer {
    let timer=Timer(timeInterval:interval,repeats:false){_ in onTimeout()}
    RunLoop.main.add(timer,forMode:.modalPanel)
    return timer
}
