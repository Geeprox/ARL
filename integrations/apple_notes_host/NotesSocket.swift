import Foundation
import Darwin

// Connected FD supplied ONLY by a controlled parent. No path/listener/command
// input. Caller and helper each verify their own pinned, registered peer.
@MainActor final class NotesFDChannel {
    private let fd: Int32
    private let peer: AuthenticatedCaller
    private var buffer = Data()
    init(fd: Int32, registration: NotesPeerRegistration) throws {
        peer = try AuthenticatedCaller.fromRegisteredSocket(fd, subject: registration.subject, expectedPID: registration.pid,
            requirement: registration.requirement, registrationEpoch: registration.epoch, currentRegistrationEpoch: registration.currentEpoch)
        self.fd = fd
        var one: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size)) == 0 else { throw ReviewFault("transport_disconnected") }
    }
    private func ready(_ event: Int16, deadline: Double) throws {
        while true {
            guard peer.isCurrent() else { throw ReviewFault("caller_unverified") }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw ReviewFault("transport_deadline_exceeded") }
            var p = pollfd(fd: fd, events: event, revents: 0)
            let result = Darwin.poll(&p, 1, Int32(min(100, ceil(remaining * 1000))))
            if result < 0 && errno == EINTR { continue }
            guard result >= 0 else { throw ReviewFault("transport_disconnected") }
            if result == 0 { continue } // polling slice is NOT the overall deadline
            if p.revents & event != 0 { return }
            throw ReviewFault("transport_disconnected")
        }
    }
    func send(_ frame: Data, deadline: Double, limit: Int) throws {
        guard frame.count + 1 <= limit, !frame.contains(10) else { throw ReviewFault("frame_too_large") }
        let data = frame + Data([10]); var offset = 0
        while offset < data.count {
            try ready(Int16(POLLOUT), deadline: deadline)
            let sent = data.withUnsafeBytes { Darwin.send(fd, $0.baseAddress!.advanced(by: offset), data.count - offset, MSG_DONTWAIT) }
            if sent < 0 && [EINTR, EAGAIN].contains(errno) { continue }
            guard sent > 0 else { throw ReviewFault("transport_disconnected") }
            offset += sent
        }
    }
    private func extract(limit: Int) throws -> Data? {
        if let line = buffer.firstIndex(of: 10) {
            guard line + 1 <= limit else { throw ReviewFault("frame_too_large") }
            let frame = Data(buffer.prefix(line)); buffer.removeFirst(line + 1)
            return frame
        }
        guard buffer.count < limit else { throw ReviewFault("frame_too_large") }
        return nil
    }
    func receiveIfAvailable(limit: Int) throws -> Data? {
        guard peer.isCurrent() else { throw ReviewFault("caller_unverified") }
        if let frame = try extract(limit: limit) { return frame }
        var bytes = [UInt8](repeating: 0, count: min(4096, limit - buffer.count))
        let count = Darwin.recv(fd, &bytes, bytes.count, MSG_DONTWAIT)
        if count < 0 && [EINTR, EAGAIN].contains(errno) { return nil }
        guard count > 0 else { throw ReviewFault("transport_disconnected") }
        buffer.append(contentsOf: bytes.prefix(count))
        return try extract(limit: limit)
    }
    func receive(deadline: Double, limit: Int) throws -> Data {
        while true {
            if let frame = try receiveIfAvailable(limit: limit) { return frame }
            try ready(Int16(POLLIN), deadline: deadline)
        }
    }
}

@MainActor final class NotesSocketConsumerTransport: NotesFrameTransport {
    private let channel: NotesFDChannel
    init(channel: NotesFDChannel) { self.channel = channel }
    func exchange(_ frame: Data, deadline: Double) throws -> Data {
        try channel.send(frame, deadline: deadline, limit: NotesWire.maxRequestFrame)
        return try channel.receive(deadline: deadline, limit: NotesWire.maxResponseFrame)
    }
}

// Headless host IO only; native review runs in the dedicated helper, not ARL's
// background worker. Call serveOne from its main actor after controlled setup.
@MainActor final class NotesHostConnection {
    private let channel: NotesFDChannel
    private var session: NotesHostSession!
    private var deadline: Double = 0
    init(fd: Int32, registration: NotesPeerRegistration, engine: NotesApprovalEngine,
         reviewer: NotesReviewer = NativeNotesReviewer(), effects: NotesEffects = NativeNotesEffects()) throws {
        channel = try NotesFDChannel(fd: fd, registration: registration)
        session = try NotesHostSession.fromRegisteredSocket(fd, registration: registration, engine: engine, reviewer: reviewer, effects: effects,
            externallyCancelled: { [weak self] in self?.pollCancellation() ?? true })
    }
    private func pollCancellation() -> Bool {
        do {
            guard let frame = try channel.receiveIfAvailable(limit: 1024) else { return false }
            let v = try flatObject(frame, limit: 1023)
            guard v["method"] as? String == "cancel" else { session.disconnect(); return true }
            let ack = try session.handle(frame)
            try channel.send(ack, deadline: deadline, limit: NotesWire.maxResponseFrame)
            // Session remembers only a correctly bound cancellation; a rejected
            // cancel does not switch authority or cancel a different operation.
            return (try flatObject(ack, limit: NotesWire.maxResponseFrame - 1))["status"] as? String == "ok"
        } catch { session.disconnect(); return true }
    }
    func serveOne(deadline: Double) throws {
        self.deadline = deadline
        let frame = try channel.receive(deadline: deadline, limit: NotesWire.maxRequestFrame)
        let result = try session.handle(frame)
        try channel.send(result, deadline: deadline, limit: NotesWire.maxResponseFrame)
    }
}
