import Foundation
import AppKit
import Observation
import ARLCredentialOnboarding

@MainActor @Observable
final class MomentsController {
    private(set) var configuration: MomentsConfiguration?
    private(set) var message: String?
    private(set) var captureDate: Date?
    private(set) var latestPost: String?
    private(set) var postCount = 0
    private(set) var remainingImages = 0
    private(set) var failedImages = 0
    private(set) var busy = false
    private(set) var syncing = false
    private(set) var nasDate: Date?
    private(set) var nasError: String?
    private(set) var running = false
    let available: Bool
    @ObservationIgnored private let home: URL
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var worker: Process?
    @ObservationIgnored private var failedWorker = false
    @ObservationIgnored private var workerFailures=0
    @ObservationIgnored private var nextWorkerStart=Date.distantPast
    @ObservationIgnored private var workerStartedAt=Date.distantPast
    @ObservationIgnored private var nextRecoveryRequest=Date.distantPast
    private(set) var recoveryPending=false
    private(set) var imageStopPreserved=false
    private(set) var imageDownloadIssue: String?
    private(set) var imageRecoveryMessage: String?
    private(set) var canReconfirmImages=false
    @ObservationIgnored private var recoveryRequestID: String?
    @ObservationIgnored private var imageResumeStop: [String:Any]?
    @ObservationIgnored private var lastFingerprint: String?
    @ObservationIgnored private var pendingFingerprint: String?
    @ObservationIgnored private var changedAt = Date.distantPast
    @ObservationIgnored private var attemptedAt = Date.distantPast
    @ObservationIgnored private var lastSyncAt = Date()
    @ObservationIgnored private var closing = false
    @ObservationIgnored private var syncedArchiveIdentity: String?
    @ObservationIgnored private var nasOwner: (any NASArchivePickerOwner)?
    @ObservationIgnored private var mountedNAS: NASArchiveMount?

    init(home: URL, enabled: Bool) {
        self.home = home.appendingPathComponent("Moments", isDirectory: true)
        available = enabled
        guard enabled else { return }
        if let raw = try? Data(contentsOf: self.home.appendingPathComponent("configuration.json")) {
            if let candidate = try? JSONDecoder().decode(MomentsConfiguration.self, from: raw), Self.valid(candidate) { configuration = candidate }
            else { message = "archive_configuration_missing" }
        }
        startLoop()
    }
    private func startLoop() {
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                do { try await Task.sleep(for: .seconds(5)) } catch { break }
            }
        }
    }
    private static func valid(_ value: MomentsConfiguration) -> Bool {
        let allowed = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files/").path + "/"
        let sns = URL(fileURLWithPath: value.snsDB).standardizedFileURL.path
        guard sns.hasPrefix(allowed), sns.hasSuffix("/db_storage/sns/sns.db"),
              value.keysFile == URL(fileURLWithPath: value.archiveRoot).appendingPathComponent("data/private/local-db-keys.json").path else { return false }
        if let contact = value.contactDB {
            guard contact == String(sns.dropLast("sns/sns.db".count)) + "contact/contact.db" else { return false }
        }
        return true
    }
    var destination: String {
        guard let destination = configuration?.nasDestination else { return "尚未选择" }
        return destination.share + (destination.directory.isEmpty ? "" : "/" + destination.directory) + "/Friday"
    }
    var canOpenNAS: Bool { mountedNAS != nil && nasError == nil }
    var collecting: Bool { configuration?.collecting == true }
    var needsDiskAccess: Bool { message == "full_disk_access_required" }
    var viewerURL: URL { URL(string: "http://127.0.0.1:8791/")! }
    private func save() throws {
        try MomentsFiles.privateDirectory(home)
        try JSONEncoder().encode(configuration).write(to: home.appendingPathComponent("configuration.json"), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: home.appendingPathComponent("configuration.json").path)
    }
    func importArchive() {
        guard available, !busy, worker == nil else { return }
        let panel = NSOpenPanel()
        panel.title = "选择现有朋友圈归档"
        panel.message = "选择包含 data/moments.json 的文件夹。已有图片、停止记录和下载进度都会保留。"
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.prompt = "使用归档"
        guard panel.runModal() == .OK, let root = panel.url else { return }
        let config = MomentsFiles.json(root.appendingPathComponent("data/private/local-service-config.json"))
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("data/moments.json").path),
            let sns = config["sns_db"] as? String, let keys = config["keys_file"] as? String,
            URL(fileURLWithPath: sns).lastPathComponent == "sns.db" else { message = "archive_configuration_missing"; return }
        let candidate = MomentsConfiguration(archiveRoot: root.path, snsDB: sns, contactDB: config["contact_db"] as? String, keysFile: keys)
        guard Self.valid(candidate) else { message = "archive_configuration_missing"; return }
        configuration = candidate
        do { try save(); failedWorker = false; message = nil } catch { message = "configuration_save_failed" }
    }
    func attachNAS(_ owner: (any NASArchivePickerOwner)?) { nasOwner = owner }
    func selectNAS(_ destination: NASArchiveDestination) {
        guard available, configuration != nil, !syncing else { return }
        configuration?.nasDestination = destination
        configuration?.nasDisplayPath = destination.displayPath
        configuration?.nasBookmark = nil
        do { try save(); nasError = nil; lastSyncAt = .distantPast; syncedArchiveIdentity = nil }
        catch { nasError = "未能保存这个位置。" }
    }
    func openNAS() {
        guard let mountedNAS, (try? mountedNAS.validate()) != nil else { return }
        NSWorkspace.shared.open(mountedNAS.root.appendingPathComponent("Friday", isDirectory: true))
    }
    func toggle() async {
        guard available, configuration != nil, !busy, !closing else { return }
        if collecting {
            configuration?.collecting = false
            do { try save() } catch { message = "configuration_save_failed" }
            _ = await stopWorker()
        } else {
            configuration?.collecting = true; failedWorker = false; message = nil
            do { try save() } catch { message = "configuration_save_failed" }
        }
    }
    func grantDiskAccess() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }
    func recoverImages() {
        guard available,configuration != nil,collecting,!closing,!imageStopPreserved,!recoveryPending else{return}
        do {
            try MomentsFiles.privateDirectory(home.appendingPathComponent("requests"))
            let id=UUID().uuidString.lowercased()
            try MomentsFiles.writeJSON(["schema":1,"id":id,"kind":"recover_images",
                "created_at":ISO8601DateFormatter().string(from:Date())],home.appendingPathComponent("requests/"+id+".json"))
            recoveryRequestID=id;imageRecoveryMessage=nil
            recoveryPending=true;nextRecoveryRequest=Date().addingTimeInterval(60)
        } catch {message="image_recovery_request_failed"}
    }
    func prepareImageResume()->Bool {
        guard available,collecting,!closing,!recoveryPending,canReconfirmImages,
              let confirmation=MomentsFiles.json(home.appendingPathComponent("bridge-status.json"))["image_resume_confirmation"] as? [String:Any],
              let stop=confirmation["stop_fingerprint"] as? [String:Any] else{return false}
        imageResumeStop=stop;return true
    }
    func cancelImageResume() {imageResumeStop=nil}
    func reconfirmImages() {
        guard let stop=imageResumeStop,available,collecting,!closing,!recoveryPending else{return}
        imageResumeStop=nil
        do {
            try MomentsFiles.privateDirectory(home.appendingPathComponent("requests"))
            let id=UUID().uuidString.lowercased()
            try MomentsFiles.writeJSON(["schema":1,"id":id,"kind":"reconfirm_images","expected_stop":stop,
                "created_at":ISO8601DateFormatter().string(from:Date())],home.appendingPathComponent("requests/"+id+".json"))
            recoveryRequestID=id;imageRecoveryMessage=nil
            recoveryPending=true;nextRecoveryRequest=Date().addingTimeInterval(60)
        } catch {imageRecoveryMessage="未能提交恢复请求，请稍后重试。"}
    }
    func retryNASBackup() {
        guard !syncing, let configuration, configuration.nasDestination != nil else { return }
        syncedArchiveIdentity=nil
        syncNAS(configuration)
    }
    private func riskBlocked(_ archive: URL) -> Bool {
        let q = MomentsFiles.json(archive.appendingPathComponent("data/image-queue.json"))
        return q["halted"] as? Bool == true || q["risk_control_suspected"] as? Bool == true
            || FileManager.default.fileExists(atPath: archive.appendingPathComponent("data/.local-service.stop").path)
    }
    private func tick() async {
        guard available, !closing, let configuration else { return }
        defer { persistStatus() }
        let archive = URL(fileURLWithPath: configuration.archiveRoot, isDirectory: true)
        let status = MomentsFiles.json(archive.appendingPathComponent("data/local-service-status.json"))
        let queue = MomentsFiles.json(archive.appendingPathComponent("data/image-queue.json"))
        let bridge = MomentsFiles.json(home.appendingPathComponent("bridge-status.json"))
        canReconfirmImages=bridge["image_resume_confirmation"] is [String:Any]
        imageStopPreserved=queue["halted"] as? Bool == true || queue["risk_control_suspected"] as? Bool == true
        let downloadCode = bridge["download_block_reason"] as? String
            ?? (status["phase"] as? String == "watching_downloads_paused" ? status["error_code"] as? String : nil)
        imageDownloadIssue = downloadCode == "image_authorization_or_global_stop"
            ? "图片下载已暂停：下载授权需要重新确认，待下载图片暂未继续。"
            : imageStopPreserved ? "图片下载已暂停，请先核对停止原因。" : nil
        if let id=recoveryRequestID {
            let reply=MomentsFiles.json(home.appendingPathComponent("responses/"+id+".json"))
            if reply["schema"] as? Int == 1, reply["id"] as? String == id {
                recoveryPending=false;recoveryRequestID=nil
                if reply["reconfirmed"] as? Bool == true {
                    imageDownloadIssue=nil
                    imageRecoveryMessage="图片下载已恢复，等待下载的图片将逐步补齐。"
                } else if reply["blocked"] as? Bool == true {
                    imageRecoveryMessage="本次检查未启动下载：图片下载仍处于暂停状态。"
                } else if let requeued=reply["requeued"] as? Int, (0...10000).contains(requeued),
                          let waiting=reply["waiting_for_new_locator"] as? Int, (0...10000).contains(waiting) {
                    imageRecoveryMessage = requeued>0 ? "已重新排入 \(requeued) 张图片，将按队列逐步下载。"
                        : waiting>0 ? "已检查，\(waiting) 张图片仍需微信提供新的下载地址。" : "已检查，暂无可重新下载的图片。"
                } else {imageRecoveryMessage="图片检查未完成，请稍后重试。"}
            } else if Date()>=nextRecoveryRequest {
                recoveryPending=false;recoveryRequestID=nil
                imageRecoveryMessage="尚未收到图片检查结果，请稍后重试。"
            }
        }
        var counts = [String: Int]()
        for record in (queue["assets"] as? [String: [String: Any]] ?? [:]).values {
            if let state = record["status"] as? String { counts[state, default: 0] += 1 }
        }
        remainingImages = (counts["queued"] ?? 0) + (counts["attempted"] ?? 0) + (counts["downloading"] ?? 0)
        failedImages = counts["failed"] ?? 0
        postCount = status["posts"] as? Int ?? postCount
        latestPost = status["latest_post_at"] as? String ?? latestPost
        if postCount == 0 {
            let posts = MomentsFiles.json(archive.appendingPathComponent("data/moments.json"))["posts"] as? [[String: Any]] ?? []
            postCount = posts.count
            if let newest = posts.compactMap({ $0["created_at_unix"] as? Double }).max() {
                latestPost = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: newest))
            }
        }
        // NAS replication is local archive work and may continue while CDN
        // downloads are halted. Never clear or renew the image stop/grant.
        let archiveIdentity = try? MomentsFiles.identity(archive.appendingPathComponent("data/moments.json"))
        if !syncing, Date().timeIntervalSince(lastSyncAt) >= 60, configuration.nasDestination != nil,
           archiveIdentity != syncedArchiveIdentity { syncNAS(configuration) }
        // Serving the archive is offline and remains available across a queued
        // image stop. The child checks the preserved stop before any refresh or
        // CDN work; starting it here cannot resume the stopped queue.
        if let worker,!worker.isRunning {
            self.worker=nil;running=false;workerFailures=min(workerFailures+1,5)
            nextWorkerStart=Date().addingTimeInterval([2.0,5,15,30,60][workerFailures-1]);message="worker_stopped"
        }
        if worker?.isRunning == true,Date().timeIntervalSince(workerStartedAt)>120 {workerFailures=0}
        if configuration.collecting, worker == nil, Date()>=nextWorkerStart { startWorker(configuration) }
        guard configuration.collecting,
              !FileManager.default.fileExists(atPath: archive.appendingPathComponent("data/.local-service.stop").path) else { return }
        var refreshRequests = [MomentsBridgeRequest]()
        do {
            var root: URL?
            if let mountedNAS { try mountedNAS.validate(); root = mountedNAS.root }
            let bridgeHome = home
            let bridgeRoot = root
            refreshRequests = try await Task.detached(priority: .utility) { try MomentsBridge.poll(root: bridgeRoot, home: bridgeHome) }.value
        } catch { /* A disconnected NAS cannot block local capture. */ }
        busy = true; defer { busy = false }
        do {
            let fingerprint = try await Task.detached(priority: .utility) { try MomentsFiles.fingerprint(configuration) }.value
            let now = Date()
            if fingerprint != pendingFingerprint { pendingFingerprint = fingerprint; changedAt = now }
            if (fingerprint != lastFingerprint || !refreshRequests.isEmpty) && now.timeIntervalSince(changedAt) >= 5 && now.timeIntervalSince(attemptedAt) >= 30 {
                attemptedAt = now
                let captureHome = home
                try await Task.detached(priority: .utility) { try MomentsFiles.capture(configuration, home: captureHome, fingerprint: fingerprint) }.value
                try MomentsBridge.captured(refreshRequests, home: home)
                lastFingerprint = fingerprint; captureDate = Date(); message = riskBlocked(archive) ? "download_stop_preserved" : nil
            }
        } catch { message = (error as? MomentsFault)?.code ?? "capture_failed" }
    }
    private func startWorker(_ configuration: MomentsConfiguration) {
        guard let resources = Bundle.main.resourceURL else { return }
        let executable = resources.appendingPathComponent("NASRuntime/python/bin/python3.12")
        let entry = resources.appendingPathComponent("MomentsRuntime/entry.py")
        do {
            try MomentsFiles.privateDirectory(home)
            let configPath = home.appendingPathComponent("worker.json")
            try MomentsFiles.writeJSON(["sns_db": "native-capture-only", "keys_file": configuration.keysFile,
                "output": URL(fileURLWithPath: configuration.archiveRoot).appendingPathComponent("data").path,
                "native_capture_manifest": home.appendingPathComponent("capture.json").path,
                "native_capture_lock": home.appendingPathComponent("capture.lock").path,
                "bridge_home": home.path,
                "owner_pid": Int(getpid()), "poll_seconds": 5, "quiet_seconds": 5, "refresh_min_seconds": 30,
                "max_defer_seconds": 120, "images_enabled": true,"safe_image_recovery":true, "viewer_port": 8791], configPath)
            let child = Process(); child.executableURL = executable
            child.arguments = ["-I", "-B", entry.path, "--config", configPath.path]
            child.environment = ["PATH": "/usr/bin:/bin", "HOME": FileManager.default.homeDirectoryForCurrentUser.path, "LANG": "en_US.UTF-8", "PYTHONDONTWRITEBYTECODE": "1"]
            child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
            try child.run(); worker = child; running = true;failedWorker=false;workerStartedAt=Date()
            if message=="worker_stopped" || message=="worker_launch_failed" {message=nil}
        } catch {
            failedWorker=true;message="worker_launch_failed";workerFailures=min(workerFailures+1,5)
            nextWorkerStart=Date().addingTimeInterval([2.0,5,15,30,60][workerFailures-1])
        }
    }
    private func syncNAS(_ configuration: MomentsConfiguration) {
        guard let destination = configuration.nasDestination, let nasOwner,
              let templateURL = Bundle.main.resourceURL?.appendingPathComponent("MomentsRuntime/worker/viewer.template.html"),
              let template = try? String(contentsOf: templateURL, encoding: .utf8) else { return }
        lastSyncAt = Date(); syncing = true
        syncTask = Task {
            defer { syncing = false }
            do {
                let mount = try await nasOwner.connectArchive(destination)
                mountedNAS = mount
                let archive = URL(fileURLWithPath: configuration.archiveRoot)
                let identityBefore = try MomentsFiles.identity(archive.appendingPathComponent("data/moments.json"))
                // The new worker understands the private NAS receipt. Its local
                // viewer keeps the same URL and serves verified NAS media.
                _ = try await Task.detached(priority: .utility) {
                    try MomentsNAS.sync(archive: archive, destination: mount.root, template: template,
                        validate: { try mount.validate() }, reclaim: true)
                }.value
                syncedArchiveIdentity = identityBefore; nasDate = Date(); nasError = nil; persistStatus()
            } catch {
                let code = (error as? MomentsFault)?.code ?? (error as? NASRuntimeFailure)?.rawValue
                    ?? (error as? CredentialError).map {String(describing:$0)} ?? "connection_failed"
                switch code {
                case "archive_busy","busy": break // Wait for the existing local operation; the next tick retries.
                case "nas_access_denied": nasError="NAS 连接未启用 SMB 加密，备份尚未进行。请在 NAS 开启共享加密后重试。"
                case "staleReference","notFound","wrongPurpose": nasError="NAS 登录信息已变化，请重新选择备份位置。"
                case "nas_hash_mismatch","media_hash_mismatch","reclaim_verification_failed": nasError="备份校验未通过。未校验的本地文件已保留，请重试备份。"
                default: nasError="暂时无法连接备份目录，尚未完成同步。网络恢复后会自动重试。"
                }
            }
        }
    }
    private func persistStatus() {
        try? MomentsFiles.privateDirectory(home)
        var value: [String: Any] = ["schema": 1, "owner": "local.arl.control", "checked_at": ISO8601DateFormatter().string(from: Date()),
            "collecting": collecting, "worker_running": running, "posts": postCount, "remaining_images": remainingImages,
            "nas_syncing": syncing,
            "failed_images": failedImages, "uses_llm": false, "uses_wx_cli": false, "account_protocol_enabled": false,
            "finder_downloads_enabled": false, "image_min_interval_seconds": 30, "image_cooldown_every": 10, "image_cooldown_seconds": 120]
        if let message { value["error_code"] = message }
        if let nasError { value["nas_error"] = nasError }
        if let captureDate { value["last_native_source_capture_at"] = ISO8601DateFormatter().string(from: captureDate) }
        if let nasDate { value["last_nas_commit_at"] = ISO8601DateFormatter().string(from: nasDate) }
        if let latestPost { value["latest_post_at"] = latestPost }
        try? MomentsFiles.writeJSON(value, home.appendingPathComponent("status.json"))
    }
    private func stopWorker() async -> Bool {
        guard let worker else { return true }
        worker.terminate()
        let deadline = Date().addingTimeInterval(40)
        while worker.isRunning && Date() < deadline { try? await Task.sleep(for: .milliseconds(100)) }
        guard !worker.isRunning else { message = "worker_draining"; return false }
        self.worker = nil; running = false; return true
    }
    func cancelExit() {
        guard available, closing else { return }
        closing = false; startLoop()
    }
    func stop() async -> Bool {
        if syncing { message = "nas_draining"; return false }
        closing = true
        loop?.cancel()
        await loop?.value
        await syncTask?.value
        return await stopWorker()
    }
}
