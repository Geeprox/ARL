import Foundation
import Darwin
import CryptoKit
import ARLCredentialOnboarding

struct MomentsFault: Error { let code: String }
struct MomentsConfiguration: Codable, Sendable {
    var archiveRoot: String
    var snsDB: String
    var contactDB: String?
    var keysFile: String
    var collecting: Bool = true
    var nasBookmark: Data?
    var nasDisplayPath: String?
    var nasDestination: NASArchiveDestination?
}

// Only this native signed owner touches the live WeChat directory. Python sees
// immutable, authenticated-input copies, never a live DB or process memory.
enum MomentsFiles {
    static func privateDirectory(_ url: URL) throws {
        guard !isLink(url) else { throw MomentsFault(code: "unsafe_directory") }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
    }
    static func isLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }
    static func json(_ url: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: url), let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return value
    }
    static func writeJSON(_ value: [String: Any], _ url: URL) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    static func identity(_ url: URL, optional: Bool = false) throws -> String {
        var s = stat()
        guard lstat(url.path, &s) == 0 else {
            if errno == ENOENT && optional { return "absent" }
            throw MomentsFault(code: errno == EPERM || errno == EACCES ? "full_disk_access_required" : "source_unavailable")
        }
        guard (s.st_mode & S_IFMT) == S_IFREG, s.st_size <= 2 * 1024 * 1024 * 1024 else { throw MomentsFault(code: "source_not_regular_or_too_large") }
        return identity(s)
    }
    private static func identity(_ s: stat) -> String {
        "\(s.st_dev):\(s.st_ino):\(s.st_size):\(s.st_mtimespec.tv_sec):\(s.st_mtimespec.tv_nsec):\(s.st_ctimespec.tv_sec):\(s.st_ctimespec.tv_nsec)"
    }
    static func sources(_ configuration: MomentsConfiguration) -> [URL] {
        [configuration.snsDB, configuration.contactDB].compactMap { $0 }.flatMap { [URL(fileURLWithPath: $0), URL(fileURLWithPath: $0 + "-wal")] }
    }
    static func fingerprint(_ configuration: MomentsConfiguration) throws -> String {
        let identities = try sources(configuration).map { try identity($0, optional: $0.path.hasSuffix("-wal")) }
        return SHA256.hash(data: Data(identities.joined(separator: "|").utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func capture(_ configuration: MomentsConfiguration, home: URL, fingerprint: String) throws {
        let root = home.appendingPathComponent("capture", isDirectory: true)
        try privateDirectory(root)
        let fd = open(home.appendingPathComponent("capture.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw MomentsFault(code: "capture_lock_failed") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw MomentsFault(code: "capture_busy") }
        defer { flock(fd, LOCK_UN) }
        guard try self.fingerprint(configuration) == fingerprint else { throw MomentsFault(code: "source_changed") }
        let generation = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try privateDirectory(generation)
        var committed = false
        defer { if !committed { try? FileManager.default.removeItem(at: generation) } }
        for source in sources(configuration) {
            let before = try identity(source, optional: source.path.hasSuffix("-wal"))
            if before == "absent" { continue }
            let handle = open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard handle >= 0 else { throw MomentsFault(code: "full_disk_access_required") }
            var opened = stat()
            guard fstat(handle, &opened) == 0, identity(opened) == before else {
                close(handle); throw MomentsFault(code: "source_changed")
            }
            let input = FileHandle(fileDescriptor: handle, closeOnDealloc: true)
            let destination = generation.appendingPathComponent(source.lastPathComponent)
            FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600])
            let output = try FileHandle(forWritingTo: destination)
            do {
                var bytes = 0
                while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                    bytes += chunk.count
                    guard bytes <= opened.st_size else { throw MomentsFault(code: "source_changed") }
                    try output.write(contentsOf: chunk)
                }
                guard bytes == opened.st_size else { throw MomentsFault(code: "source_changed") }
                try output.synchronize(); try output.close(); try input.close()
            } catch { try? output.close(); try? input.close(); throw error }
            guard try identity(source) == before else { throw MomentsFault(code: "source_changed") }
        }
        guard try self.fingerprint(configuration) == fingerprint else { throw MomentsFault(code: "source_changed") }
        var manifest: [String: Any] = ["schema": 1, "fingerprint": fingerprint,
            "sns_db": generation.appendingPathComponent("sns.db").path,
            "captured_at": ISO8601DateFormatter().string(from: Date()), "owner": "local.arl.control"]
        if configuration.contactDB != nil { manifest["contact_db"] = generation.appendingPathComponent("contact.db").path }
        try writeJSON(manifest, home.appendingPathComponent("capture.json")); committed = true
        // Readers hold a shared lease throughout export; old generations cannot
        // disappear underneath them. Keep the current generation plus one prior.
        let children = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey])
            .sorted { ((try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast) > ((try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast) }
        for old in children.dropFirst(2) where old != generation { try? FileManager.default.removeItem(at: old) }
    }
    static func sha(_ url: URL) throws -> String {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw MomentsFault(code: "media_unreadable") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

// A bounded SMB mailbox; only the native credential owner supplies this root.
// Commands contain public asset IDs, never URLs, account operations or paths.
struct MomentsBridgeRequest: Sendable {
    let id: String
    let createdAt: String
    var payload: [String: Any] { ["schema": 1, "id": id, "created_at": createdAt, "kind": "refresh"] }
}
enum MomentsBridge {
    static func directory(_ url: URL, under root: URL) throws {
        guard url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/"), !MomentsFiles.isLink(root) else { throw MomentsFault(code: "bridge_scope") }
        var cursor = root
        for part in url.path.dropFirst(root.path.count).split(separator: "/") {
            cursor.appendPathComponent(String(part), isDirectory: true)
            guard !MomentsFiles.isLink(cursor) else { throw MomentsFault(code: "bridge_symlink") }
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: cursor.path, isDirectory: &isDirectory) {
                guard isDirectory.boolValue else { throw MomentsFault(code: "bridge_not_directory") }
            } else {
                try FileManager.default.createDirectory(at: cursor, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            }
        }
    }
    static func bounded(_ url: URL, maximum: Int = 8192) throws -> Data {
        guard !MomentsFiles.isLink(url), let size = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]).fileSize, size <= maximum,
              try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw MomentsFault(code: "bridge_input") }
        return try Data(contentsOf: url)
    }
    static func poll(root: URL?, home: URL) throws -> [MomentsBridgeRequest] {
        let fm = FileManager.default
        try directory(home.appendingPathComponent("requests"), under: home)
        try directory(home.appendingPathComponent("responses"), under: home)
        var candidates = [URL]()
        let manual = home.appendingPathComponent("manual-refresh.json")
        if fm.fileExists(atPath: manual.path) { candidates.append(manual) }
        if let root {
            let box = root.appendingPathComponent("Friday/apps/moments/.bridge")
            try directory(box.appendingPathComponent("requests"), under: root)
            try directory(box.appendingPathComponent("responses"), under: root)
            if let bytes = try? bounded(home.appendingPathComponent("bridge-status.json"), maximum: 4 * 1024 * 1024) {
                try bytes.write(to: box.appendingPathComponent("status.json"), options: .atomic)
            }
            for file in (try fm.contentsOfDirectory(at: home.appendingPathComponent("responses"), includingPropertiesForKeys: nil)).prefix(64) {
                guard UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil, file.pathExtension == "json" else { continue }
                let bytes = try bounded(file)
                let target = box.appendingPathComponent("responses/" + file.lastPathComponent)
                if !fm.fileExists(atPath: target.path) { try bytes.write(to: target, options: .atomic) }
                let request = box.appendingPathComponent("requests/" + file.lastPathComponent)
                if fm.fileExists(atPath: request.path) { try fm.removeItem(at: request) }
                try fm.removeItem(at: file)
            }
            candidates += (try fm.contentsOfDirectory(at: box.appendingPathComponent("requests"), includingPropertiesForKeys: nil)).prefix(32)
        }
        var refreshes = [MomentsBridgeRequest]()
        for file in candidates {
            guard let bytes = try? bounded(file), let value = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                  value["schema"] == nil || value["schema"] as? Int == 1,
                  let id = value["id"] as? String, UUID(uuidString: id) != nil,
                  file == manual || file.lastPathComponent == id + ".json",
                  let created = value["created_at"] as? String,
                  let date = ISO8601DateFormatter().date(from: created), Date().timeIntervalSince(date) >= -30, Date().timeIntervalSince(date) <= 600 else { continue }
            let target = home.appendingPathComponent("requests/" + id + ".json")
            let reply = home.appendingPathComponent("responses/" + id + ".json")
            if fm.fileExists(atPath: target.path) || fm.fileExists(atPath: reply.path) { continue }
            if value["kind"] as? String == "refresh" { refreshes.append(MomentsBridgeRequest(id: id, createdAt: created)) }
            else if value["kind"] as? String == "images", let ids = value["asset_ids"] as? [String], (1...20).contains(ids.count),
                    ids.allSatisfy({ $0.range(of: "^[A-Za-z0-9:_-]{1,200}$", options: .regularExpression) != nil }) {
                try bytes.write(to: target, options: .atomic)
            }
        }
        return refreshes
    }
    static func captured(_ requests: [MomentsBridgeRequest], home: URL) throws {
        for request in requests {
            try MomentsFiles.writeJSON(request.payload, home.appendingPathComponent("requests/" + request.id + ".json"))
            let manual = home.appendingPathComponent("manual-refresh.json")
            if MomentsFiles.json(manual)["id"] as? String == request.id { try? FileManager.default.removeItem(at: manual) }
        }
    }
}

extension MomentsFiles {
    // Copy content, not macOS ACLs/resource forks/ownership onto SMB. Foundation
    // copyItem can fail with EACCES even when ordinary byte reads/writes work.
    static func copyBytes(_ source: URL, to target: URL) throws {
        let inputFD = open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard inputFD >= 0 else { throw MomentsFault(code: "media_unreadable") }
        let input = FileHandle(fileDescriptor: inputFD, closeOnDealloc: true)
        defer { try? input.close() }
        var info = stat()
        guard fstat(inputFD, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size <= 2 * 1024 * 1024 * 1024 else { throw MomentsFault(code: "invalid_media_source") }
        let outputFD = open(target.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard outputFD >= 0 else { throw MomentsFault(code: "nas_write_failed") }
        let output = FileHandle(fileDescriptor: outputFD, closeOnDealloc: true)
        defer { try? output.close() }
        var count: Int64 = 0
        while let block = try input.read(upToCount: 1024 * 1024), !block.isEmpty {
            count += Int64(block.count)
            guard count <= info.st_size else { throw MomentsFault(code: "media_changed") }
            try output.write(contentsOf: block)
        }
        guard count == info.st_size else { throw MomentsFault(code: "media_changed") }
        try output.synchronize(); try output.close()
    }
}
