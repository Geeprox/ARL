import Foundation
import Dispatch

private enum Failure: Error { case check(String) }
private final class Observation: @unchecked Sendable {
    private let lock = NSLock()
    private var failure: String?
    private var dispatches = 0
    func finished(_ error: String?) { lock.withLock { failure = error; if error == nil { dispatches += 1 } } }
    func value() -> (String?, Int) { lock.withLock { (failure, dispatches) } }
}

@main enum MusicWriteRecoveryConcurrencyTests {
    static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure.check(message) }
    }
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { throw Failure.check("owned root") }
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).appendingPathComponent("competition")
        let first = FileMusicWriteJournal(directory: directory)
        let second = FileMusicWriteJournal(directory: directory) // independent NSLock and file descriptor
        let request = try MusicWriteRequest(requestID: UUID(), intent: .createPlaylist, name: "Synthetic competition")
        let reference = UUID(), epoch = UUID()
        let original = MusicWriteRecord(request: request, reference: reference, epoch: epoch, baseline: [])
        try first.transaction { ledger in
            ledger.epochs[reference.uuidString] = epoch
            ledger.records[request.requestID.uuidString] = original
        }
        try first.recoveryTransaction { _, ledger in
            ledger.records[request.requestID.uuidString] = .init(request: request, reference: reference,
                epoch: epoch, reason: .userRequestedOnce, decidedAt: Date())
        }
        let originalBytes = try Data(contentsOf: directory.appendingPathComponent("write-ledger.json"))
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
        let observation = Observation()
        DispatchQueue.global().async {
            defer { done.signal() }
            do {
                try first.recoveryTransaction { _, ledger in
                    guard var value = ledger.records[request.requestID.uuidString], value.mayReserve else { throw Failure.check("first reservation") }
                    entered.signal()
                    guard release.wait(timeout: .now() + 8) == .success else { throw Failure.check("release timeout") }
                    value.attempts.append(original)
                    ledger.records[request.requestID.uuidString] = value
                }
                // Effect boundary is reached only after durable reservation returns.
                observation.finished(nil)
            } catch { observation.finished(String(describing: error)) }
        }
        guard entered.wait(timeout: .now() + 8) == .success else { release.signal(); throw Failure.check("first entered timeout") }
        var secondBodyEntered = false, secondBusy = false, secondDispatches = 0
        do {
            let reserved = try second.recoveryTransaction { _, ledger in
                secondBodyEntered = true
                guard var value = ledger.records[request.requestID.uuidString], value.mayReserve else { return false }
                value.attempts.append(original); ledger.records[request.requestID.uuidString] = value
                return true
            }
            if reserved { secondDispatches += 1 }
        } catch CredentialError.busy { secondBusy = true }
        catch { release.signal(); _ = done.wait(timeout: .now() + 8); throw error }
        release.signal()
        try check(done.wait(timeout: .now() + 8) == .success, "first completion")
        let observed = observation.value()
        try check(observed.0 == nil && observed.1 == 1, "first durable reservation")
        try check(secondBusy && !secondBodyEntered && secondDispatches == 0, "second must fail before transaction body")
        let readback = try second.inspectRecovery(requestID: request.requestID)
        try check(readback?.attempts.count == 1 && readback?.mayReserve == false, "second sees consumed attempt")
        let after = try second.recoveryTransaction { _, ledger in
            guard let value = ledger.records[request.requestID.uuidString] else { throw Failure.check("missing decision") }
            return value.mayReserve
        }
        if after { secondDispatches += 1 }
        try check(!after && secondDispatches == 0, "subsequent call cannot dispatch")
        try check(try Data(contentsOf: directory.appendingPathComponent("write-ledger.json")) == originalBytes, "original ledger byte identical")
        print("{\"status\":\"PASS\",\"groups\":[\"independent_journal_exclusive_reservation\"],\"second_body_entered\":false,\"first_mock_dispatches\":1,\"second_mock_dispatches\":0,\"original_ledger_unchanged\":true,\"real_keychain\":0,\"real_provider\":0}")
    }
}
