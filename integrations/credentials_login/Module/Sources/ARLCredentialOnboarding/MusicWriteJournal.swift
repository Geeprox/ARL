import Foundation
import Darwin
import OSLog
import CryptoKit

/// Lazily creates only this identity's receipt directory after the deployment gate.
/// Files are owner-only, bounded, atomic and fsynced; a nonblocking flock excludes another process.
final class FileMusicWriteJournal: MusicWriteJournal, @unchecked Sendable {
    private let directory: URL
    private let lock = NSLock()
    private var activeDirectory: Int32?
    init(directory: URL) { self.directory = directory }
    private let filename = "write-ledger.json"
    private let recoveryFilename = "recovery-ledger.json"
    private func validate(_ fd: Int32, mode: mode_t, type: mode_t) throws -> stat {
        var metadata = stat()
        guard fstat(fd, &metadata) == 0, metadata.st_uid == getuid(), metadata.st_mode & S_IFMT == type,
              metadata.st_mode & 0o777 == mode, type != S_IFREG || metadata.st_nlink == 1
        else { throw CredentialError.uncertainLocalState }
        return metadata
    }
    private enum Missing: Error { case directory }
    private func withLock<T>(create: Bool = true, exclusive: Bool = false, _ body: () throws -> T) throws -> T {
        try lock.withLock {
            // Traverse with openat/O_NOFOLLOW, preventing a symlink in any path component.
            guard directory.isFileURL, directory.path.hasPrefix("/"), !directory.pathComponents.contains("..") else { throw CredentialError.uncertainLocalState }
            var fd = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard fd >= 0 else { throw CredentialError.storageUnavailable }
            defer { close(fd) }
            for component in directory.pathComponents.dropFirst() {
                let next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                if next >= 0 { close(fd); fd = next; continue }
                if !create, errno == ENOENT { throw Missing.directory }
                guard create, errno == ENOENT, mkdirat(fd, component, 0o700) == 0 else { throw CredentialError.uncertainLocalState }
                let created = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                guard created >= 0 else { throw CredentialError.uncertainLocalState }
                close(fd); fd = created
            }
            _ = try validate(fd, mode: 0o700, type: S_IFDIR)
            let lockFD = openat(fd, "operation.lock", ((create || exclusive) ? O_RDWR : O_RDONLY) | (create ? O_CREAT : 0) | O_NOFOLLOW, 0o600)
            guard lockFD >= 0 else { throw CredentialError.storageUnavailable }
            defer { close(lockFD) }
            _ = try validate(lockFD, mode: 0o600, type: S_IFREG)
            guard flock(lockFD, ((create || exclusive) ? LOCK_EX : LOCK_SH) | LOCK_NB) == 0 else { throw CredentialError.busy }
            defer { flock(lockFD, LOCK_UN) }
            activeDirectory = fd
            defer { activeDirectory = nil }
            return try body()
        }
    }
    func inspect() throws -> MusicWriteLedger? {
        do { return try withLock(create: false) {
            let ledger = try load()
            if let ledger { try validate(ledger) }
            return ledger
        } } catch Missing.directory { return nil }
    }
    private struct Archived: Codable {
        let record: MusicWriteRecord
        let recovery: MusicWriteRecoveryRecord?
    }
    private func bucket(_ id: UUID) -> String { String(id.uuidString.lowercased().prefix(2)) }
    private func archiveName(_ id: UUID) -> String { "completed-" + id.uuidString.lowercased() + ".json" }
    private func hash(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    private func archiveIndex(_ key: String, ledger: MusicWriteLedger) throws -> [String: String] {
        guard ledger.archiveBuckets?.contains(key) == true else { return [:] }
        guard let bytes = try loadBytes(filename: "archive-index-" + key + ".json"),
              let index = try? JSONDecoder().decode([String: String].self, from: bytes),
              index.allSatisfy({ UUID(uuidString: $0.key)?.uuidString == $0.key &&
                  String($0.key.lowercased().prefix(2)) == key && $0.value.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil })
        else { throw CredentialError.uncertainLocalState }
        return index
    }
    private func archived(_ id: UUID, ledger: MusicWriteLedger) throws -> Archived? {
        guard let expected = try archiveIndex(bucket(id), ledger: ledger)[id.uuidString] else { return nil }
        guard let bytes = try loadBytes(filename: archiveName(id)), hash(bytes) == expected,
              let value = try? JSONDecoder().decode(Archived.self, from: bytes), value.record.request.requestID == id,
              value.record.cloudResource == nil, value.record.result != nil || value.recovery?.reconciled != nil
        else { throw CredentialError.uncertainLocalState }
        var single = MusicWriteLedger(); single.schema = 3; single.records[id.uuidString] = value.record
        try validate(single)
        if let recovery = value.recovery { try recovery.validate(original: value.record) }
        return value
    }
    func inspect(requestID: UUID) throws -> MusicWriteLedger? {
        do { return try withLock(create: false) {
            guard var ledger = try load() else { return nil }
            try validate(ledger)
            if let value = try archived(requestID, ledger: ledger) {
                // A crash may leave both durable copies; they must agree.
                if let active = ledger.records[requestID.uuidString], active != value.record { throw CredentialError.uncertainLocalState }
                ledger.records[requestID.uuidString] = value.record
            }
            return ledger
        } } catch Missing.directory { return nil }
    }
    private func recoveryOriginals(_ originals: MusicWriteLedger, _ recovery: MusicWriteRecoveryLedger) throws -> MusicWriteLedger {
        var result = originals
        for key in recovery.records.keys where result.records[key] == nil {
            guard let id = UUID(uuidString: key), let archived = try archived(id, ledger: originals) else { throw CredentialError.uncertainLocalState }
            result.records[key] = archived.record
        }
        try recovery.validate(originals: result)
        return result
    }
    private func archiveCompleted(_ ledger: inout MusicWriteLedger) throws {
        guard ledger.records.count >= 384 else { return }
        let recoveryBytes = try loadBytes(filename: recoveryFilename)
        var recovery = try recoveryBytes.map { try JSONDecoder().decode(MusicWriteRecoveryLedger.self, from: $0) } ?? MusicWriteRecoveryLedger()
        _ = try recoveryOriginals(ledger, recovery)
        let parents = Set(ledger.records.values.compactMap { $0.cloudResource?.supersedesRequestID })
        let completed = try ledger.records.values.filter { record in
            guard record.cloudResource == nil, !parents.contains(record.request.requestID) else { return false }
            if record.result != nil || recovery.records[record.request.requestID.uuidString]?.reconciled != nil { return true }
            return try archived(record.request.requestID, ledger: ledger) != nil
        }
        for record in completed {
            let id = record.request.requestID, key = bucket(id)
            if ledger.archiveBuckets?.contains(key) != true {
                // Empty index first; schema fence before removing any record.
                try writeBytes(JSONEncoder().encode([String: String]()), filename: "archive-index-" + key + ".json")
                ledger.schema = 4; ledger.archiveBuckets = (ledger.archiveBuckets ?? []).union([key]); try write(ledger)
            }
            var index = try archiveIndex(key, ledger: ledger)
            let value = Archived(record: record, recovery: recovery.records[id.uuidString])
            if index[id.uuidString] != nil {
                guard let old = try archived(id, ledger: ledger), old.record == record,
                      value.recovery == nil || old.recovery == value.recovery else { throw CredentialError.uncertainLocalState }
            } else {
                let bytes = try JSONEncoder().encode(value)
                try writeBytes(bytes, filename: archiveName(id))
                index[id.uuidString] = hash(bytes)
                try writeBytes(JSONEncoder().encode(index), filename: "archive-index-" + key + ".json")
            }
            ledger.records.removeValue(forKey: id.uuidString)
            recovery.records.removeValue(forKey: id.uuidString)
        }
        // Both immutable archive and index are durable before active compaction.
        if !completed.isEmpty {
            try write(ledger)
            if recoveryBytes != nil { try writeBytes(JSONEncoder().encode(recovery), filename: recoveryFilename) }
        }
    }
    func transaction<T>(_ body: (inout MusicWriteLedger) throws -> T) throws -> T {
        try withLock {
            var ledger = try load() ?? MusicWriteLedger()
            try validate(ledger)
            try archiveCompleted(&ledger)
            let previous = ledger
            let result = try body(&ledger)
            guard ledger.archiveBuckets == previous.archiveBuckets else { throw CredentialError.uncertainLocalState }
            for key in Set(ledger.records.keys).subtracting(previous.records.keys) {
                guard let id = UUID(uuidString: key), try archived(id, ledger: previous) == nil else { throw CredentialError.uncertainLocalState }
            }
            if previous.schema == 4 { ledger.schema = 4 }
            else if previous.schema == 3 || ledger.records.values.contains(where: { $0.metadataFieldsOnly == true }) {ledger.schema = 3}
            else if previous.schema == 2 || ledger.records.values.contains(where: { $0.cloudResource != nil }) { ledger.schema = 2 }
            for (key, old) in previous.records {
                guard let current = ledger.records[key], current.request == old.request, current.reference == old.reference,
                      current.epoch == old.epoch, current.baseline == old.baseline, current.baselineSongIDs == old.baselineSongIDs, current.contentDigest == old.contentDigest, current.metadataFieldsOnly == old.metadataFieldsOnly, current.cloudResource == old.cloudResource,
                      old.result == nil || current.result == old.result else { throw CredentialError.uncertainLocalState }
            }
            // Validate the mutated value before persisting or allowing an effect.
            try validate(ledger)
            try write(ledger)
            return result
        }
    }
    func inspectRecovery(requestID: UUID) throws -> MusicWriteRecoveryRecord? {
        do { return try withLock(create: false) {
            guard let originals = try load() else { return nil }
            try validate(originals)
            if let value = try archived(requestID, ledger: originals) { return value.recovery }
            guard let bytes = try loadBytes(filename: recoveryFilename) else { return nil }
            let recovery = try JSONDecoder().decode(MusicWriteRecoveryLedger.self, from: bytes)
            _ = try recoveryOriginals(originals, recovery)
            return recovery.records[requestID.uuidString]
        } } catch Missing.directory { return nil }
    }
    func recoveryTransaction<T>(_ body: (MusicWriteLedger, inout MusicWriteRecoveryLedger) throws -> T) throws -> T {
        // Existing directory and lock only: a recovery cannot create a missing original.
        try withLock(create: false, exclusive: true) {
            guard let originals = try load() else { throw CredentialError.missing }
            try validate(originals)
            let bytes = try loadBytes(filename: recoveryFilename)
            var recovery = try bytes.map { try JSONDecoder().decode(MusicWriteRecoveryLedger.self, from: $0) } ?? MusicWriteRecoveryLedger()
            _ = try recoveryOriginals(originals, recovery)
            let previous = recovery
            let value = try body(originals, &recovery)
            // Older binaries must reject the new once-only decision, including
            // a locally not-dispatched recovery; they must not silently ignore it.
            if previous.schema == 2 || recovery.records.values.contains(where: {
                $0.appendDecision != nil || $0.reason == .duplicateSafeAppendOnce
            }) { recovery.schema = 2 }
            _ = try recoveryOriginals(originals, recovery)
            for (key, old) in previous.records {
                guard let current = recovery.records[key], current.preserves(old) else { throw CredentialError.uncertainLocalState }
            }
            try writeBytes(JSONEncoder().encode(recovery), filename: recoveryFilename)
            return value
        }
    }
    private func validate(_ ledger: MusicWriteLedger) throws {
    guard [1,2,3,4].contains(ledger.schema), ledger.records.count <= 512, ledger.epochs.count <= 512,
          ledger.schema == 4 || ledger.archiveBuckets == nil,
          (ledger.archiveBuckets ?? []).allSatisfy({ $0.range(of: "^[a-f0-9]{2}$", options: .regularExpression) != nil }),
          ledger.records.allSatisfy({ $0.key == $0.value.request.requestID.uuidString })
    else { throw CredentialError.uncertainLocalState }
    var parents = Set<UUID>(), files = Set<String>()
    for record in ledger.records.values {
        try record.request.validate()
        guard record.request.isMetadataUpdate ? (record.metadataFieldsOnly == true ? ledger.schema >= 3 && record.contentDigest == nil : record.metadataFieldsOnly == nil && record.contentDigest?.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil) : record.contentDigest == nil && record.metadataFieldsOnly == nil
        else { throw CredentialError.uncertainLocalState }
        guard record.request.isSongListUpdate ? record.baselineSongIDs.map({ $0.allSatisfy(MusicReadProtocol.validID) && Set($0).count == $0.count }) == true : record.baselineSongIDs == nil else { throw CredentialError.uncertainLocalState }
        guard record.result?.matchedSongID.map({ record.cloudResource != nil && MusicReadProtocol.validID($0) }) ?? true else { throw CredentialError.uncertainLocalState }
        if let cloud = record.cloudResource {
            try cloud.resource.validate(); try cloud.selectedResource.validate()
            guard ledger.schema >= 2, record.request.intent == .appendSong,
                  cloud.selectedResource.sameFileIdentity(as: cloud.resource), cloud.observedAt.isFinite,
                  let parent = ledger.records[cloud.supersedesRequestID.uuidString], parent.cloudResource == nil,
                  parent.request.intent == .appendSong, parent.reference == record.reference, parent.epoch == record.epoch,
                  parent.request.playlistID == record.request.playlistID, parent.request.name == record.request.name,
                  parent.request.songID != record.request.songID, record.request.songID == cloud.resource.songID,
                  record.request.requestID == cloud.operationID(reference: record.reference, epoch: record.epoch),
                  parents.insert(cloud.supersedesRequestID).inserted,
                  files.insert([record.reference.uuidString,record.epoch.uuidString,record.request.playlistID!,cloud.resource.pcID].joined(separator: "|")).inserted
            else { throw CredentialError.uncertainLocalState }
        }
        guard record.effectDisposition != .notDispatched || (record.returnedPlaylistID == nil && record.result == nil)
        else { throw CredentialError.uncertainLocalState }
        guard record.baseline.count <= 500, Set(record.baseline).count == record.baseline.count,
              record.baseline.allSatisfy(MusicReadProtocol.validID),
              record.returnedPlaylistID.map(MusicReadProtocol.validID) ?? true,
              record.result.map({ $0.requestID == record.request.requestID && $0.readbackVerified }) ?? true
        else { throw CredentialError.uncertainLocalState }
    }
    }
    private func load() throws -> MusicWriteLedger? {
        guard let bytes = try loadBytes(filename: filename) else { return nil }
        guard let ledger = try? JSONDecoder().decode(MusicWriteLedger.self, from: bytes) else { throw CredentialError.uncertainLocalState }
        return ledger
    }
    private func loadBytes(filename: String) throws -> Data? {
        guard let directoryFD = activeDirectory else { throw CredentialError.uncertainLocalState }
        let fd = openat(directoryFD, filename, O_RDONLY | O_NOFOLLOW)
        if fd < 0, errno == ENOENT { return nil }
        guard fd >= 0 else { throw CredentialError.uncertainLocalState }
        defer { close(fd) }
        let metadata = try validate(fd, mode: 0o600, type: S_IFREG)
        guard metadata.st_size > 0, metadata.st_size <= 2097152 else { throw CredentialError.uncertainLocalState }
        var bytes = [UInt8](repeating: 0, count: Int(metadata.st_size)), offset = 0
        while offset < bytes.count {
            let remaining = bytes.count - offset
            let count = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!.advanced(by: offset), remaining) }
            guard count > 0 else { throw CredentialError.uncertainLocalState }; offset += count
        }
        return Data(bytes)
    }
    private func write(_ receipt: MusicWriteLedger) throws {
        try writeBytes(JSONEncoder().encode(receipt), filename: filename)
    }
    private func writeBytes(_ bytes: Data, filename: String) throws {
        guard bytes.count <= 2097152 else { throw CredentialError.uncertainLocalState }
        guard let directoryFD = activeDirectory else { throw CredentialError.uncertainLocalState }
        let temporary = "receipt-" + UUID().uuidString
        let fd = openat(directoryFD, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw CredentialError.storageUnavailable }
        defer { close(fd); unlinkat(directoryFD, temporary, 0) }
        try bytes.withUnsafeBytes { pointer in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, pointer.baseAddress!.advanced(by: offset), bytes.count - offset)
                guard count > 0 else { throw CredentialError.storageUnavailable }; offset += count
            }
        }
        guard fsync(fd) == 0, renameat(directoryFD, temporary, directoryFD, filename) == 0,
              fsync(directoryFD) == 0 else { throw CredentialError.storageUnavailable }
    }
}

public enum MusicBusinessLogFailure: Error, Sendable { case unavailable }

/// Local business evidence only. Credentials and transport authentication never belong here.
/// Segments rotate by size; retention is eight days, never shortened for a quota.
final class MusicBusinessJournal: @unchecked Sendable {
    private let directory: URL
    private let lock = NSLock()
    private var active: String?
    private var lastCleanup = Date.distantPast
    private let retention: TimeInterval = 8 * 86400
    private let now: @Sendable () -> Date
    private let minimumFreeBytes: UInt64
    init(directory: URL, minimumFreeBytes: UInt64 = 0,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory; self.minimumFreeBytes = minimumFreeBytes; self.now = now
    }
    private func validate(_ fd: Int32, type: mode_t, mode: mode_t) throws -> stat {
        var value = stat()
        guard fstat(fd, &value) == 0, value.st_uid == getuid(),
              value.st_mode & S_IFMT == type, value.st_mode & 0o777 == mode,
              type != S_IFREG || value.st_nlink == 1 else { throw MusicBusinessLogFailure.unavailable }
        return value
    }
    private func openDirectory() throws -> Int32 {
        guard directory.isFileURL, !directory.pathComponents.contains("..") else { throw MusicBusinessLogFailure.unavailable }
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw MusicBusinessLogFailure.unavailable }
        do {
            for part in directory.pathComponents.dropFirst() {
                var next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if next < 0 && errno == ENOENT {
                    guard mkdirat(fd, part, 0o700) == 0 || errno == EEXIST else { throw MusicBusinessLogFailure.unavailable }
                    next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                guard next >= 0 else { throw MusicBusinessLogFailure.unavailable }
                close(fd); fd = next
            }
            _ = try validate(fd, type: S_IFDIR, mode: 0o700)
            return fd
        } catch { close(fd); throw error }
    }
    func append(_ record: [String: Any], requestID: UUID?, callID: UUID?) throws {
        try lock.withLock {
            do {
                let current = now(), fd = try openDirectory()
                defer { close(fd) }
                // All journal instances/processes share this directory lock.
                // Hold it before opening a segment until append/cleanup finishes,
                // so no writer can succeed on an inode another instance unlinks.
                let coordination = openat(fd, "business.lock.noindex", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
                guard coordination >= 0 else { throw MusicBusinessLogFailure.unavailable }
                defer { close(coordination) }
                _ = try validate(coordination, type: S_IFREG, mode: 0o600)
                guard flock(coordination, LOCK_EX) == 0 else { throw MusicBusinessLogFailure.unavailable }
                defer { flock(coordination, LOCK_UN) }
                if current.timeIntervalSince(lastCleanup) >= 3600 {
                    // Unlink only our regular, single-link, owner-only expired segments.
                    // An active segment's latest mtime starts its retention clock.
                    for name in try FileManager.default.contentsOfDirectory(atPath: directory.path)
                        where name.hasPrefix("business-") && name.hasSuffix(".jsonl.noindex") && name != active {
                        let file = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                        guard file >= 0 else { throw MusicBusinessLogFailure.unavailable }
                        let metadata: stat
                        do { metadata = try validate(file, type: S_IFREG, mode: 0o600) }
                        catch { close(file); throw error }
                        close(file)
                        if current.timeIntervalSince1970 - Double(metadata.st_mtimespec.tv_sec) > retention {
                            guard unlinkat(fd, name, 0) == 0 else { throw MusicBusinessLogFailure.unavailable }
                        }
                    }
                    lastCleanup = current
                }
                var capacity = statfs()
                guard fstatfs(fd, &capacity) == 0,
                      UInt64(capacity.f_bavail) * UInt64(capacity.f_bsize) >= minimumFreeBytes
                else { throw MusicBusinessLogFailure.unavailable }
                var row = record
                row["schema"] = 1; row["at_utc"] = ISO8601DateFormatter().string(from: current)
                row["request_id"] = requestID?.uuidString ?? NSNull()
                row["call_id"] = callID?.uuidString ?? NSNull()
                row["build"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "fixture"
                var bytes = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys, .withoutEscapingSlashes])
                bytes.append(10)
                if active == nil { active = "business-" + String(Int(current.timeIntervalSince1970)) + "-" + UUID().uuidString + ".jsonl.noindex" }
                let file = openat(fd, active!, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
                guard file >= 0 else { throw MusicBusinessLogFailure.unavailable }
                defer { close(file) }
                let metadata = try validate(file, type: S_IFREG, mode: 0o600)
                guard flock(file, LOCK_EX) == 0 else { throw MusicBusinessLogFailure.unavailable }
                defer { flock(file, LOCK_UN) }
                do {
                    try bytes.withUnsafeBytes { buffer in
                        var offset = 0
                        while offset < buffer.count {
                            let n = Darwin.write(file, buffer.baseAddress!.advanced(by: offset), buffer.count-offset)
                            if n < 0 && errno == EINTR { continue }
                            guard n > 0 else { throw MusicBusinessLogFailure.unavailable }
                            offset += n
                        }
                    }
                    guard fsync(file) == 0, fsync(fd) == 0 else { throw MusicBusinessLogFailure.unavailable }
                } catch {
                    // Preserve all young evidence, including any incomplete tail.
                    // Never append a new successful row behind this uncertain one.
                    let damaged = active!
                    active = nil
                    let isolated = String(damaged.dropLast(".jsonl.noindex".count)) + "-incomplete.jsonl.noindex"
                    _ = renameat(fd, damaged, fd, isolated)
                    _ = fsync(fd)
                    throw error
                }
                if metadata.st_size + off_t(bytes.count) >= 4 * 1024 * 1024 { active = nil }
            } catch {
                Self.logger.fault("Music business log unavailable; an effect may already have occurred. No automatic replay. Young records are retained for at least seven days; no early eviction.")
                throw error // Callers report diagnostic availability without replacing the business outcome.
            }
        }
    }
    private static let logger = Logger(subsystem: "local.arl.control", category: "music-business-log")
}
