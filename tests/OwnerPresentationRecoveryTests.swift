import Foundation
import Darwin

private enum FixtureFailure: Error { case check(String) }
private final class Latch: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    var waiting: Bool { lock.withLock { continuation != nil } }
    func wait() async {
        await withCheckedContinuation { value in
            let done = lock.withLock { () -> Bool in
                if released { return true }; continuation = value; return false
            }
            if done { value.resume() }
        }
    }
    func release() {
        let value = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            released = true; defer { continuation = nil }; return continuation
        }
        value?.resume()
    }
}

@main enum OwnerPresentationRecoveryTests {
    static func check(_ value: Bool, _ label: String) throws { if !value { throw FixtureFailure.check(label) } }
    static func until(_ condition: @Sendable () -> Bool) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition() && ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(2)) }
        try check(condition(), "bounded_join")
    }
    static func main() async throws {
        // R13: a failed refresh keeps dated success; invalidated callbacks and
        // their defers cannot overwrite or finish the replacement generation.
        var view = TaobaoConnectionPresentation()
        let ready = TaobaoConnectionState(state: "protocol_ready", available: ["search_products"], unsupported: [])
        let failed = TaobaoConnectionState(state: "unreachable", available: [], unsupported: [])
        let first = view.begin(.check), date = Date(timeIntervalSince1970: 100)
        try check(view.receive(ready, for: first, at: date), "first_success")
        view.finish(first)
        let refresh = view.begin(.check)
        try check(view.snapshot.state == "protocol_ready" && view.checkedAt == date, "refresh_retains")
        view.receive(failed, for: refresh, at: date.addingTimeInterval(1)); view.finish(refresh)
        try check(view.stale && view.checkedAt == date && view.snapshot.state == "protocol_ready" && view.display.state == "unreachable", "failure_retains")
        let old = view.begin(.search)
        view.invalidate(.appChanged)
        let current = view.begin(.check)
        try check(!view.receive(ready, for: old, at: date) && !view.finish(old) && view.active == current, "old_callback_and_defer")
        let now = date.addingTimeInterval(2)
        view.receive(ready, for: current, at: now); view.finish(current)
        try check(!view.stale && view.checkedAt == now && view.failure == nil, "normal_recovery")

        // R12: publication of a result/cancellation is not Task.value joining.
        let life = OwnerReadLifecycle(), latch = Latch()
        life.listening()
        let token = life.reserveOperation()!
        let work = Task.detached { await latch.wait() }
        life.retain(work, for: token)
        try await until { latch.waiting }
        try check(life.reserveOperation() == nil, "serial_admission")
        life.fail(.taskPending); life.cancel()
        life.listenerClosed(cleanupProven: true)
        let worker = Task.detached {}
        life.observeWorker(worker)
        try await until { life.snapshot.workerJoined }
        try check(!life.snapshot.drained && life.snapshot.operationPending && !life.operationEnded(token), "cancel_not_join")
        latch.release()
        try await until { life.snapshot.drained }
        try check(life.snapshot.canRequestRecovery && life.operationEnded(token), "joined_recovery")
        let normal = OwnerReadLifecycle()
        normal.listening()
        let normalToken = normal.reserveOperation()!
        normal.retain(Task.detached {}, for: normalToken)
        try await until { normal.operationEnded(normalToken) }
        guard let next = normal.reserveOperation() else { throw FixtureFailure.check("next_normal_request") }
        normal.retain(Task.detached {}, for: next)
        try await until { normal.operationEnded(next) }
        normal.listenerClosed(cleanupProven: true); normal.observeWorker(Task.detached {})
        try await until { normal.snapshot.drained }

        // An injected post-bind failure removes only its exact owned socket.
        // This private temporary endpoint never equals the installed endpoint.
        let root = "/private/tmp/arl-r5-" + UUID().uuidString
        try check(mkdir(root, 0o700) == 0, "owned_directory")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let path = root + "/s"
        do { _ = try OwnerReadSocket.fixtureListener(path: path, failAfterBind: true); throw FixtureFailure.check("injection_missed") }
        catch let fault as OwnerReadFault { try check(fault == .unavailable, "postbind_fault") }
        try check(!FileManager.default.fileExists(atPath: path), "postbind_cleaned")
        let listener = try OwnerReadSocket.fixtureListener(path: path)
        try check(close(listener.fd) == 0, "normal_close")
        try check(OwnerReadSocket.fixtureRemove(path: path, device: listener.device, inode: listener.inode), "normal_remove")
        try Data("unrelated synthetic file".utf8).write(to: URL(fileURLWithPath: path))
        try check(!OwnerReadSocket.fixtureRemove(path: path, device: listener.device, inode: listener.inode), "foreign_file_preserved")
        try check(try Data(contentsOf: URL(fileURLWithPath: path)) == Data("unrelated synthetic file".utf8), "foreign_bytes_preserved")
        print("{\"status\":\"PASS\",\"groups\":[\"R13_generation_and_dated_results\",\"R12_task_join_and_owned_socket\"],\"real_services\":0,\"business_calls\":0}")
    }
}
