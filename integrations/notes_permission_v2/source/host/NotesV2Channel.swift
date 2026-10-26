import Foundation
import Darwin

// Fixed inherited connected FD; no listener, socket path or caller enrollment.
// An admission closure is mandatory and runs around every read/write wait.
final class NotesV2Channel {
    let fd: Int32
    private let admitted: () throws -> Void
    private var buffer = Data()
    init(fd: Int32, admitted: @escaping () throws -> Void) throws {
        self.fd = fd; self.admitted = admitted
        var one: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size)) == 0 else { throw NativeFault("transport_disconnected") }
    }
    func connected() -> Bool {
        var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        return Darwin.poll(&p, 1, 0) >= 0 && p.revents & Int16(POLLHUP | POLLERR | POLLNVAL) == 0
    }
    private func ready(_ event: Int16, deadline: Double) throws {
        while true {
            try admitted()
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw NativeFault("transport_deadline_exceeded") }
            var p = pollfd(fd: fd, events: event, revents: 0)
            let value = Darwin.poll(&p, 1, Int32(min(100, ceil(remaining * 1000))))
            if value < 0 && errno == EINTR { continue }
            guard value >= 0 else { throw NativeFault("transport_disconnected") }
            if value == 0 { continue }
            guard p.revents & Int16(POLLHUP | POLLERR | POLLNVAL) == 0, p.revents & event != 0 else { throw NativeFault("transport_disconnected") }
            try admitted(); return
        }
    }
    func send(_ raw: Data, deadline: Double, limit: Int = NotesV2Wire.responseLimit) throws {
        guard raw.count + 1 <= limit, !raw.contains(10) else { throw NativeFault("frame_too_large") }
        let frame = raw + Data([10]); var offset = 0
        while offset < frame.count {
            try ready(Int16(POLLOUT), deadline: deadline)
            let sent = frame.withUnsafeBytes { Darwin.send(fd, $0.baseAddress!.advanced(by: offset), frame.count - offset, MSG_DONTWAIT) }
            if sent < 0 && [EINTR, EAGAIN].contains(errno) { continue }
            guard sent > 0 else { throw NativeFault("transport_disconnected") }
            offset += sent
        }
    }
    func receive(deadline: Double, limit: Int = NotesV2Wire.requestLimit) throws -> Data {
        while true {
            try admitted()
            if let newline = buffer.firstIndex(of: 10) {
                let length = buffer.distance(from: buffer.startIndex, to: newline)
                guard length + 1 <= limit else { throw NativeFault("frame_too_large") }
                let frame = Data(buffer.prefix(length)); buffer = Data(buffer.dropFirst(length + 1)); return frame
            }
            guard buffer.count < limit else { throw NativeFault("frame_too_large") }
            try ready(Int16(POLLIN), deadline: deadline)
            var bytes = [UInt8](repeating: 0, count: min(4096, limit - buffer.count))
            let count = Darwin.recv(fd, &bytes, bytes.count, MSG_DONTWAIT)
            if count < 0 && [EINTR, EAGAIN].contains(errno) { continue }
            guard count > 0 else { throw NativeFault("transport_disconnected") }
            buffer.append(contentsOf: bytes.prefix(count))
        }
    }
}
