import Foundation
import Security
import Darwin

/// One ARL process owns the fixed packaged runtime children. Local activation is
/// created only by a reviewed migration; no RPC, launch argument or discovery
/// enables it. Credentials and scope remain in their existing repositories.
@MainActor final class BundledRuntimeOwner {
    static private(set) var current: BundledRuntimeOwner?
    private var generation = UUID()
    private var operation: UUID?
    private var exitRequested = false
    private var watchdog: Task<Void, Never>?
    private var watchdogHome: URL?
    private var wantsRunning = false
    private var expectedChildren: Set<String> = []
    private var recoveryAttempt = 0
    private var nextRecoveryAt: TimeInterval?
    private var runningSince: TimeInterval?
    private let recoveryInitialDelay: TimeInterval
    private let recoveryMaximumDelay: TimeInterval
    private let recoveryStableSeconds: TimeInterval
    private let watchdogInterval: TimeInterval
    private init(initialDelay: TimeInterval = 1, maximumDelay: TimeInterval = 60,
                 stableSeconds: TimeInterval = 60, interval: TimeInterval = 1) {
        recoveryInitialDelay = initialDelay; recoveryMaximumDelay = maximumDelay
        recoveryStableSeconds = stableSeconds; watchdogInterval = interval
    }
    #if ARL_LIFECYCLE_TEST
    var afterDrainTestHook: (() async -> Void)?
    var activationTestHook: (() throws -> Void)?
    static func fixture(automatic: Bool = false) -> BundledRuntimeOwner {
        automatic ? BundledRuntimeOwner(initialDelay: 0.04, maximumDelay: 0.16, stableSeconds: 0.3, interval: 0.01) : BundledRuntimeOwner()
    }
    var testChildCount: Int { children.count }
    var testRecoveryAttempt: Int { recoveryAttempt }
    func testChild(_ key: String) -> Process? { children[key] }
    func addTestChild(_ process: Process, key: String = "core") {
        children[key] = process; observeTermination(process, key: key)
    }
    func startTestWatchdog(home: URL) { wantsRunning = true; startWatchdog(home: home) }
    #endif
    private var children: [String: Process] = [:]
    private(set) var failure: String?
    private(set) var activated = false
    var watchdogRunning: Bool { watchdog != nil && wantsRunning && !exitRequested }
    static func start(home: URL, enabled: Bool) -> BundledRuntimeOwner? {
        guard enabled else { return nil }
        let owner = BundledRuntimeOwner()
        guard FileManager.default.fileExists(atPath: home.appendingPathComponent("unified-runtime.json").path) else { return nil }
        ARLConnectionLog.production.record("arl", "starting")
        do { try owner.activate(home: home); ARLConnectionLog.production.record("arl", "started") }
        catch { owner.failure = "bundled_runtime_start_failed"; ARLConnectionLog.production.record("arl", "start_failed", ["failed": true]) }
        owner.wantsRunning = true
        owner.startWatchdog(home: home)
        current = owner
        return owner
    }
    private func activate(home: URL) throws {
        guard !exitRequested else { throw ARLError(code:"bundled_runtime_exiting") }
        generation = UUID(); failure = nil; runningSince = nil
        #if ARL_LIFECYCLE_TEST
        if let activationTestHook {
            try activationTestHook(); expectedChildren = Set(children.keys)
            activated = true; runningSince = ProcessInfo.processInfo.systemUptime; return
        }
        #endif
        let raw = try RemindersNativeIO.privateFile(home.appendingPathComponent("unified-runtime.json").path)
        let activation = try RemindersNativeIO.flatObject(raw)
        guard Set(activation.keys) == ["schema_version", "enabled", "core_manifest_sha256", "mio_enabled"],
              RemindersNativeIO.integer(activation["schema_version"]) == 1,
              RemindersNativeIO.integer(activation["enabled"]) == 1,
              let mio = RemindersNativeIO.integer(activation["mio_enabled"]), [0, 1].contains(mio),
              let seal = activation["core_manifest_sha256"] as? String,
              Bundle.main.object(forInfoDictionaryKey: "ARLCoreRuntimeManifestSHA256") as? String == seal,
              let resources = Bundle.main.resourceURL,
              RemindersNativeIO.hash(try Data(contentsOf: resources.appendingPathComponent("CoreRuntime/manifest.json"))) == seal
        else { throw ARLError(code: "identity_unverified") }
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              InstallManagement.validateDynamicAndStatic(code, requirement: nil)
        else { throw ARLError(code: "identity_unverified") }
        let python = resources.appendingPathComponent("NASRuntime/python/bin/python3.12")
        let entry = resources.appendingPathComponent("CoreRuntime/entry.py")
        expectedChildren = mio == 1 ? ["core", "mio"] : ["core"]
        guard Set(children.keys).isSubset(of: expectedChildren) else { throw ARLError(code: "identity_unverified") }
        try ensureChild("core", executable: python, arguments: ["-I", "-B", entry.path, "--parent-pid", String(getpid())])
        if mio == 1 {
            let nested = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LoginItems/ARLMioAppleBridge.app")
            guard let bundle = Bundle(url: nested),
                  let seal = bundle.object(forInfoDictionaryKey: "ARLApprovedPolicySHA256") as? String,
                  seal.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
                  let executable = bundle.executableURL
            else { throw ARLError(code: "identity_unverified") }
            // Preserve the existing sealed policy and profile bytes. No init,
            // doctor, account creation or authorization is performed here.
            let policy = home.appendingPathComponent("mio-apple/activation.json")
            guard RemindersNativeIO.hash(try RemindersNativeIO.privateFile(policy.path)) == seal
            else { throw ARLError(code: "identity_unverified") }
            try ensureChild("mio", executable: executable, arguments: ["--host", policy.path, "--approved-policy-sha256", seal])
        }
        activated = true; runningSince = ProcessInfo.processInfo.systemUptime
    }
    #if !ARL_LIFECYCLE_TEST
    private func publishOwnership() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/ARL")
        var records: [String:Any] = [:]
        for (key,child) in children { records[key] = try InstallManagement.record(child.processIdentifier) }
        let value: [String:Any] = ["schema_version":1,"owner":try InstallManagement.record(getpid()),"children":records]
        let data = try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys])
        let temporary = home.appendingPathComponent(".owned-runtime-" + UUID().uuidString)
        let fd = open(temporary.path,O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,0o600)
        guard fd >= 0 else { throw ARLError(code:"install_receipt_unavailable") }
        let stream = FileHandle(fileDescriptor:fd,closeOnDealloc:true)
        try stream.write(contentsOf:data);try stream.synchronize();try stream.close()
        guard rename(temporary.path,home.appendingPathComponent("owned-runtime.json").path)==0 else { throw ARLError(code:"install_receipt_unavailable") }
    }
    #endif
    private func ensureChild(_ key: String, executable: URL, arguments: [String]) throws {
        if let child = children[key] {
            guard child.isRunning, child.executableURL == executable, child.arguments == arguments
            else { throw ARLError(code: "bundled_runtime_cleanup_pending") }
            observeTermination(child, key: key)
            return
        }
        try launch(key, executable: executable, arguments: arguments)
    }
    private func launch(_ key: String, executable: URL, arguments: [String]) throws {
        guard children[key] == nil, executable.resolvingSymlinksInPath().path == executable.path,
              executable.path.hasPrefix(Bundle.main.bundleURL.path + "/") else { throw ARLError(code: "unsafe_home") }
        let process = Process()
        process.executableURL = executable; process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory(), "LANG": "C", "PYTHONDONTWRITEBYTECODE": "1"]
        let output = Pipe(), errors = Pipe()
        ARLConnectionLog.production.capture(output, source: key, stream: "stdout")
        ARLConnectionLog.production.capture(errors, source: key, stream: "stderr")
        process.standardInput = FileHandle.nullDevice; process.standardOutput = output; process.standardError = errors
        observeTermination(process, key: key)
        ARLConnectionLog.production.record(key, "starting")
        do { try process.run() }
        catch { ARLConnectionLog.production.record(key, "start_failed", ["failed": true]); throw error }
        try? output.fileHandleForWriting.close(); try? errors.fileHandleForWriting.close()
        ARLConnectionLog.production.record(key, "started", ["peer_pid": process.processIdentifier])
        children[key] = process
        #if !ARL_LIFECYCLE_TEST
        try publishOwnership()
        #endif
    }
    private func observeTermination(_ process: Process, key: String) {
        let launchGeneration = generation
        process.terminationHandler = { [weak self] child in
            ARLConnectionLog.production.record(key, "stopped", ["exit_code": child.terminationStatus, "failed": child.terminationStatus != 0])
            Task { @MainActor in
                guard let self, self.generation == launchGeneration,
                      self.children[key] === child, self.wantsRunning, !self.exitRequested else { return }
                self.noteFailure("bundled_" + key + "_stopped")
            }
        }
    }
    private func noteFailure(_ code: String) {
        failure = code; activated = false; runningSince = nil
        if nextRecoveryAt == nil {
            let delay = min(recoveryMaximumDelay, recoveryInitialDelay * pow(2, Double(min(recoveryAttempt, 16))))
            nextRecoveryAt = ProcessInfo.processInfo.systemUptime + delay
            ARLConnectionLog.production.record("arl", "retry", ["retry_in_ms": delay * 1000, "failed": true])
        }
    }
    private func startWatchdog(home: URL) {
        watchdogHome = home
        guard watchdog == nil, wantsRunning, !exitRequested else { return }
        let interval = watchdogInterval
        watchdog = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(interval)) } catch { return }
                guard let self else { return }
                await self.watchdogTick(home: home)
            }
        }
    }
    private func watchdogTick(home: URL) async {
        guard wantsRunning, !exitRequested, !Task.isCancelled, operation == nil,
              !FileManager.default.fileExists(atPath: home.appendingPathComponent("disabled").path),
              !FileManager.default.fileExists(atPath: home.appendingPathComponent("install-maintenance.json").path)
        else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if failure == nil {
            if !expectedChildren.isEmpty && expectedChildren.contains(where: { children[$0]?.isRunning != true }) {
                noteFailure("bundled_runtime_child_stopped")
            } else {
                if let runningSince, now - runningSince >= recoveryStableSeconds { recoveryAttempt = 0 }
                return
            }
        }
        if nextRecoveryAt == nil { noteFailure(failure ?? "bundled_runtime_start_failed") }
        guard let nextRecoveryAt, now >= nextRecoveryAt else { return }
        recoveryAttempt = min(recoveryAttempt + 1, 16)
        self.nextRecoveryAt = nil
        _ = await repairChildren(home: home)
        if let failure, !exitRequested, !Task.isCancelled { noteFailure(failure) }
    }
    private func cancelWatchdog() { watchdog?.cancel(); watchdog = nil }
    func requestExit() { exitRequested = true; cancelWatchdog() }
    func cancelExit() {
        exitRequested = false
        if wantsRunning, let watchdogHome { startWatchdog(home: watchdogHome) }
    }
    #if !ARL_LIFECYCLE_TEST
    func messagesReceivePeer(_ fd:Int32)throws->MessagesReceiveRelayPeer {
        guard !exitRequested,activated,let process=children["core"],process.isRunning,
              let executable=process.executableURL else{throw MessagesReceiveFault("receive_core_unavailable")}
        return try MessagesReceiveRelayPeer(fd:fd,expectedPID:process.processIdentifier,
            expectedExecutable:executable,expectedParentPID:getpid())
    }
    #endif
    private func acquire() async -> UUID? {
        let deadline = ProcessInfo.processInfo.systemUptime + 40
        while operation != nil && ProcessInfo.processInfo.systemUptime < deadline {
            do { try await Task.sleep(for: .milliseconds(20)) } catch { return nil }
        }
        guard operation == nil else { failure = "bundled_runtime_cleanup_pending"; return nil }
        let token = UUID(); operation = token; return token
    }
    private func release(_ token: UUID) { if operation == token { operation = nil } }
    private func repairChildren(home: URL) async -> Bool {
        guard !exitRequested, let token = await acquire() else { return false }
        defer { release(token) }
        guard !exitRequested, !Task.isCancelled else { return false }
        // Reap only exact owned processes already observed exited. A healthy
        // sibling and its in-flight business operations keep their process.
        for (key, child) in children where !child.isRunning {
            child.waitUntilExit(); children[key] = nil
        }
        do { try activate(home: home); nextRecoveryAt = nil; return true }
        catch { failure = "bundled_runtime_start_failed"; return false }
    }
    func recover(home: URL) async -> Bool {
        guard !exitRequested else { return false }
        wantsRunning = true; startWatchdog(home: home)
        return await recoverChildren(home: home)
    }
    private func recoverChildren(home: URL) async -> Bool {
        guard !exitRequested, let token = await acquire() else { return false }
        defer { release(token) }
        guard !exitRequested, await drain(token) else { return false }
        #if ARL_LIFECYCLE_TEST
        if let afterDrainTestHook { await afterDrainTestHook() }
        #endif
        guard operation == token, !exitRequested else { return false }
        do { try activate(home: home); nextRecoveryAt = nil; return true }
        catch { failure = "bundled_runtime_start_failed"; return false }
    }
    func stopAndDrain(forExit: Bool = false) async -> Bool {
        if forExit { requestExit() }
        else { wantsRunning = false; cancelWatchdog() }
        guard let token = await acquire() else { return false }
        defer { release(token) }
        return await drain(token)
    }
    private func drain(_ token: UUID) async -> Bool {
        guard operation == token else { return false }
        generation = UUID()
        let drainGeneration = generation
        let deadline = ProcessInfo.processInfo.systemUptime + 40
        for key in ["mio", "core"] {
            guard let process = children[key] else { continue }
            ARLConnectionLog.production.record(key, "stopping")
            if process.isRunning { process.terminate() }
            while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return false }
            }
            guard operation == token, generation == drainGeneration, children[key] === process,
                  !process.isRunning else { failure = "bundled_runtime_cleanup_pending"; return false }
            process.waitUntilExit(); children[key] = nil
        }
        activated = false
        return true
    }
}
