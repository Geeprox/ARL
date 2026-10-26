"""No-window/no-EventKit reproduction of the real modal timer/deadline helper."""
import json,subprocess,tempfile,unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
class RemindersConfirmationTests(unittest.TestCase):
    def test_timer_fires_in_modal_mode_and_late_create_is_denied(self):
        with tempfile.TemporaryDirectory(prefix='reminder-modal-',dir='/tmp') as tmp:
            main=Path(tmp)/'main.swift';binary=Path(tmp)/'test'
            main.write_text('''import Foundation
import AppKit
final class State: @unchecked Sendable {var fired=false}
let state=State()
let timer=modalConfirmationTimer(interval:0.02){state.fired=true}
RunLoop.main.run(mode:.modalPanel,before:Date().addingTimeInterval(0.06))
timer.invalidate()
let window=ConfirmationWindow(started:1000)
let result:[String:Bool]=["modal_fired":state.fired,"before_deadline":window.permits(confirmed:true,now:19_999_999_999),"at_deadline":window.permits(confirmed:true,now:20_000_001_000),"late_create":window.permits(confirmed:true,now:30_000_001_000),"cancel":window.permits(confirmed:false,now:1001),"clock_backwards":window.permits(confirmed:true,now:999)]
FileHandle.standardOutput.write(try! JSONSerialization.data(withJSONObject:result))
''')
            subprocess.run(['/usr/bin/xcrun','swiftc','-swift-version','6','-module-cache-path',str(ROOT/'integrations/apple_reminders/dist/module-cache'),str(main),str(ROOT/'integrations/apple_reminders/ConfirmationWindow.swift'),'-framework','AppKit','-o',str(binary)],check=True,capture_output=True,timeout=30)
            p=subprocess.run([str(binary)],check=True,capture_output=True,timeout=3)
            self.assertEqual(json.loads(p.stdout),{'modal_fired':True,'before_deadline':True,'at_deadline':False,'late_create':False,'cancel':False,'clock_backwards':False})
