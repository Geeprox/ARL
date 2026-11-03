import Foundation
import CryptoKit
import SQLite3
import Darwin

struct MessagesReceiveFault: Error, Sendable { let code: String; init(_ code: String) { self.code = code } }
struct MessagesReceiveSource: Codable, Equatable, Sendable { let volumeUUID: String; let inode: UInt64; let birth: String }
struct MessagesReceiveConversation: Codable, Equatable, Identifiable, Sendable {
    let rowID: Int64
    let guid: String
    let account: String
    let name: String
    let participants: [String]
    var id: String { guid }
}
struct MessagesReceiveSelection: Codable, Sendable {
    let source: MessagesReceiveSource
    let conversation: MessagesReceiveConversation
    let observedAt: Date
}
struct MessagesReceiveSelectionPage: Sendable {
    let entries: [MessagesReceiveSelection]
    let nextBeforeRowID: Int64?
    let excludedCount: Int
}
struct MessagesReceiveScope: Codable, Sendable {
    let id: UUID
    let source: MessagesReceiveSource
    let conversation: MessagesReceiveConversation
    let consumerAppID: String
    let startRowID: Int64
    let startedAt: Date
}
struct MessagesReceiveEvent: Codable, Equatable, Sendable {
    let rowID: Int64
    let guid: String
    let sender: String
    let text: String?
    let appleDate: Int64
    let coverage: String
}
struct MessagesReceiveBatch: Codable, Sendable {
    let id: UUID
    let scopeID: UUID
    let events: [MessagesReceiveEvent]
    var digest: String { MessagesReceiveEncoding.hash(try! MessagesReceiveEncoding.encode(self)) }
}
struct MessagesReceiveStatus: Codable, Sendable {
    let enabled: Bool
    let running: Bool
    let scope: MessagesReceiveScope?
    let pendingCount: Int
    let cursor: Int64
}
/// Constructed by the existing signed/kernel-peer transport. It is deliberately
/// not Codable: JSON parameters can never create an authenticated binding.
struct MessagesReceiveConsumer: Sendable {
    let appID: String
    let sessionID: String
    let registrationGeneration: String
    let authorizedCapabilities: Set<String>
}
private enum MessagesReceiveEncoding {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func text(_ value: String, maximum: Int = 1024) throws {
        guard !value.isEmpty, value.utf8.count <= maximum, !value.contains("\0") else { throw MessagesReceiveFault("invalid_receive_scope") }
    }
}

/// Only fixed SELECT statements run against a normal read-only SQLite connection.
/// No immutable=1, copying a live DB without its WAL, private framework or child
/// process receives the protected database. Schema changes fail explicitly.
final class MessagesReceiveDatabase {
    static var liveURL: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Messages/chat.db") }
    private let url: URL
    private let db: OpaquePointer
    let source: MessagesReceiveSource
    private let liveDevice: dev_t
    private var deadline = ProcessInfo.processInfo.systemUptime + 3
    private static func identity(_ url: URL) throws -> MessagesReceiveSource {
        // Validate the actual components below with openat/O_NOFOLLOW. Foundation
        // may rewrite a valid /private/var temporary path while standardizing it.
        guard url.isFileURL, url.path.hasPrefix("/"), !url.path.contains("\0"),
              url.path.split(separator: "/").allSatisfy({ $0 != "." && $0 != ".." }) else { throw MessagesReceiveFault("unsafe_messages_database") }
        var directory = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw MessagesReceiveFault("messages_database_unavailable") }
        defer { close(directory) }
        for component in url.deletingLastPathComponent().path.split(separator: "/") {
            let child = openat(directory, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard child >= 0 else { throw MessagesReceiveFault("messages_database_unavailable") }
            close(directory); directory = child
        }
        var parent = stat(), info = stat()
        guard fstat(directory, &parent) == 0, parent.st_uid == getuid(), parent.st_mode & 0o022 == 0,
              fstatat(directory, url.lastPathComponent, &info, AT_SYMLINK_NOFOLLOW) == 0,
              info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1, info.st_mode & 0o022 == 0 else {
            throw MessagesReceiveFault("unsafe_messages_database")
        }
        for suffix in ["-wal", "-shm", "-journal"] {
            var sidecar = stat()
            if fstatat(directory, url.lastPathComponent + suffix, &sidecar, AT_SYMLINK_NOFOLLOW) == 0 {
                guard sidecar.st_mode & S_IFMT == S_IFREG, sidecar.st_uid == getuid(), sidecar.st_nlink == 1,
                      sidecar.st_mode & 0o022 == 0 else { throw MessagesReceiveFault("unsafe_messages_sidecar") }
            } else if errno != ENOENT { throw MessagesReceiveFault("messages_database_unavailable") }
        }
        guard let volume = try? url.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString,
              !volume.isEmpty else { throw MessagesReceiveFault("messages_volume_identity_unavailable") }
        return .init(volumeUUID: volume, inode: UInt64(info.st_ino), birth: "\(info.st_birthtimespec.tv_sec):\(info.st_birthtimespec.tv_nsec)")
    }
    init(url: URL) throws {
        self.url = url; source = try Self.identity(url)
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw MessagesReceiveFault("messages_database_unavailable") }
        liveDevice = info.st_dev
        var connection: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_NOFOLLOW
        guard sqlite3_open_v2(url.path, &connection, flags, nil) == SQLITE_OK, let connection else {
            if let connection { sqlite3_close(connection) }
            throw MessagesReceiveFault("messages_database_permission_or_availability")
        }
        db = connection
        do {
            guard sqlite3_db_readonly(db, "main") == 1 else { throw MessagesReceiveFault("messages_database_not_read_only") }
            sqlite3_busy_timeout(db, 250)
            // System SQLite does not expose its load-extension API. No SQL or
            // extension path is accepted from a caller; only fixed statements.
            sqlite3_limit(db, SQLITE_LIMIT_LENGTH, 1024 * 1024)
            sqlite3_progress_handler(db, 1000, { context in
                guard let context else { return 1 }
                let value = Unmanaged<MessagesReceiveDatabase>.fromOpaque(context).takeUnretainedValue()
                return ProcessInfo.processInfo.systemUptime < value.deadline ? 0 : 1
            }, Unmanaged.passUnretained(self).toOpaque())
            try execute("PRAGMA query_only=ON"); try execute("PRAGMA trusted_schema=OFF")
            try verifyIdentity()
            for (table, required) in [
                ("chat", Set(["guid", "account_login", "display_name", "service_name"])),
                ("handle", Set(["id", "service"])),
                ("chat_handle_join", Set(["chat_id", "handle_id"])),
                ("chat_message_join", Set(["chat_id", "message_id"])),
                ("message", Set(["guid", "text", "attributedBody", "handle_id", "is_from_me", "date", "service", "associated_message_type", "item_type"]))
            ] {
                let realTable = try statement("SELECT sql FROM sqlite_master WHERE type='table' AND name=?", strings: [table])
                defer { sqlite3_finalize(realTable) }
                guard sqlite3_step(realTable) == SQLITE_ROW, let definition = string(realTable, 0),
                      !definition.uppercased().contains("VIRTUAL TABLE") else { throw MessagesReceiveFault("unsupported_messages_schema") }
                let columns = try statement("PRAGMA table_info(\(table))")
                var available = Set<String>()
                while try step(columns) { if let name = string(columns, 1) { available.insert(name) } }
                sqlite3_finalize(columns)
                guard required.isSubset(of: available) else { throw MessagesReceiveFault("unsupported_messages_schema") }
            }
            let journal = try statement("PRAGMA journal_mode"); defer { sqlite3_finalize(journal) }
            if sqlite3_step(journal) == SQLITE_ROW, string(journal, 0)?.lowercased() == "wal" {
                // A live WAL must use its existing sidecars; do not pretend the
                // database is immutable or initialize missing shared state.
                guard access(url.path + "-wal", R_OK) == 0, access(url.path + "-shm", R_OK) == 0 else {
                    throw MessagesReceiveFault("messages_wal_not_ready")
                }
            }
        } catch { sqlite3_progress_handler(db, 0, nil, nil); throw error }
    }
    deinit { sqlite3_progress_handler(db, 0, nil, nil); sqlite3_close(db) }
    private func verifyIdentity() throws {
        var current = stat()
        guard try Self.identity(url) == source, lstat(url.path, &current) == 0, current.st_dev == liveDevice else { throw MessagesReceiveFault("messages_database_changed") }
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw MessagesReceiveFault("messages_read_deadline") }
    }
    private func statement(_ sql: String, strings: [String] = [], integers: [Int64] = []) throws -> OpaquePointer {
        try verifyIdentity()
        var value: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &value, nil) == SQLITE_OK, let value else { throw MessagesReceiveFault("unsupported_messages_schema") }
        for (index, string) in strings.enumerated() {
            guard sqlite3_bind_text(value, Int32(index + 1), string, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) == SQLITE_OK else {
                sqlite3_finalize(value); throw MessagesReceiveFault("messages_read_failed")
            }
        }
        for (index, integer) in integers.enumerated() { sqlite3_bind_int64(value, Int32(strings.count + index + 1), integer) }
        return value
    }
    private func step(_ value: OpaquePointer) throws -> Bool {
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw MessagesReceiveFault("messages_read_deadline") }
        let result = sqlite3_step(value)
        guard result == SQLITE_ROW || result == SQLITE_DONE else { throw MessagesReceiveFault("messages_read_failed") }
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw MessagesReceiveFault("messages_read_deadline") }
        return result == SQLITE_ROW
    }
    private func string(_ value: OpaquePointer, _ index: Int32, maximum: Int = 4096) -> String? {
        guard sqlite3_column_type(value, index) == SQLITE_TEXT, sqlite3_column_bytes(value, index) <= maximum,
              let raw = sqlite3_column_text(value, index) else { return nil }
        let bytes = UnsafeBufferPointer(start: raw, count: Int(sqlite3_column_bytes(value, index)))
        return String(bytes: bytes, encoding: .utf8)
    }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw MessagesReceiveFault("messages_read_failed") }
    }
    func snapshot<T>(_ body: () throws -> T) throws -> T {
        deadline = ProcessInfo.processInfo.systemUptime + 3
        try execute("BEGIN"); defer { try? execute("ROLLBACK") }
        let value = try body(); try verifyIdentity(); return value
    }
    func highWater() throws -> Int64 {
        let value = try statement("SELECT COALESCE(MAX(ROWID),0) FROM message"); defer { sqlite3_finalize(value) }
        guard try step(value) else { throw MessagesReceiveFault("messages_read_failed") }
        return sqlite3_column_int64(value, 0)
    }
    func conversations(before: Int64 = .max) throws -> (entries: [MessagesReceiveConversation], next: Int64?, excluded: Int) {
        guard before > 0 else { throw MessagesReceiveFault("invalid_receive_request") }
        let value = try statement("SELECT ROWID,guid,account_login,COALESCE(display_name,'') FROM chat WHERE service_name='iMessage' AND ROWID<? ORDER BY ROWID DESC LIMIT 201", integers: [before])
        defer { sqlite3_finalize(value) }
        var rows: [MessagesReceiveConversation] = [], scanned = 0, excluded = 0, last: Int64?
        while try step(value) {
            if scanned == 200 { return (rows, last, excluded) }
            let rowID = sqlite3_column_int64(value, 0)
            scanned += 1; last = rowID
            guard let guid = string(value, 1, maximum: 1024), let account = string(value, 2, maximum: 1024),
                  !guid.isEmpty, !account.isEmpty, let name = string(value, 3, maximum: 4096) else { excluded += 1; continue }
            let participants: [String]
            do { participants = try members(rowID) }
            catch let fault as MessagesReceiveFault where fault.code == "unsupported_messages_conversation" { excluded += 1; continue }
            guard (1...16).contains(participants.count) else { excluded += 1; continue }
            rows.append(.init(rowID: rowID, guid: guid, account: account, name: name, participants: participants))
            if try MessagesReceiveEncoding.encode(rows.last!).count > 16 * 1024 { rows.removeLast(); excluded += 1 }
        }
        return (rows, nil, excluded)
    }
    private func members(_ rowID: Int64) throws -> [String] {
        let value = try statement("SELECT h.id,h.service FROM chat_handle_join j JOIN handle h ON h.ROWID=j.handle_id WHERE j.chat_id=? ORDER BY h.id LIMIT 18", integers: [rowID])
        defer { sqlite3_finalize(value) }
        var rows: [String] = []
        while try step(value) {
            guard rows.count < 16, let address = string(value, 0, maximum: 1024), !address.isEmpty,
                  string(value, 1) == "iMessage", !rows.contains(address) else { throw MessagesReceiveFault("unsupported_messages_conversation") }
            rows.append(address)
        }
        return rows
    }
    func verify(_ expected: MessagesReceiveConversation) throws {
        guard try MessagesReceiveEncoding.encode(expected).count <= 16 * 1024 else { throw MessagesReceiveFault("unsupported_messages_conversation") }
        let value = try statement("SELECT guid,account_login,COALESCE(display_name,''),service_name FROM chat WHERE ROWID=?", integers: [expected.rowID])
        defer { sqlite3_finalize(value) }
        guard try step(value), string(value, 0) == expected.guid, string(value, 1) == expected.account,
              string(value, 2) == expected.name, string(value, 3) == "iMessage", try members(expected.rowID) == expected.participants else {
            throw MessagesReceiveFault("messages_receive_scope_changed")
        }
    }
    func read(_ conversation: MessagesReceiveConversation, after cursor: Int64, through high: Int64) throws -> (cursor: Int64, events: [MessagesReceiveEvent]) {
        let value = try statement("SELECT m.ROWID,m.guid,CASE WHEN m.is_from_me=0 AND m.associated_message_type=0 AND m.item_type=0 THEN m.text ELSE NULL END,CASE WHEN m.is_from_me=0 AND m.associated_message_type=0 AND m.item_type=0 THEN length(m.attributedBody) ELSE NULL END,h.id,m.is_from_me,m.date,m.service,m.associated_message_type,m.item_type FROM message m JOIN chat_message_join j ON j.message_id=m.ROWID LEFT JOIN handle h ON h.ROWID=m.handle_id WHERE j.chat_id=? AND m.ROWID>? AND m.ROWID<=? ORDER BY m.ROWID LIMIT 32", integers: [conversation.rowID, cursor, high])
        defer { sqlite3_finalize(value) }
        var last = cursor, events: [MessagesReceiveEvent] = []
        while try step(value) {
            let rowID = sqlite3_column_int64(value, 0)
            guard rowID > last else { throw MessagesReceiveFault("messages_read_changed") }
            guard sqlite3_column_int(value, 5) == 0 else { last = rowID; continue }
            guard let guid = string(value, 1, maximum: 1024), !guid.isEmpty, let sender = string(value, 4, maximum: 1024),
                  conversation.participants.contains(sender), string(value, 7) == "iMessage" else { throw MessagesReceiveFault("messages_receive_scope_changed") }
            // No NSKeyedUnarchiver/private attributedBody decoder or guessed
            // text. Retain an explicit unsupported event so the cursor cannot
            // make missing rich text look like an empty conversation.
            let body = string(value, 2, maximum: 65536)
            let attributed = sqlite3_column_type(value, 3) != SQLITE_NULL && sqlite3_column_int64(value, 3) > 0
            let ordinary = sqlite3_column_int(value, 8) == 0 && sqlite3_column_int(value, 9) == 0
            let presentButUndecodable = body == nil && sqlite3_column_type(value, 2) == SQLITE_TEXT && sqlite3_column_bytes(value, 2) > 0
            let coverage = !ordinary ? "unsupported_message_kind" : presentButUndecodable ? "unsupported_or_oversize_plain_text" : body == nil || body!.isEmpty ? (attributed ? "unsupported_attributed_body" : "no_plain_text") : "plain_text_only"
            var event = MessagesReceiveEvent(rowID: rowID, guid: guid, sender: sender, text: ordinary ? body : nil,
                                             appleDate: sqlite3_column_int64(value, 6), coverage: coverage)
            if try MessagesReceiveEncoding.encode(event).count > 64 * 1024 {
                event = .init(rowID: rowID, guid: guid, sender: sender, text: nil, appleDate: event.appleDate, coverage: "body_exceeds_receive_budget")
            }
            guard try MessagesReceiveEncoding.encode(events + [event]).count <= 64 * 1024 else { break }
            events.append(event); last = rowID
        }
        return (last, events)
    }
}

private struct MessagesReceiveAcknowledgment: Codable {
    let scopeID: UUID
    let batchID: UUID
    let digest: String
}
private struct MessagesReceiveState: Codable {
    var version = 1
    var enabled = false
    var scope: MessagesReceiveScope?
    var cursor: Int64 = 0
    var pending: MessagesReceiveBatch?
    var lastAcknowledgment: MessagesReceiveAcknowledgment?
}

/// A separately anchored, exclusively owned, atomic state file. Scope, cursor
/// and pending delivery are committed together before any body is returned.
private final class MessagesReceiveStateFile {
    private let home: URL
    private let directory: Int32
    private let lock: Int32
    private let source: MessagesReceiveSource
    private let liveDevice: dev_t
    private static let name = "messages-receive-v1"
    private static func openDirectory(_ url: URL) throws -> Int32 {
        guard url.isFileURL, url.path.hasPrefix("/"), !url.path.contains("\0"),
              url.path.split(separator: "/").allSatisfy({ $0 != "." && $0 != ".." }) else { throw MessagesReceiveFault("receive_state_path_unsafe") }
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw MessagesReceiveFault("receive_state_unavailable") }
        do {
            for part in url.path.split(separator: "/") {
                let next = openat(fd, String(part), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw MessagesReceiveFault("receive_state_unavailable") }
                close(fd); fd = next
            }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o022 == 0 else { throw MessagesReceiveFault("receive_state_directory_unsafe") }
            return fd
        } catch { close(fd); throw error }
    }
    private static func safeFile(_ fd: Int32, limit: Int) throws -> Int {
        var info = stat()
        guard fd >= 0, fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_mode & 0o777 == 0o600, info.st_nlink == 1, info.st_size >= 0, info.st_size <= limit else {
            throw MessagesReceiveFault("receive_state_unsafe")
        }
        return Int(info.st_size)
    }
    private static func write(_ fd: Int32, _ data: Data) throws {
        var offset = 0
        try data.withUnsafeBytes { buffer in
            while offset < data.count {
                let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), data.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw MessagesReceiveFault("receive_state_uncertain") }; offset += count
            }
        }
        guard fsync(fd) == 0 else { throw MessagesReceiveFault("receive_state_uncertain") }
    }
    init(home: URL) throws {
        self.home = home
        let parent = try Self.openDirectory(home); defer { close(parent) }
        var child = stat(), anchor = stat()
        let hasChild = fstatat(parent, Self.name, &child, AT_SYMLINK_NOFOLLOW) == 0, childError = errno
        let hasAnchor = fstatat(parent, Self.name + ".anchor", &anchor, AT_SYMLINK_NOFOLLOW) == 0, anchorError = errno
        guard hasChild || childError == ENOENT, hasAnchor || anchorError == ENOENT, hasChild == hasAnchor else { throw MessagesReceiveFault("receive_state_missing_or_replaced") }
        if !hasChild { guard mkdirat(parent, Self.name, 0o700) == 0 else { throw MessagesReceiveFault("receive_state_unavailable") } }
        let opened = openat(parent, Self.name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard opened >= 0 else { throw MessagesReceiveFault("receive_state_unavailable") }
        do {
            guard fstat(opened, &child) == 0, child.st_uid == getuid(), child.st_mode & 0o777 == 0o700 else { throw MessagesReceiveFault("receive_state_unsafe") }
            guard let volume = try? home.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString,
                  !volume.isEmpty else { throw MessagesReceiveFault("receive_volume_identity_unavailable") }
            let birth = "\(child.st_birthtimespec.tv_sec):\(child.st_birthtimespec.tv_nsec)"
            let binding = Data("v2\n\(volume)\n\(child.st_ino)\n\(birth)\n".utf8)
            if !hasAnchor {
                let fd = openat(parent, Self.name + ".anchor", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                guard fd >= 0 else { throw MessagesReceiveFault("receive_state_uncertain") }; defer { close(fd) }
                try Self.write(fd, binding); guard fsync(parent) == 0 else { throw MessagesReceiveFault("receive_state_uncertain") }
            } else {
                let fd = openat(parent, Self.name + ".anchor", O_RDONLY | O_NOFOLLOW | O_CLOEXEC); defer { if fd >= 0 { close(fd) } }
                let size = try Self.safeFile(fd, limit: 256); var bytes = [UInt8](repeating: 0, count: size)
                guard Darwin.read(fd, &bytes, size) == size, Data(bytes) == binding else { throw MessagesReceiveFault("receive_state_missing_or_replaced") }
            }
            let lockFD = openat(opened, "lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
            do { _ = try Self.safeFile(lockFD, limit: 0); guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { throw MessagesReceiveFault("receive_owner_busy") } }
            catch { if lockFD >= 0 { close(lockFD) }; throw error }
            directory = opened; lock = lockFD; source = .init(volumeUUID: volume, inode: UInt64(child.st_ino), birth: birth); liveDevice = child.st_dev
            if !hasChild { try save(MessagesReceiveState()) }
        } catch { close(opened); throw error }
    }
    deinit { flock(lock, LOCK_UN); close(lock); close(directory) }
    private func verify() throws {
        let parent = try Self.openDirectory(home); defer { close(parent) }
        var info = stat()
        guard fstatat(parent, Self.name, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_mode & 0o777 == 0o700, info.st_uid == getuid(), info.st_dev == liveDevice, UInt64(info.st_ino) == source.inode,
              "\(info.st_birthtimespec.tv_sec):\(info.st_birthtimespec.tv_nsec)" == source.birth,
              (try? home.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString) == source.volumeUUID else {
            throw MessagesReceiveFault("receive_state_missing_or_replaced")
        }
    }
    func load() throws -> MessagesReceiveState {
        try verify()
        let fd = openat(directory, "state.json", O_RDONLY | O_NOFOLLOW | O_CLOEXEC); defer { if fd >= 0 { close(fd) } }
        let size = try Self.safeFile(fd, limit: 4 * 1024 * 1024)
        var data = Data(count: size)
        let count = data.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, size) }
        guard count == size else { throw MessagesReceiveFault("receive_state_uncertain") }
        let value = try JSONDecoder().decode(MessagesReceiveState.self, from: data)
        guard value.version == 1, value.cursor >= 0, value.pending?.scopeID == nil || value.pending?.scopeID == value.scope?.id,
              value.lastAcknowledgment?.scopeID == nil || value.lastAcknowledgment?.scopeID == value.scope?.id,
              (value.pending?.events.count ?? 0) <= 32 else { throw MessagesReceiveFault("receive_state_changed") }
        return value
    }
    func save(_ state: MessagesReceiveState) throws {
        try verify()
        let data = try MessagesReceiveEncoding.encode(state)
        guard data.count <= 4 * 1024 * 1024 else { throw MessagesReceiveFault("receive_state_capacity") }
        let temporary = "state-" + UUID().uuidString.lowercased()
        let fd = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw MessagesReceiveFault("receive_state_uncertain") }
        defer { close(fd); unlinkat(directory, temporary, 0) }
        try Self.write(fd, data)
        guard renameat(directory, temporary, directory, "state.json") == 0, fsync(directory) == 0 else { throw MessagesReceiveFault("receive_state_uncertain") }
        try verify()
    }
}

final class MessagesReceiveService: @unchecked Sendable {
    static let capability = "messages.receive"
    private let lock = NSLock()
    private let file: MessagesReceiveStateFile
    private let sourceURL: URL
    private var state: MessagesReceiveState
    private var running = false
    init(home: URL, databaseURL: URL = MessagesReceiveDatabase.liveURL) throws {
        file = try MessagesReceiveStateFile(home: home); state = try file.load(); sourceURL = databaseURL
        // Loading saved metadata never opens chat.db or starts capture.
    }
    private func synchronized<T>(_ body: () throws -> T) rethrows -> T { lock.lock(); defer { lock.unlock() }; return try body() }
    func status() -> MessagesReceiveStatus { synchronized { statusLocked() } }
    private func statusLocked() -> MessagesReceiveStatus { .init(enabled: state.enabled, running: running, scope: state.scope, pendingCount: state.pending?.events.count ?? 0, cursor: state.cursor) }
    func selections(beforeRowID: Int64 = .max) throws -> MessagesReceiveSelectionPage { try synchronized {
        let database = try MessagesReceiveDatabase(url: sourceURL)
        return try database.snapshot {
            let rows = try database.conversations(before: beforeRowID)
            return .init(entries: rows.entries.map { .init(source: database.source, conversation: $0, observedAt: Date()) }, nextBeforeRowID: rows.next, excludedCount: rows.excluded)
        }
    } }
    func enable(selection: MessagesReceiveSelection, consumerAppID: String) throws -> MessagesReceiveStatus { try synchronized {
        try MessagesReceiveEncoding.text(consumerAppID, maximum: 128)
        guard consumerAppID.range(of: "^[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}$", options: .regularExpression) != nil,
              Date().timeIntervalSince(selection.observedAt) >= 0, Date().timeIntervalSince(selection.observedAt) <= 300 else { throw MessagesReceiveFault("receive_selection_expired") }
        guard state.pending == nil else { throw MessagesReceiveFault("receive_pending_delivery_requires_review") }
        let database = try MessagesReceiveDatabase(url: sourceURL)
        guard database.source == selection.source else { throw MessagesReceiveFault("messages_database_changed") }
        let baseline = try database.snapshot { try database.verify(selection.conversation); return try database.highWater() }
        var next = state
        next.scope = .init(id: UUID(), source: database.source, conversation: selection.conversation, consumerAppID: consumerAppID, startRowID: baseline, startedAt: Date())
        next.cursor = baseline; next.enabled = true; next.lastAcknowledgment = nil
        try file.save(next); state = next; running = true; return statusLocked()
    } }
    func resumeFromNow() throws -> MessagesReceiveStatus { try synchronized {
        guard state.enabled, let scope = state.scope else { throw MessagesReceiveFault("receive_scope_required") }
        let database = try MessagesReceiveDatabase(url: sourceURL)
        guard database.source == scope.source else { throw MessagesReceiveFault("messages_database_changed") }
        let baseline = try database.snapshot { try database.verify(scope.conversation); return try database.highWater() }
        guard baseline >= state.cursor else { throw MessagesReceiveFault("messages_database_rewound") }
        var next = state; next.cursor = baseline; try file.save(next); state = next; running = true; return statusLocked()
    } }
    func pause() { synchronized { running = false } }
    func revoke() throws { try synchronized { var next = state; next.enabled = false; try file.save(next); state = next; running = false } }
    func discardPendingAfterReview() throws { try synchronized {
        guard !state.enabled, !running else { throw MessagesReceiveFault("receive_disable_before_discard") }
        var next = state; next.pending = nil; try file.save(next); state = next
    } }
    private func captureLocked() throws {
        guard running, state.enabled, let scope = state.scope else { throw MessagesReceiveFault("receive_paused_or_revoked") }
        let database = try MessagesReceiveDatabase(url: sourceURL)
        guard database.source == scope.source else { throw MessagesReceiveFault("messages_database_changed") }
        let page = try database.snapshot {
            try database.verify(scope.conversation)
            let high = try database.highWater(); guard high >= state.cursor else { throw MessagesReceiveFault("messages_database_rewound") }
            if state.pending != nil { return (cursor: state.cursor, events: [MessagesReceiveEvent]()) }
            return try database.read(scope.conversation, after: state.cursor, through: high)
        }
        if state.pending != nil { return }
        var next = state; next.cursor = page.cursor
        if !page.events.isEmpty { next.pending = .init(id: UUID(), scopeID: scope.id, events: page.events) }
        try file.save(next); state = next
    }
    func capture() throws -> MessagesReceiveStatus { try synchronized {
        do { try captureLocked(); return statusLocked() } catch { running = false; throw error }
    } }
    /// Agent-only pull/ack; the host verifies its actual current registration and
    /// policy on every call. There are no scope selectors or database paths here.
    func dispatch(method: String, parameters: [String: Any], consumer: MessagesReceiveConsumer,
                  verify: (MessagesReceiveConsumer) throws -> Void) throws -> Data { try synchronized {
        try verify(consumer)
        guard consumer.authorizedCapabilities.contains(Self.capability), !consumer.sessionID.isEmpty,
              !consumer.registrationGeneration.isEmpty, state.enabled, let scope = state.scope,
              scope.consumerAppID == consumer.appID else { throw MessagesReceiveFault("receive_consumer_not_authorized") }
        if method == "messages.receive.status" {
            guard parameters.isEmpty else { throw MessagesReceiveFault("invalid_receive_request") }
            try verify(consumer); return try MessagesReceiveEncoding.encode(statusLocked())
        }
        guard parameters["scope_id"] as? String == scope.id.uuidString.lowercased() else { throw MessagesReceiveFault("receive_scope_changed") }
        if method == "messages.receive.pull" {
            guard Set(parameters.keys) == ["scope_id"] else { throw MessagesReceiveFault("invalid_receive_request") }
            do { try captureLocked() } catch { running = false; throw error }; try verify(consumer)
            // Verify the source/scope even when returning a previously pending
            // batch, so changed group membership never exposes retained text.
            do {
                let database = try MessagesReceiveDatabase(url: sourceURL)
                guard database.source == scope.source else { throw MessagesReceiveFault("messages_database_changed") }
                try database.snapshot { try database.verify(scope.conversation) }
            } catch { running = false; throw error }
            struct Reply: Encodable {
                let schema_version = 1
                let delivery = "at_least_once_until_ack"
                let status: MessagesReceiveStatus
                let batch: MessagesReceiveBatch?
                let batch_digest: String?
                enum CodingKeys: String, CodingKey { case schema_version, delivery, status, batch, batch_digest }
                func encode(to encoder: Encoder) throws {
                    var values = encoder.container(keyedBy: CodingKeys.self)
                    try values.encode(schema_version, forKey: .schema_version); try values.encode(delivery, forKey: .delivery)
                    try values.encode(status, forKey: .status)
                    if let batch { try values.encode(batch, forKey: .batch) } else { try values.encodeNil(forKey: .batch) }
                    if let batch_digest { try values.encode(batch_digest, forKey: .batch_digest) } else { try values.encodeNil(forKey: .batch_digest) }
                }
            }
            let bytes = try MessagesReceiveEncoding.encode(Reply(status: statusLocked(), batch: state.pending, batch_digest: state.pending?.digest))
            guard bytes.count <= 96 * 1024 else { throw MessagesReceiveFault("receive_wire_budget") }
            return bytes
        }
        guard method == "messages.receive.ack", Set(parameters.keys) == ["scope_id", "batch_id", "batch_digest"] else { throw MessagesReceiveFault("receive_ack_mismatch") }
        if let acknowledged = state.lastAcknowledgment,
           parameters["batch_id"] as? String == acknowledged.batchID.uuidString.lowercased(),
           parameters["batch_digest"] as? String == acknowledged.digest {
            try verify(consumer); return try MessagesReceiveEncoding.encode(statusLocked())
        }
        guard let pending = state.pending, parameters["batch_id"] as? String == pending.id.uuidString.lowercased(),
              parameters["batch_digest"] as? String == pending.digest else { throw MessagesReceiveFault("receive_ack_mismatch") }
        try verify(consumer)
        var next = state; next.pending = nil
        next.lastAcknowledgment = .init(scopeID: scope.id, batchID: pending.id, digest: pending.digest)
        try file.save(next); state = next
        return try MessagesReceiveEncoding.encode(statusLocked())
    } }
}
