import Foundation
import CryptoKit
import Darwin

// Native ARL connects the selected SMB directory with its existing credential owner.
// No NAS password, DB key, signed CDN URL or raw contact database is replicated.
enum MomentsNAS {
    static func sync(archive: URL, destination: URL, template: String,
                     validate: @Sendable () throws -> Void = {}, reclaim: Bool = false) throws -> String {
        let fm = FileManager.default
        guard fm.fileExists(atPath: destination.path), !MomentsFiles.isLink(destination) else { throw MomentsFault(code: "nas_unavailable") }
        let dataRoot = archive.appendingPathComponent("data")
        let lease = open(dataRoot.appendingPathComponent(".media.lock").path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard lease >= 0 else { throw MomentsFault(code: "archive_busy") }
        defer { close(lease) }
        guard flock(lease, LOCK_EX | LOCK_NB) == 0 else { throw MomentsFault(code: "archive_busy") }
        defer { flock(lease, LOCK_UN) }
        try validate()
        let raw = try Data(contentsOf: dataRoot.appendingPathComponent("moments.json"))
        guard raw.count <= 128 * 1024 * 1024, let document = try JSONSerialization.jsonObject(with: raw) as? [String: Any], document["posts"] is [Any] else { throw MomentsFault(code: "archive_invalid") }
        let snapshot = SHA256.hash(data: raw).map { String(format: "%02x", $0) }.joined()
        let app = destination.appendingPathComponent("Friday/apps/moments", isDirectory: true)
        let blobRoot = app.appendingPathComponent("data/media", isDirectory: true)
        try safeDirectory(blobRoot, under: destination)
        // Include every previously cached media blob, even if a newer export
        // no longer references it. Keys/raw contacts/private state stay local.
        let previous = MomentsFiles.json(dataRoot.appendingPathComponent("private/nas-storage.json"))
        var records = previous["files"] as? [String: [String: Any]] ?? [:]
        // NAS itself hashes every immutable blob after each publication. Reuse
        // that complete proof for older blobs; only new bytes need transfer and
        // readback on this Mac. Reclamation still rehashes both actual copies.
        var auditedFiles = [String: [String: Any]]()
        var auditDate: String?
        let marker = app.appendingPathComponent("current.json")
        let auditFile = app.appendingPathComponent(".integrity.json")
        if !MomentsFiles.isLink(marker), !MomentsFiles.isLink(auditFile),
           let size = try? auditFile.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 8 * 1024 * 1024,
           previous["media_root"] as? String == blobRoot.path {
            let current = MomentsFiles.json(marker), audit = MomentsFiles.json(auditFile)
            if let priorSnapshot = previous["snapshot"] as? String,
               current["snapshot"] as? String == priorSnapshot,
               audit["source_moments_sha256"] as? String == priorSnapshot,
               (audit["verification_failures"] as? [Any])?.isEmpty == true,
               let files = audit["files"] as? [String: [String: Any]] {
                auditedFiles = files; auditDate = audit["checked_at"] as? String
            }
        }
        var localFiles = [URL]()
        let localMedia = dataRoot.appendingPathComponent("media", isDirectory: true)
        guard !MomentsFiles.isLink(localMedia) else { throw MomentsFault(code: "unsafe_archive_path") }
        for source in try fm.contentsOfDirectory(at: localMedia, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) {
            guard source.lastPathComponent.range(of: "^[a-f0-9]{64}\\.(jpg|jpeg|png|gif|webp|mp4)$", options: .regularExpression) != nil,
                  !MomentsFiles.isLink(source), (try source.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else { continue }
            let expected = source.deletingPathExtension().lastPathComponent
            guard try MomentsFiles.sha(source) == expected else { throw MomentsFault(code: "media_hash_mismatch") }
            records["media/" + source.lastPathComponent] = ["sha256": expected, "bytes": (try source.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0]
            localFiles.append(source)
        }
        var manifest = [[String: Any]]()
        var lastReadValidation = Date()
        var reusedAuditedBlobs = 0
        for reference in records.keys.sorted() {
            guard reference.range(of: "^media/[a-f0-9]{64}\\.(jpg|jpeg|png|gif|webp|mp4)$", options: .regularExpression) != nil,
                  let record = records[reference], let expected = record["sha256"] as? String,
                  expected == URL(fileURLWithPath: reference).deletingPathExtension().lastPathComponent,
                  let bytes = record["bytes"] as? Int else { throw MomentsFault(code: "archive_receipt_invalid") }
            if let proof = auditedFiles[reference], proof["sha256"] as? String == expected,
               proof["bytes"] as? Int == bytes {
                manifest.append(["path": reference, "sha256": expected, "bytes": bytes])
                reusedAuditedBlobs += 1
                continue
            }
            // Re-reading previously archived immutable blobs does not request
            // credentials. Bound revocation checks while reading; keep full
            // checks at every write/publication/reclamation boundary below.
            if Date().timeIntervalSince(lastReadValidation) >= 5 {
                try validate(); lastReadValidation = Date()
            }
            let source = dataRoot.appendingPathComponent(reference)
            let target = blobRoot.appendingPathComponent(source.lastPathComponent)
            guard !MomentsFiles.isLink(target) else { throw MomentsFault(code: "unsafe_nas_path") }
            let currentIdentity = try? MomentsFiles.identity(target)
            let previouslyVerified = previous["media_root"] as? String == blobRoot.path
                && currentIdentity != nil && record["nas_identity"] as? String == currentIdentity
            var verified = previouslyVerified
            if !verified, fm.fileExists(atPath: target.path) { verified = try MomentsFiles.sha(target) == expected }
            if !verified {
                try validate()
                guard fm.fileExists(atPath: source.path) else { throw MomentsFault(code: "nas_media_missing") }
                let pending = blobRoot.appendingPathComponent(".upload-" + UUID().uuidString)
                defer { try? fm.removeItem(at: pending) }
                try MomentsFiles.copyBytes(source, to: pending)
                let handle = try FileHandle(forWritingTo: pending); try handle.synchronize(); try handle.close()
                guard try MomentsFiles.sha(pending) == expected else { throw MomentsFault(code: "nas_hash_mismatch") }
                try validate()
                guard rename(pending.path, target.path) == 0 else { throw MomentsFault(code: "nas_commit_failed") }
            }
            // Read back the committed filename, not only the temporary upload.
            guard try (verified || MomentsFiles.sha(target) == expected),
                  (try target.resourceValues(forKeys: [.fileSizeKey])).fileSize == bytes else { throw MomentsFault(code: "nas_hash_mismatch") }
            records[reference]?["nas_identity"] = try MomentsFiles.identity(target)
            manifest.append(["path": reference, "sha256": expected, "bytes": bytes])
        }
        let snapshotRoot = app.appendingPathComponent("snapshots/" + snapshot, isDirectory: true)
        try safeDirectory(snapshotRoot, under: destination)
        try raw.write(to: snapshotRoot.appendingPathComponent("moments.json"), options: .atomic)
        guard try MomentsFiles.sha(snapshotRoot.appendingPathComponent("moments.json")) == snapshot else { throw MomentsFault(code: "nas_hash_mismatch") }
        // Preserve the existing public JSON files in this immutable generation.
        // Never traverse data/private, copy DBs or export credentials.
        let metadata = snapshotRoot.appendingPathComponent("metadata", isDirectory: true)
        try safeDirectory(metadata, under: destination)
        for source in try fm.contentsOfDirectory(at: dataRoot, includingPropertiesForKeys: [.isRegularFileKey]) where source.pathExtension == "json" && source.lastPathComponent != "moments.json" {
            guard !MomentsFiles.isLink(source), (try source.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else { throw MomentsFault(code: "unsafe_archive_path") }
            let target = metadata.appendingPathComponent(source.lastPathComponent)
            guard !MomentsFiles.isLink(target) else { throw MomentsFault(code: "unsafe_nas_path") }
            let bytes = try Data(contentsOf: source)
            try bytes.write(to: target, options: .atomic)
            let expected = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            guard try MomentsFiles.sha(target) == expected else { throw MomentsFault(code: "nas_hash_mismatch") }
        }
        var embedded = document; embedded.removeValue(forKey: "changes")
        let json = String(decoding: try JSONSerialization.data(withJSONObject: embedded, options: [.sortedKeys]), as: UTF8.self)
            .replacingOccurrences(of: "<", with: "\\u003c").replacingOccurrences(of: ">", with: "\\u003e").replacingOccurrences(of: "&", with: "\\u0026")
        try Data(template.replacingOccurrences(of: "__INITIAL_DATA__", with: json).utf8).write(to: snapshotRoot.appendingPathComponent("index.html"), options: .atomic)
        try validate()
        try MomentsFiles.writeJSON(["schema": 1, "snapshot": snapshot, "media": manifest], snapshotRoot.appendingPathComponent("manifest.json"))
        // Only this final tiny atomic publication changes what the NAS serves.
        try MomentsFiles.writeJSON(["schema": 1, "snapshot": snapshot, "received_at": ISO8601DateFormatter().string(from: Date()), "media_count": manifest.count], app.appendingPathComponent("current.json"))
        try validate()
        var receipt: [String: Any] = ["schema": 1, "snapshot": snapshot, "media_root": blobRoot.path,
            "files": records, "verified_at": ISO8601DateFormatter().string(from: Date()),
            "reused_NAS_audited_blobs": reusedAuditedBlobs,
            "verification_mode": "new_blobs_readback_plus_prior_committed_NAS_full_hash_proof"]
        if let auditDate { receipt["NAS_full_audit_at"] = auditDate }
        // Local receipt precedes any reclamation. A stopped transfer never removes
        // a source, and restart resumes from the independently verified NAS blobs.
        try MomentsFiles.writeJSON(receipt, dataRoot.appendingPathComponent("private/nas-storage.json"))
        var reclaimed = 0, reclaimedBytes = 0
        if reclaim {
            for source in localFiles {
                try validate()
                let reference = "media/" + source.lastPathComponent
                guard let record = records[reference], let expected = record["sha256"] as? String,
                      try MomentsFiles.sha(source) == expected,
                      try MomentsFiles.sha(blobRoot.appendingPathComponent(source.lastPathComponent)) == expected else { throw MomentsFault(code: "reclaim_verification_failed") }
                reclaimedBytes += record["bytes"] as? Int ?? 0
                try fm.removeItem(at: source); reclaimed += 1
            }
        }
        try MomentsFiles.writeJSON(["schema": 1, "snapshot": snapshot, "verified_files": records.count,
            "reclaimed_files": reclaimed, "reclaimed_bytes": reclaimedBytes,
            "completed_at": ISO8601DateFormatter().string(from: Date())], dataRoot.appendingPathComponent("private/nas-migration.json"))
        return snapshot
    }
    private static func safeDirectory(_ path: URL, under root: URL) throws {
        guard path.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/") else { throw MomentsFault(code: "unsafe_nas_path") }
        var cursor = root
        for part in path.path.dropFirst(root.path.count).split(separator: "/") {
            cursor.appendPathComponent(String(part), isDirectory: true)
            guard !MomentsFiles.isLink(cursor) else { throw MomentsFault(code: "unsafe_nas_path") }
            var directory: ObjCBool = false
            if FileManager.default.fileExists(atPath: cursor.path, isDirectory: &directory) {
                guard directory.boolValue else { throw MomentsFault(code: "unsafe_nas_path") }
            } else {
                try FileManager.default.createDirectory(at: cursor, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            }
        }
    }
}
