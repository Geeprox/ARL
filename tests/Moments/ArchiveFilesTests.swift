import Foundation
import CryptoKit

@main struct ArchiveFilesTests {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("arl-moments-test-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        let live = root.appendingPathComponent("live")
        let home = root.appendingPathComponent("owner")
        try MomentsFiles.privateDirectory(live); try MomentsFiles.privateDirectory(home)
        try Data(repeating: 7, count: 4096).write(to: live.appendingPathComponent("sns.db"))
        try Data(repeating: 8, count: 1024).write(to: live.appendingPathComponent("sns.db-wal"))
        let config = MomentsConfiguration(archiveRoot: root.path, snsDB: live.appendingPathComponent("sns.db").path, keysFile: "unused")
        let identity = try MomentsFiles.fingerprint(config)
        try MomentsFiles.capture(config, home: home, fingerprint: identity)
        let capture = MomentsFiles.json(home.appendingPathComponent("capture.json"))
        let staged = URL(fileURLWithPath: capture["sns_db"] as! String)
        assert(tryEqual(staged, live.appendingPathComponent("sns.db")))
        assert(tryEqual(URL(fileURLWithPath: staged.path + "-wal"), live.appendingPathComponent("sns.db-wal")))
        try Data(repeating: 9, count: 4096).write(to: live.appendingPathComponent("sns.db"))
        do { try MomentsFiles.capture(config, home: home, fingerprint: identity); fatalError("stale source accepted") } catch { assert((error as? MomentsFault)?.code == "source_changed") }
        assert(MomentsFiles.json(home.appendingPathComponent("capture.json"))["fingerprint"] as? String == identity)
        try fm.removeItem(at: live.appendingPathComponent("sns.db-wal"))
        let next = try MomentsFiles.fingerprint(config)
        try MomentsFiles.capture(config, home: home, fingerprint: next)
        let nextDB = MomentsFiles.json(home.appendingPathComponent("capture.json"))["sns_db"] as! String
        assert(!fm.fileExists(atPath: nextDB + "-wal"))
        let data = root.appendingPathComponent("data")
        try MomentsFiles.privateDirectory(data.appendingPathComponent("media"))
        let media = Data("image fixture".utf8)
        let hash = SHA256.hash(data: media).map { String(format: "%02x", $0) }.joined()
        try media.write(to: data.appendingPathComponent("media/" + hash + ".jpg"))
        let oldVideo = Data("unreferenced historical video".utf8)
        let oldHash = SHA256.hash(data: oldVideo).map { String(format: "%02x", $0) }.joined()
        let oldFile = data.appendingPathComponent("media/" + oldHash + ".mp4")
        try oldVideo.write(to: oldFile)
        try MomentsFiles.writeJSON(["posts": [["id": "18446744073709551615", "media": [["local_path": "media/" + hash + ".jpg"]]]]], data.appendingPathComponent("moments.json"))
        try MomentsFiles.privateDirectory(data.appendingPathComponent("private"))
        try Data("never sync secret".utf8).write(to: data.appendingPathComponent("private/keys.json"))
        let nas = root.appendingPathComponent("nas"); try MomentsFiles.privateDirectory(nas)
        let snapshot = try MomentsNAS.sync(archive: root, destination: nas, template: "<script>let x=__INITIAL_DATA__</script>")
        assert(snapshot.count == 64)
        assert(!fm.fileExists(atPath: nas.appendingPathComponent("Friday/apps/moments/data/private").path))
        let current = nas.appendingPathComponent("Friday/apps/moments/current.json")
        let before = try Data(contentsOf: current)
        let repeated = try MomentsNAS.sync(archive: root, destination: nas, template: "__INITIAL_DATA__")
        assert(repeated == snapshot)
        assert(fm.fileExists(atPath: nas.appendingPathComponent("Friday/apps/moments/data/media/" + oldHash + ".mp4").path))
        do {
            _ = try MomentsNAS.sync(archive: root, destination: nas, template: "__INITIAL_DATA__", validate: { throw MomentsFault(code: "disconnected") }, reclaim: true)
            fatalError("disconnected NAS accepted")
        } catch { assert((error as? MomentsFault)?.code == "disconnected") }
        assert(fm.fileExists(atPath: oldFile.path))
        _ = try MomentsNAS.sync(archive: root, destination: nas, template: "__INITIAL_DATA__", reclaim: true)
        assert(!fm.fileExists(atPath: oldFile.path))
        assert(!fm.fileExists(atPath: data.appendingPathComponent("media/" + hash + ".jpg").path))
        assert(MomentsFiles.json(data.appendingPathComponent("private/nas-migration.json"))["reclaimed_files"] as? Int == 2)
        assert(MomentsFiles.json(data.appendingPathComponent("private/nas-storage.json"))["files"] as? [String: Any] != nil)
        _ = try MomentsNAS.sync(archive: root, destination: nas, template: "__INITIAL_DATA__", reclaim: true)
        try Data("corrupted".utf8).write(to: data.appendingPathComponent("media/" + hash + ".jpg"))
        do { _ = try MomentsNAS.sync(archive: root, destination: nas, template: "__INITIAL_DATA__"); fatalError("corrupt media accepted") } catch { assert((error as? MomentsFault)?.code == "media_hash_mismatch") }
        assert(tryEqual(current, current)); assert(MomentsFiles.json(current)["snapshot"] as? String == snapshot)
        let escape = root.appendingPathComponent("escape"); try MomentsFiles.privateDirectory(escape)
        let unsafe = root.appendingPathComponent("unsafe"); try MomentsFiles.privateDirectory(unsafe)
        try fm.createSymbolicLink(at: unsafe.appendingPathComponent("Friday"), withDestinationURL: escape)
        do { _ = try MomentsNAS.sync(archive: root, destination: unsafe, template: "__INITIAL_DATA__"); fatalError("symlink accepted") } catch { assert((error as? MomentsFault)?.code == "unsafe_nas_path") }
        assert(!before.isEmpty)
        print("PASS: native capture, NAS idempotence, unreferenced video migration, readback before reclamation, disconnected preservation, receipt restart, corruption preservation, secret exclusion, symlink rejection")
    }
    static func tryEqual(_ a: URL, _ b: URL) -> Bool { (try? Data(contentsOf: a)) == (try? Data(contentsOf: b)) }
}
