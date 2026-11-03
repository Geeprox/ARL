import Foundation
import AppKit

// Type declarations for unused metadata validation in the actual Notes models.
enum AppleDirectStep { case notesAccountName, notesFolderName }
enum AppleDirectValueIssue { case tooLong }
struct AppleDirectFault: Error {
    let code: String
    init(_ code: String, step: AppleDirectStep? = nil, valueIssue: AppleDirectValueIssue? = nil) { self.code = code }
}

@MainActor final class FocusFixture {
    let center = NotificationCenter()
    let notificationObject = NSObject()
    var page = NotesDirectPageState()
    var ticket: NotesDirectActionTicket
    var folder: NotesDirectFolder?
    var enabled = true, held = false, operationBusy = false, active = false
    var now: TimeInterval = 100
    var activationCalls = 0
    init() { page.appear(); ticket = page.ticket(folder: nil)! }
    var current: Bool {
        enabled && !held && !operationBusy && (try? page.validate(ticket, currentFolder: folder)) != nil
    }
    func attempt(timeout: TimeInterval = 1.5) -> NotesDirectFocusAttempt {
        .init(center: center, object: notificationObject, timeout: timeout, now: { self.now },
              isActive: { self.active }, isCurrent: { self.current }, activate: { self.activationCalls += 1 })
    }
    func notify() { center.post(name: NSApplication.didBecomeActiveNotification, object: notificationObject) }
    func finalTicket(_ attempt: NotesDirectFocusAttempt) -> NotesDirectActionTicket? {
        guard attempt.confirmationStillValid, current, active else { return nil }
        return page.ticket(folder: folder)
    }
}

@MainActor @main enum NotesFocusTests {
    static var checks = 0
    static func expect(_ value: Bool, _ name: String) { precondition(value, name); checks += 1 }
    static func main() async {
        do {
            let fixture = FocusFixture(), attempt = fixture.attempt()
            expect(fixture.activationCalls == 0, "constructing a helper does not activate")
            attempt.startAfterClick()
            expect(fixture.activationCalls == 1 && attempt.phase == .waiting, "actual click requests activation synchronously once")
            expect(fixture.finalTicket(attempt) == nil, "request alone is not activation evidence")
            fixture.notify()
            expect(attempt.phase == .waiting, "notification with inactive app cannot admit")
            fixture.active = true; fixture.notify()
            expect(await attempt.wait() == .confirmed, "active notification confirms the same intent")
            expect(fixture.finalTicket(attempt)?.epoch == fixture.ticket.epoch, "only original page generation can issue ticket")
            attempt.startAfterClick(); fixture.notify()
            expect(fixture.activationCalls == 1, "duplicate events never request activation again")
            fixture.active = false
            expect(fixture.finalTicket(attempt) == nil, "losing focus before admission still rejects")
            attempt.close()
        }
        do {
            let fixture = FocusFixture(); fixture.active = true
            let attempt = fixture.attempt(); attempt.startAfterClick()
            expect(await attempt.wait() == .confirmed && fixture.activationCalls == 0, "already-active explicit click needs no activation request")
            fixture.now += 2
            expect(fixture.finalTicket(attempt) == nil, "confirmed focus cannot queue a late business action")
            attempt.close()
        }
        for invalid in ["disabled", "held", "busy", "hidden", "epoch", "folder"] {
            let fixture = FocusFixture()
            switch invalid {
            case "disabled": fixture.enabled = false
            case "held": fixture.held = true
            case "busy": fixture.operationBusy = true
            case "hidden": fixture.page.disappear()
            case "epoch": fixture.page.cancel()
            default: fixture.folder = .init(accountID: "synthetic-account", accountName: "Synthetic", id: "synthetic-folder", name: "Synthetic")
            }
            let attempt = fixture.attempt(); attempt.startAfterClick()
            expect(await attempt.wait() == .invalidated && fixture.activationCalls == 0, "invalid \(invalid) gate cannot activate or proceed")
            expect(fixture.finalTicket(attempt) == nil, "invalid \(invalid) gate cannot issue a ticket")
            attempt.close()
        }
        for changed in ["held", "busy", "hidden", "epoch", "folder"] {
            let fixture = FocusFixture(), attempt = fixture.attempt(); attempt.startAfterClick()
            switch changed {
            case "held": fixture.held = true
            case "busy": fixture.operationBusy = true
            case "hidden": fixture.page.disappear()
            case "epoch": fixture.page.cancel()
            default: fixture.folder = .init(accountID: "synthetic-account", accountName: "Synthetic", id: "different-folder", name: "Different")
            }
            fixture.active = true; fixture.notify()
            expect(await attempt.wait() == .invalidated, "\(changed) during activation invalidates original intent")
            expect(fixture.finalTicket(attempt) == nil && fixture.activationCalls == 1, "\(changed) cannot trigger retry or late operation")
            attempt.close()
        }
        do {
            let fixture = FocusFixture(), attempt = fixture.attempt(timeout: 0.02)
            attempt.startAfterClick()
            expect(await attempt.wait() == .timedOut, "missing activation has a finite timeout")
            fixture.active = true; fixture.notify()
            expect(fixture.finalTicket(attempt) == nil && fixture.activationCalls == 1, "late notification cannot revive timed-out intent")
            attempt.close()
        }
        do {
            let fixture = FocusFixture(), attempt = fixture.attempt()
            attempt.startAfterClick(); fixture.now += 2; fixture.active = true; fixture.notify()
            expect(await attempt.wait() == .timedOut && fixture.finalTicket(attempt) == nil, "absolute monotonic deadline wins over delayed timer scheduling")
            attempt.close()
        }
        do {
            let fixture = FocusFixture(), attempt = fixture.attempt()
            attempt.startAfterClick()
            let waiting = Task { @MainActor in await attempt.wait() }; waiting.cancel()
            expect(await waiting.value == .cancelled, "task cancellation ends wait without business dispatch")
            fixture.active = true; fixture.notify()
            expect(fixture.finalTicket(attempt) == nil, "cancelled intent cannot be revived")
            attempt.close()
        }
        do {
            let fixture = FocusFixture()
            let old = fixture.page.appear(), current = fixture.page.appear()
            fixture.ticket = fixture.page.ticket(folder: nil)!
            let attempt = fixture.attempt(); attempt.startAfterClick()
            expect(!fixture.page.disappear(appearance: old), "old view disappearance is ignored")
            fixture.active = true; fixture.notify()
            expect(await attempt.wait() == .confirmed && fixture.finalTicket(attempt) != nil, "current appearance survives old disappearance while focusing")
            expect(fixture.page.disappear(appearance: current), "current appearance can still disappear")
            expect(fixture.finalTicket(attempt) == nil, "current disappearance blocks a previously confirmed focus")
            attempt.close()
        }
        do {
            let fixture = FocusFixture(), attempt = fixture.attempt()
            expect(await attempt.wait() == .invalidated && fixture.activationCalls == 0, "no real click means no activation")
            attempt.close()
        }
        print("PASS \(checks) Notes focus/admission checks; real app activation=0 Notes reads=0")
    }
}
