import Foundation

// All state, permission and metadata observations below are synthetic. No live
// TCC request, Apple event, application launch, message, note or calendar store.
final class AutomaticMemoryPreferences: UserDefaults, @unchecked Sendable {
    private var values: [String: Any] = [:]
    init() { super.init(suiteName: "local.arl.fixture." + UUID().uuidString)! }
    override func dictionary(forKey key: String) -> [String: Any]? { values[key] as? [String: Any] }
    override func data(forKey key: String) -> Data? { values[key] as? Data }
    override func string(forKey key: String) -> String? { values[key] as? String }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
}
final class AutomaticPermissionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Bool] = []
    func check(_ ask: Bool) -> AppleDirectPermission {
        lock.lock(); defer { lock.unlock() }; values.append(ask); return .authorized
    }
    var calls: [Bool] { lock.lock(); defer { lock.unlock() }; return values }
}
final class AutomaticConsentProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var observedCalls: [Bool] = []
    let quiet: AppleDirectPermission
    init(_ quiet: AppleDirectPermission) { self.quiet = quiet }
    func check(_ ask: Bool) -> AppleDirectPermission {
        lock.lock(); defer { lock.unlock() }; observedCalls.append(ask)
        return ask ? .authorized : quiet
    }
    var calls: [Bool] { lock.lock(); defer { lock.unlock() }; return observedCalls }
}
@MainActor final class AutomaticProbeFixture {
    var calls = 0
    var now: TimeInterval = 100
    var time = Date(timeIntervalSince1970: 1000)
    var result: Result<AppleDirectPermission, AppleStatusProbeFailure> = .success(.authorized)
    var continuation: CheckedContinuation<Void, Never>?
    var suspend = false
    func coordinator(automatic: Bool = false, enabled: Bool = true) -> AppleStatusCoordinator<AppleDirectPermission> {
        .init(enabled: enabled, uptime: { self.now }, date: { self.time }, foreground: { true },
              startAutomatically: automatic, probe: {
            self.calls += 1
            if self.suspend { await withCheckedContinuation { self.continuation = $0 } }
            return try self.result.get()
        })
    }
}
@MainActor final class AutomaticCalendarFixture {
    var value = CalendarPermissionState.writeOnly
    var requests = 0
}
@main enum AppleAutomaticRefreshTests {
    enum Failure: Error { case assertion(String) }
    static func expect(_ value: Bool, _ label: String) throws {
        if !value { throw Failure.assertion(label) }
    }
    @MainActor static func main() async throws {
        let disabledFixture = AutomaticProbeFixture(), disabled = disabledFixture.coordinator(automatic: true, enabled: false)
        await disabled.refresh(force: true)
        try expect(disabledFixture.calls == 0 && disabled.state.value == nil, "disabled probes never run")
        let fixture = AutomaticProbeFixture(), status = fixture.coordinator()
        await status.refresh()
        try expect(status.state.value == .authorized && status.state.observedAt == fixture.time, "first quiet observation")
        await status.refresh()
        try expect(fixture.calls == 1, "healthy refresh honors interval")
        fixture.now += 30; fixture.time.addTimeInterval(30)
        fixture.result = .failure(.init(.targetNotRunning, nativeStatus: -600))
        await status.refresh()
        let previousDate = status.state.observedAt
        try expect(status.state.value == .authorized && status.state.showingLastKnown &&
                   status.state.observedAt == Date(timeIntervalSince1970: 1000), "app exit retains last known and timestamp")
        try expect(status.state.lastFailure == .init(.targetNotRunning, nativeStatus: -600), "failure remains finite and distinct from denial")
        await status.refresh()
        try expect(fixture.calls == 2, "failure backs off")
        fixture.now += 5; await status.refresh()
        try expect(fixture.calls == 3 && status.state.observedAt == previousDate, "retry does not fabricate observation time")
        fixture.now += 14; await status.refresh()
        try expect(fixture.calls == 3, "second failure has longer backoff")
        fixture.now += 1; fixture.result = .success(.denied); await status.refresh()
        try expect(status.state.value == .denied && status.state.lastFailure == nil && !status.state.showingLastKnown,
                   "real denial supersedes a cached grant")

        let concurrentFixture = AutomaticProbeFixture(); concurrentFixture.suspend = true
        let concurrent = concurrentFixture.coordinator()
        let first = Task { await concurrent.refresh(force: true) }
        while concurrentFixture.continuation == nil { await Task.yield() }
        let second = Task { await concurrent.refresh(force: true) }
        await Task.yield()
        try expect(concurrentFixture.calls == 1 && concurrent.state.refreshing, "concurrent callers coalesce")
        concurrentFixture.continuation?.resume(); concurrentFixture.continuation = nil
        await first.value; await second.value
        try expect(concurrentFixture.calls == 1 && !concurrent.state.refreshing, "one completed observation")

        concurrentFixture.suspend = true
        let stale = Task { await concurrent.refresh(force: true) }
        while concurrentFixture.continuation == nil { await Task.yield() }
        concurrent.pause(); concurrent.accept(.denied)
        concurrentFixture.continuation?.resume(); concurrentFixture.continuation = nil
        await stale.value
        try expect(concurrent.state.value == .denied, "old quiet observation cannot overwrite explicit consent result")
        concurrent.stop()
        let stoppedFixture = AutomaticProbeFixture(); stoppedFixture.suspend = true
        let stopped = stoppedFixture.coordinator()
        let late = Task { await stopped.refresh(force: true) }
        while stoppedFixture.continuation == nil { await Task.yield() }
        stopped.stop(); stoppedFixture.continuation?.resume(); stoppedFixture.continuation = nil
        await late.value
        try expect(stopped.state.value == nil && !stopped.state.refreshing, "shutdown rejects late publication")
        await stopped.refresh(force: true)
        try expect(stoppedFixture.calls == 1, "stopped coordinator does not restart")

        let autoFixture = AutomaticProbeFixture(), auto = autoFixture.coordinator(automatic: true)
        for _ in 0..<100 where autoFixture.calls == 0 { await Task.yield() }
        try expect(autoFixture.calls == 1, "startup initiates a quiet observation without a check button")
        auto.stop()
        let preferences = AutomaticMemoryPreferences(), executor = AppleDirectExecutor(), probe = AutomaticPermissionProbe()
        let observed = AppleDirectStatus.make(target: .notes, enabled: true, executor: executor,
            preferences: preferences, startAutomatically: false, check: { probe.check($0) })
        await observed.refresh(force: true)
        let restored = AppleDirectStatus.make(target: .notes, enabled: true, executor: executor,
            preferences: preferences, startAutomatically: false, check: { _ in throw AppleDirectFault("open_target_application") })
        try expect(restored.state.value == .authorized && restored.state.showingLastKnown && restored.state.observedAt != nil,
                   "same installed owner restores display evidence")
        await restored.refresh(force: true)
        try expect(restored.state.value == .authorized && restored.state.lastFailure?.issue == .targetNotRunning,
                   "closed app does not erase persisted evidence")
        let key = "appleDirectPermissionObservationV1." + AppleDirectTarget.notes.identifier
        var saved = preferences.dictionary(forKey: key)!; saved["owner"] = "different-owner"; preferences.set(saved, forKey: key)
        let otherOwner = AppleDirectStatus.make(target: .notes, enabled: true, executor: executor,
            preferences: preferences, startAutomatically: false, check: { probe.check($0) })
        try expect(otherOwner.state.value == nil, "another signing identity cannot reuse display cache")
        let notes = NotesDirectController(home: URL(fileURLWithPath: "/nonexistent-fixture"), enabled: true,
            executor: executor, preferences: preferences, startAutomatically: false, permissionCheck: { probe.check($0) },
            prepareTarget: { _ in throw Failure.assertion("quiet Notes status must never prepare application") })
        let messages = MessagesDirectController(home: URL(fileURLWithPath: "/nonexistent-fixture"), enabled: true,
            executor: executor, preferences: preferences, startAutomatically: false, permissionCheck: { probe.check($0) },
            prepareTarget: { _ in throw Failure.assertion("quiet Messages status must never prepare application") })
        await notes.refreshStatus(); await messages.refreshStatus()
        try expect(notes.permission == .authorized && messages.permission == .authorized && probe.calls == [false, false, false],
                   "controller quiet probes never request consent or open target; no page/foreground needed")
        try expect(notes.folders.isEmpty && notes.readResult == nil && messages.accounts.isEmpty && messages.recipient == nil,
                   "quiet status never invokes metadata or business consumers")
        let calendarFixture = AutomaticCalendarFixture()
        let calendar = CalendarPermissionController(enabled: true, readStatus: { calendarFixture.value }, requestAccess: {
            calendarFixture.requests += 1; return true
        }, verifyOwner: {}, foreground: { false })
        let calendarObserved = calendar.observedAt
        calendarFixture.value = .unknown; calendar.refresh(); await calendar.request()
        try expect(calendar.state == .writeOnly && calendar.lastKnownState == .writeOnly && calendar.lastProbeFailed &&
                   calendar.observedAt == calendarObserved && calendarFixture.requests == 0, "Calendar quiet unknown preserves grant and never prompts")
        calendarFixture.value = .denied; calendar.refresh()
        try expect(calendar.state == .denied && !calendar.lastProbeFailed && calendarFixture.requests == 0, "Calendar real denial replaces cached grant")
        for initial in [AppleDirectPermission.authorized, .denied, .notDetermined] {
            let consent = AutomaticConsentProbe(initial)
            let value = try AppleDirectAuthorization.requestIfNeeded(stop: AppleDirectCancellation(), check: { consent.check($0) })
            try expect(consent.calls == (initial == .notDetermined ? [false, true] : [false]) &&
                       value == (initial == .notDetermined ? .authorized : initial), "explicit connect prompts only after fresh notDetermined")
        }
        let cancelledConsent = AutomaticConsentProbe(.notDetermined), cancelledStop = AppleDirectCancellation()
        cancelledStop.cancel()
        do {
            _ = try AppleDirectAuthorization.requestIfNeeded(stop: cancelledStop, check: { cancelledConsent.check($0) })
            throw Failure.assertion("cancelled connect admitted")
        } catch let fault as AppleDirectFault { try expect(fault.code == "cancelled" && cancelledConsent.calls.isEmpty, "cancelled connect never probes or prompts") }
        notes.suspendForExit(); messages.suspendForExit()
        try expect(notes.actionAdmissionHeld && messages.actionAdmissionHeld, "controller exit closes native action admission")
        notes.finishExit(); messages.finishExit()
        notes.connection.accept(.denied); messages.connection.accept(.denied)
        try expect(notes.permission == .authorized && messages.permission == .authorized, "stopped state rejects late consent publication")
        let exitCalendarFixture = AutomaticCalendarFixture(); exitCalendarFixture.value = .notDetermined
        let exitCalendar = CalendarPermissionController(enabled: true, readStatus: { exitCalendarFixture.value }, requestAccess: {
            exitCalendarFixture.requests += 1; exitCalendarFixture.value = .writeOnly; return true
        }, verifyOwner: {}, foreground: { true })
        exitCalendar.suspendForExit(); await exitCalendar.request()
        try expect(exitCalendarFixture.requests == 0 && !exitCalendar.canAct, "exit blocks fresh Calendar consent")
        exitCalendar.resumeAfterCancelledExit(); await exitCalendar.request()
        try expect(exitCalendarFixture.requests == 1 && exitCalendar.state == .writeOnly, "cancelled exit restores Calendar admission")
        let sender = MessagesDirectAccount(id: "synthetic-sender", label: "Synthetic sender")
        let address = "recipient@example.test", text = "Synthetic full text", submissionID = UUID()
        let resolved = MessagesDirectRecipient(account: sender, id: "synthetic-recipient", handle: address,
            expires: Date().addingTimeInterval(250))
        var resolutions = 0, submissions = 0
        try MessagesDirectSubmission.perform(id: submissionID, account: sender, email: address, plaintext: text,
            resolve: { account, email in
                try expect(account == sender && email == address, "single submit resolves exact selected account and email")
                resolutions += 1; return resolved
            }, submit: { proposal in
                try expect(proposal.id == submissionID && proposal.recipient == resolved && proposal.plaintext == text,
                           "submission freezes full text and exact resolved target")
                submissions += 1
            })
        try expect(resolutions == 1 && submissions == 1, "single submit needs no separate recipient-check state")
        do {
            try MessagesDirectSubmission.perform(id: UUID(), account: sender, email: address, plaintext: text,
                resolve: { _, _ in throw AppleDirectFault("recipient_not_unique") }, submit: { _ in submissions += 1 })
            throw Failure.assertion("ambiguous target admitted")
        } catch let fault as AppleDirectFault { try expect(fault.code == "recipient_not_unique" && submissions == 1, "no submission after ambiguous recipient") }
        do {
            try MessagesDirectSubmission.perform(id: UUID(), account: sender, email: address, plaintext: text,
                resolve: { _, _ in .init(account: sender, id: "different", handle: "other@example.test", expires: resolved.expires) },
                submit: { _ in submissions += 1 })
            throw Failure.assertion("changed address admitted")
        } catch let fault as AppleDirectFault { try expect(fault.code == "recipient_changed" && submissions == 1, "no submission after address mismatch") }
        print("PASS Apple automatic refresh: quiet startup; disabled gate; coalescing; backoff; last-known observation; actual denial; pause/stop stale-result rejection; identity-bound cache; Notes/Messages ask=false only; no target launch, metadata, body or effect; Calendar no prompt")
    }
}
