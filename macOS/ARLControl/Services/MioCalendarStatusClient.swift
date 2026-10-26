import Foundation
import Darwin
import Security
import AppKit

/// A read-only consumer for the signed Mio Calendar effect host's status CLI.
/// This never calls --authorize-session and never reads an EventKit store.
struct MioCalendarStatusClient: Sendable {
    let home: URL
    private static let app = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LoginItems/ARLMioAppleBridge.app").path
    private static let executable = app + "/Contents/MacOS/ARLMioAppleBridge"
    private static let signedRequirement = "identifier \"local.arl.mioapplebridge\" and certificate root = H\"859332b7fffbbbb33b80c7b78d30c27d2d81583f\""

    func read() async throws -> MioCalendarPermissionStatus {
        try await Task.detached(priority: .utility) { try Self.readSync(home: home) }.value
    }

    private static func readSync(home: URL) throws -> MioCalendarPermissionStatus {
        _ = try verifiedApp(home: home)
        var output: [Int32] = [0, 0]
        guard pipe(&output) == 0 else { throw MioCalendarStatusFault.probeUnavailable }
        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else {
            close(output[0]); close(output[1]); throw MioCalendarStatusFault.probeUnavailable
        }
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, output[1], STDOUT_FILENO)
        posix_spawn_file_actions_addclose(&actions, output[0])
        posix_spawn_file_actions_addclose(&actions, output[1])
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)
        let args = [strdup(executable), strdup("--authorization-status"), nil]
        let environment = [strdup("PATH=/usr/bin:/bin"), nil]
        defer { for item in args + environment { free(item) } }
        var pid: pid_t = 0
        let status = args.withUnsafeBufferPointer { arg in
            environment.withUnsafeBufferPointer { env in
                posix_spawn(&pid, executable, &actions, nil,
                            UnsafeMutablePointer(mutating: arg.baseAddress!),
                            UnsafeMutablePointer(mutating: env.baseAddress!))
            }
        }
        close(output[1])
        guard status == 0 else { close(output[0]); throw MioCalendarStatusFault.probeUnavailable }
        defer {
            close(output[0])
            var exitStatus: Int32 = 0
            if waitpid(pid, &exitStatus, WNOHANG) == 0 {
                kill(pid, SIGTERM)
                _ = waitpid(pid, &exitStatus, 0)
            }
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        var data = Data()
        while ProcessInfo.processInfo.systemUptime < deadline {
            var poller = pollfd(fd: output[0], events: Int16(POLLIN), revents: 0)
            let remaining = max(1, Int32((deadline - ProcessInfo.processInfo.systemUptime) * 1000))
            let ready = poll(&poller, 1, remaining)
            if ready < 0 && errno == EINTR { continue }
            guard ready > 0 else { throw MioCalendarStatusFault.probeUnavailable }
            var byte: UInt8 = 0
            guard Darwin.read(output[0], &byte, 1) == 1 else { throw MioCalendarStatusFault.probeUnavailable }
            if byte == 10 {
                let now = Int64(Date().timeIntervalSince1970 * 1000)
                return try MioCalendarPermissionStatus.decode(data, observedAtMS: now)
            }
            data.append(byte)
            guard data.count <= 1024 else { throw MioCalendarStatusFault.invalidResponse }
        }
        throw MioCalendarStatusFault.probeUnavailable
    }

    private static func verifiedApp(home: URL) throws -> URL {
        let config = home.appendingPathComponent("mio-apple/status-consumer.json").path
        guard FileManager.default.fileExists(atPath: config) else { throw MioCalendarStatusFault.notDeployed }
        let raw = try RemindersNativeIO.privateFile(config)
        let object = try RemindersNativeIO.flatObject(raw)
        guard Set(object.keys) == ["schema_version", "enabled", "helper_bundle_id", "helper_cdhash", "helper_requirement", "helper_executable_sha256"],
              RemindersNativeIO.integer(object["schema_version"]) == 1,
              RemindersNativeIO.integer(object["enabled"]) == 1,
              object["helper_bundle_id"] as? String == "local.arl.mioapplebridge",
              let cdhash = object["helper_cdhash"] as? String,
              cdhash.range(of: "^[a-f0-9]{40}$", options: .regularExpression) != nil,
              let requirement = object["helper_requirement"] as? String,
              requirement == signedRequirement,
              let executableSHA = object["helper_executable_sha256"] as? String,
              executableSHA.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil
        else { throw MioCalendarStatusFault.identityUnverified }
        var statInfo = stat()
        guard lstat(executable, &statInfo) == 0,
              statInfo.st_mode & S_IFMT == S_IFREG,
              statInfo.st_uid == getuid(),
              statInfo.st_mode & 0o022 == 0,
              URL(fileURLWithPath: executable).resolvingSymlinksInPath().path == executable,
              RemindersNativeIO.hash(try Data(contentsOf: URL(fileURLWithPath: executable))) == executableSHA
        else { throw MioCalendarStatusFault.identityUnverified }
        var code: SecStaticCode?, rule: SecRequirement?, signing: CFDictionary?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: app) as CFURL, [], &code) == errSecSuccess,
              let code,
              SecRequirementCreateWithString(requirement as CFString, [], &rule) == errSecSuccess,
              let rule,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), rule) == errSecSuccess,
              SecCodeCopySigningInformation(code, [], &signing) == errSecSuccess,
              let observedCDHash = (signing as? [String: Any])?[kSecCodeInfoUnique as String] as? Data,
              observedCDHash.map({ String(format: "%02x", $0) }).joined() == cdhash
        else { throw MioCalendarStatusFault.identityUnverified }
        return URL(fileURLWithPath: app)
    }
}
