import Foundation
import Darwin

/// Serialized by the existing native Host. Disk records, not UI state, own the
/// one-attempt boundary. A failed/unknown task never consumes another task's grant.
struct RemindersTaskStore {
    let home: String
    let identity: RemindersFirstIdentity
    let policy: String
    let legacyRunID: String
    let sessionID: String
    private var directory: String { home + "/tasks-v1" }
    private func path(_ id: String) throws -> String {
        guard RemindersTaskContract.uuid(id), id != legacyRunID else { throw RemindersTransportFault("invalid_task_id") }
        return directory + "/" + id + ".json"
    }
    private func directoryExists(create: Bool = false) throws -> Bool {
        try RemindersNativeIO.privateDirectory(home)
        if access(directory, F_OK) != 0 {
            guard errno == ENOENT else { throw RemindersTransportFault("unsafe_home") }
            guard create else { return false }
            guard mkdir(directory, 0o700) == 0 else { throw RemindersTransportFault("unsafe_home") }
        }
        try RemindersNativeIO.privateDirectory(directory); return true
    }
    private func ids() throws -> [String] {
        guard try directoryExists() else { return [] }
        let names = try FileManager.default.contentsOfDirectory(atPath: directory)
        guard names.count <= 512 else { throw RemindersTransportFault("task_capacity") }
        return names.filter { $0.hasSuffix(".json") && RemindersTaskContract.uuid(String($0.dropLast(5))) }.map { String($0.dropLast(5)) }.sorted()
    }
    func admissionDirectory() throws -> String {
        _=try directoryExists(create:true)
        let path=directory+"/admissions"
        if access(path,F_OK) != 0 {guard errno==ENOENT,mkdir(path,0o700)==0 else{throw RemindersTransportFault("unsafe_home")}}
        try RemindersNativeIO.privateDirectory(path);return path
    }
    func read(_ id: String) throws -> RemindersTaskRecord {
        let file = try path(id)
        guard try directoryExists() else { throw RemindersTransportFault("task_not_found") }
        var info=stat()
        if lstat(file,&info) != 0 {
            guard errno == ENOENT else{throw RemindersTransportFault("unsafe_config")}
            throw RemindersTransportFault("task_not_found")
        }
        let raw=try RemindersNativeIO.privateFile(file)
        guard raw.count<=12288 else{throw RemindersTransportFault("task_record_changed")}
        let value = try JSONDecoder().decode(RemindersTaskRecord.self, from: raw)
        guard value.schema_version == 1, value.task_id == id, value.operation_id == RemindersTaskContract.operationID(id),
              value.policy_sha256 == policy, RemindersUpgradeReview.storedSubjectMatches(value.identity, current: identity) else { throw RemindersTransportFault("task_record_changed") }
        try RemindersTaskContract.title(value.title)
        if let scope = value.scope { try RemindersTaskContract.target(scope.source) }
        guard value.state != .scoped || value.scope != nil,
              value.state != .saved || (value.reminder_id?.isEmpty == false && value.reminder_id!.utf8.count <= 1024),
              value.state == .saved || value.reminder_id == nil else { throw RemindersTransportFault("task_record_changed") }
        return value
    }
    private func write(_ value: RemindersTaskRecord, new: Bool = false) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(value)
        guard bytes.count<=12288 else{throw RemindersTransportFault("task_payload_too_large")}
        if new { try RemindersNativeIO.writeNew(bytes, to: path(value.task_id)) }
        else { try RemindersNativeIO.atomicWrite(bytes, to: path(value.task_id)) }
    }
    func prepare(id: String, title: String) throws -> RemindersTaskRecord {
        let file = try path(id); try RemindersTaskContract.title(title)
        _ = try directoryExists(create: true)
        if access(file, F_OK) == 0 {
            let old = try read(id)
            guard old.title == title else { throw RemindersTransportFault("idempotency_conflict") }
            return old
        }
        guard errno == ENOENT, try ids().count < 256 else { throw RemindersTransportFault("task_capacity") }
        let value = RemindersTaskRecord(schema_version: 1, task_id: id, operation_id: RemindersTaskContract.operationID(id), title: title,
            identity: identity, policy_sha256: policy, state: .draft)
        try write(value, new: true); return value
    }
    func grant(id: String, expected: String, source: RemindersSelectedSource, nowMS: Int64, uptime: Double) throws -> RemindersTaskRecord {
        var value = try mutable(id, expected: expected); try RemindersTaskContract.target(source)
        value.scope = .init(source: source, identity: identity, expires_at_ms: nowMS + 300_000, expires_uptime: uptime + 300, host_session_id: sessionID)
        value.state = .scoped; try write(value); return value
    }
    func mutable(_ id: String, expected: String) throws -> RemindersTaskRecord {
        let value = try read(id)
        guard !value.state.terminal else { throw RemindersTransportFault("task_already_consumed") }
        guard value.digest == expected else { throw RemindersTransportFault("task_changed") }
        return value
    }
    func cancel(id: String, expected: String) throws -> RemindersTaskRecord {
        var value = try mutable(id, expected: expected)
        value.state = .cancelled; value.scope = nil; try write(value); return value
    }
    func submit(id: String, expected: String, nowMS: Int64, uptime: Double, validate: (RemindersTaskRecord) throws -> Void,
                effect: (RemindersTaskRecord) throws -> String) throws -> RemindersTaskRecord {
        var value = try read(id)
        // These records can be displayed or polled, never resubmitted to EventKit.
        if value.state.terminal { return value }
        guard value.digest == expected, value.state == .scoped, let scope = value.scope,
              scope.identity == identity, scope.host_session_id == sessionID, scope.expires_uptime.isFinite, scope.expires_uptime > uptime, scope.expires_uptime <= uptime + 300, scope.expires_at_ms > nowMS, scope.expires_at_ms <= nowMS + 300_000 else { throw RemindersTransportFault("task_scope_required") }
        try validate(value)
        value.state = .attempting
        try write(value) // Durable consumption precedes every possible effect.
        do {
            // Recheck after durable admission, including exact live code and target.
            try validate(value)
            let result = try effect(value)
            guard !result.isEmpty, result.utf8.count <= 1024 else { throw RemindersTransportFault("task_outcome_unknown") }
            value.state = .saved; value.reminder_id = result
            try write(value)
        } catch {
            value.state = .unknown; value.reminder_id = nil
            try? write(value)
            throw RemindersTransportFault("task_outcome_unknown")
        }
        return value
    }
    func page(offset: Int) throws -> RemindersTaskPage {
        guard (0...256).contains(offset) else { throw RemindersTransportFault("invalid_arguments") }
        let all = try ids(); let end = min(offset + 5, all.count)
        guard offset <= all.count else { throw RemindersTransportFault("invalid_arguments") }
        let rows = try all[offset..<end].map { id in
            let value = try read(id); return RemindersTaskSummary(task_id: id, title: value.title, state: value.state)
        }
        return .init(offset: offset, next_offset: end < all.count ? end : nil, entries: rows)
    }
}
