import Foundation
import Darwin
import Security

private enum CheckFailure: Error { case failed(String) }
private final class Outcome: @unchecked Sendable {
    private let lock = NSLock()
    private var failure: Error?
    func fail(_ error: Error) { lock.withLock { failure = error } }
    func check() throws { try lock.withLock { if let failure { throw failure } } }
}

@main enum OwnerReadHandshakeTests {
    static func expect(_ value: Bool, _ label: String) throws {
        guard value else { throw CheckFailure.failed(label) }
    }
    static func pair() throws -> (Int32, Int32) {
        var fds: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw CheckFailure.failed("socketpair") }
        do { try OwnerReadSocket.configure(fds[0]); try OwnerReadSocket.configure(fds[1]) }
        catch { close(fds[0]); close(fds[1]); throw error }
        return (fds[0], fds[1])
    }
    static func signedPeer(_ fd: Int32, wrongRequirement: Bool = false) throws {
        // Kernel audit evidence and actual dynamic/static Security verification
        // of this isolated signed fixture; no grant or production app is used.
        let token = try OwnerReadPeer.audit(fd)
        let pid = token.withUnsafeBytes { pid_t($0.loadUnaligned(fromByteOffset: 20, as: UInt32.self)) }
        _ = try OwnerReadPeer.process(pid)
        guard pid == getpid() else { throw OwnerReadFault.identity }
        var guest: SecCode?, code: SecStaticCode?, requirement: SecRequirement?
        if wrongRequirement {
            guard SecRequirementCreateWithString("cdhash H\"0000000000000000000000000000000000000000\"" as CFString,
                [], &requirement) == errSecSuccess else { throw OwnerReadFault.identity }
        }
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit as String: token] as CFDictionary, [], &guest) == errSecSuccess,
              let guest, SecCodeCheckValidity(guest, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess,
              SecCodeCopyStaticCode(guest, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode), requirement) == errSecSuccess
        else { throw OwnerReadFault.identity }
    }
    static func send(_ fd: Int32, _ bytes: [UInt8]) throws {
        try bytes.withUnsafeBytes { raw in
            guard Darwin.write(fd, raw.baseAddress, raw.count) == raw.count else { throw CheckFailure.failed("fragment_write") }
        }
    }
    static func slowVerificationRoundtrip() throws {
        let (client, server) = try pair()
        defer { close(client); close(server) }
        let outcome = Outcome(), group = DispatchGroup()
        let began = OwnerReadSocket.now
        group.enter()
        DispatchQueue.global().async {
            defer { group.leave() }
            do {
                let accepted = OwnerReadSocket.now
                let admission = OwnerReadAdmission(started: accepted, overallDeadline: accepted + 20)
                try admission.verifying(cancelled: { false }) {
                    Thread.sleep(forTimeInterval: 2.1); try signedPeer(server)
                }
                try OwnerReadSocket.writeFrame(Data("hello".utf8), fd: server, limit: 1024,
                    deadline: admission.frameDeadline, cancelled: { false })
                let request = try OwnerReadSocket.readFrame(server, limit: 1024, deadline: admission.deadline,
                    firstByteFrameSeconds: OwnerReadWire.frameSeconds, cancelled: { false })
                try expect(request == Data("synthetic request".utf8), "request_after_slow_client_verification")
                try admission.verifying(cancelled: { false }) { try signedPeer(server) }
            } catch { outcome.fail(error) }
        }
        let admission = OwnerReadAdmission(started: began, overallDeadline: began + 20)
        try admission.verifying(cancelled: { false }) { try signedPeer(client) }
        let hello = try OwnerReadSocket.readFrame(client, limit: 1024, deadline: admission.deadline,
            firstByteFrameSeconds: OwnerReadWire.frameSeconds, cancelled: { false })
        try expect(hello == Data("hello".utf8), "hello_after_slow_owner_verification")
        try admission.verifying(cancelled: { false }) {
            Thread.sleep(forTimeInterval: 2.1); try signedPeer(client)
        }
        try OwnerReadSocket.writeFrame(Data("synthetic request".utf8), fd: client, limit: 1024,
            deadline: admission.frameDeadline, cancelled: { false })
        try expect(group.wait(timeout: .now() + 12) == .success, "signed_roundtrip_drained")
        try outcome.check()
        let elapsed = OwnerReadSocket.now - began
        try expect(elapsed > 4 && elapsed < 10, "segmented_verifications_share_ten_second_window")
    }
    static func firstByteAndFragmentDeadlines() throws {
        for slow in [false, true] {
            let (reader, writer) = try pair()
            defer { close(reader); close(writer) }
            let outcome = Outcome(), group = DispatchGroup()
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                do {
                    let delay = slow ? 1.1 : 0.05
                    try send(writer, [0]); Thread.sleep(forTimeInterval: delay)
                    try send(writer, [0]); Thread.sleep(forTimeInterval: delay)
                    try send(writer, [0, 1, 120])
                } catch { outcome.fail(error) }
            }
            let began = OwnerReadSocket.now
            do {
                let data = try OwnerReadSocket.readFrame(reader, limit: 1024, deadline: began + 10,
                    firstByteFrameSeconds: OwnerReadWire.frameSeconds, cancelled: { false })
                try expect(!slow && data == Data([120]), "fast_fragmented_frame")
            } catch let fault as OwnerReadFault {
                try expect(slow && fault == .deadline, "slow_fragmented_frame_rejected")
            }
            try expect(group.wait(timeout: .now() + 3) == .success, "fragment_writer_drained")
            try outcome.check()
        }
    }
    static func lateVerificationCannotSend() throws {
        let (client, server) = try pair()
        defer { close(client); close(server) }
        let began = OwnerReadSocket.now
        let admission = OwnerReadAdmission(started: began, overallDeadline: began + 0.2)
        do {
            try admission.verifying(cancelled: { false }) { Thread.sleep(forTimeInterval: 0.1); try signedPeer(client) }
            try admission.verifying(cancelled: { false }) { Thread.sleep(forTimeInterval: 0.15); try signedPeer(client) }
            try OwnerReadSocket.writeFrame(Data([1]), fd: client, limit: 1024,
                deadline: admission.frameDeadline, cancelled: { false })
            throw CheckFailure.failed("late_verification_admitted")
        } catch let fault as OwnerReadFault { try expect(fault == .deadline, "overall_budget_not_renewed") }
        var byte: UInt8 = 0
        try expect(recv(server, &byte, 1, MSG_PEEK | MSG_DONTWAIT) < 0 && errno == EAGAIN, "expired_verification_sent_no_frame")
        let capped = OwnerReadAdmission(started: began, overallDeadline: began + 210)
        try expect(capped.deadline == began + 10, "admission_capped_at_ten")
    }
    static func rejectedSignatureAndCancellation() throws {
        let (client, server) = try pair()
        defer { close(client); close(server) }
        let began = OwnerReadSocket.now
        let admission = OwnerReadAdmission(started: began, overallDeadline: began + 20)
        do {
            try admission.verifying(cancelled: { false }) { try signedPeer(client, wrongRequirement: true) }
            throw CheckFailure.failed("wrong_signature_admitted")
        } catch let fault as OwnerReadFault { try expect(fault == .identity, "signature_rejection_preserved") }
        let stop = OwnerReadStop(), group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { Thread.sleep(forTimeInterval: 0.05); stop.cancel(); group.leave() }
        do {
            _ = try OwnerReadSocket.readFrame(client, limit: 1024, deadline: admission.deadline,
                firstByteFrameSeconds: OwnerReadWire.frameSeconds, cancelled: { stop.cancelled })
            throw CheckFailure.failed("cancel_not_observed")
        } catch let fault as OwnerReadFault { try expect(fault == .cancelled, "cancellation_preserved") }
        try expect(group.wait(timeout: .now() + 1) == .success, "canceller_drained")
    }
    static func main() throws {
        try slowVerificationRoundtrip()
        try firstByteAndFragmentDeadlines()
        try lateVerificationCannotSend()
        try rejectedSignatureAndCancellation()
        try expect(OwnerReadWire.seconds(for: "mio_reminders_get") == 210 &&
            OwnerReadWire.seconds(for: "mio_nas_read_text") == 110 &&
            OwnerReadWire.seconds(for: "mio_netease_song_search") == 35 &&
            OwnerReadWire.seconds(for: "mio_maps_geo") == 20, "existing_tool_budgets_preserved")
        print("PASS 8 real socket/signature owner admission checks; live calls 0")
    }
}
