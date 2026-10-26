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
    #if ARL_LIFECYCLE_TEST
    var afterDrainTestHook: (() async -> Void)?
    var activationTestHook: (() throws -> Void)?
    static func fixture() -> BundledRuntimeOwner { BundledRuntimeOwner() }
    var testChildCount: Int { children.count }
    func addTestChild(_ process: Process) { children["core"] = process }
    #endif
    private var children: [String: Process] = [:]
    private(set) var failure: String?
    private(set) var activated = false
    static func start(home: URL, enabled: Bool) -> BundledRuntimeOwner? {
        guard enabled else { return nil }
        let owner = BundledRuntimeOwner()
        guard FileManager.default.fileExists(atPath: home.appendingPathComponent("unified-runtime.json").path) else { return nil }
        ARLConnectionLog.production.record("arl", "starting")
        do { try owner.activate(home: home); ARLConnectionLog.production.record("arl", "started") }
        catch { owner.failure = "bundled_runtime_start_failed"; ARLConnectionLog.production.record("arl", "start_failed", ["failed": true]) }
        current = owner
        return owner
    }
    private func activate(home: URL) throws {
        guard !exitRequested else { throw ARLError(code:"bundled_runtime_exiting") }
        #if ARL_LIFECYCLE_TEST
        if let activationTestHook { try activationTestHook(); return }
        #endif
        generation = UUID(); failure = nil
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
        try launch("core", executable: python, arguments: ["-I", "-B", entry.path, "--parent-pid", String(getpid())])
        activated = true
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
            try launch("mio", executable: executable, arguments: ["--host", policy.path, "--approved-policy-sha256", seal])
        }
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
        let launchGeneration = generation
        process.terminationHandler = { [weak self] child in
            ARLConnectionLog.production.record(key, "stopped", ["exit_code": child.terminationStatus, "failed": child.terminationStatus != 0])
            Task { @MainActor in
                guard let self, self.generation == launchGeneration else { return }
                self.failure = "bundled_" + key + "_stopped"
            }
        }
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
    func requestExit() { exitRequested = true }
    func cancelExit() { exitRequested = false }
    private func acquire() async -> UUID? {
        let deadline = ProcessInfo.processInfo.systemUptime + 40
        while operation != nil && ProcessInfo.processInfo.systemUptime < deadline {
            do { try await Task.sleep(for: .milliseconds(20)) } catch { return nil }
        }
        guard operation == nil else { failure = "bundled_runtime_cleanup_pending"; return nil }
        let token = UUID(); operation = token; return token
    }
    private func release(_ token: UUID) { if operation == token { operation = nil } }
    func recover(home: URL) async -> Bool {
        guard !exitRequested, let token = await acquire() else { return false }
        defer { release(token) }
        guard !exitRequested, await drain(token) else { return false }
        #if ARL_LIFECYCLE_TEST
        if let afterDrainTestHook { await afterDrainTestHook() }
        #endif
        guard operation == token, !exitRequested else { return false }
        do { try activate(home: home); return true }
        catch { failure = "bundled_runtime_start_failed"; return false }
    }
    func stopAndDrain(forExit: Bool = false) async -> Bool {
        if forExit { requestExit() }
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
