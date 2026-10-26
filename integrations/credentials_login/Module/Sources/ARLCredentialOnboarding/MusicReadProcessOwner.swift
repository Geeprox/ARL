import Foundation
import Darwin

public enum MusicReadRuntimeFailure: String, Error, Sendable {
    case cleanupUnproven = "cleanup_unproven"
}
struct MusicCleanupStatus: Sendable, Equatable {
    enum Phase: Sendable { case idle, running, cleanupUnproven }
    let phase: Phase
    let generation: UUID?
    let lastReapedGeneration: UUID?
    var provedIdle: Bool { phase == .idle }
}
protocol MusicProcessBarrier: Sendable { func cleanupStatus() -> MusicCleanupStatus }
enum MusicReadSystemIdentity {
    static func read(_ pid: pid_t) -> proc_bsdinfo? {
        var value = proc_bsdinfo()
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &value, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size ? value : nil
    }
}

/// Direct child with one waitpid owner. No Foundation Process or independent
/// reaper exists. All waitpid and signal calls hold this lock. Until waitpid
/// consumes this child, its PID cannot be reused; identity-read failure does
/// not create the Foundation automatic-reaping race.
final class MusicReadOwnedChild: @unchecked Sendable {
    private let lock = NSLock()
    private var pid: pid_t = 0
    private var exitCode: Int32?
    private var ownershipLost = false
    #if ARL_OWNER_FIXTURE
    var fixtureObserveAutomatically = true
    #endif
    private var onReaped: (@Sendable () -> Void)?
    var processIdentifier: pid_t { lock.withLock { pid } }
    var isRunning: Bool { lock.withLock { pid > 0 && exitCode == nil } }
    var terminationStatus: Int32 { lock.withLock { exitCode ?? -1 } }

    func run(executable: URL, arguments: [String], environment: [String: String], directory: URL,
             input: Pipe, output: Pipe, reaped: @escaping @Sendable () -> Void) throws {
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw CredentialError.storageUnavailable }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { throw CredentialError.storageUnavailable }
        defer { posix_spawnattr_destroy(&attributes) }
        let nullFD = open("/dev/null", O_WRONLY | O_CLOEXEC)
        guard nullFD >= 0 else { throw CredentialError.storageUnavailable }
        defer { close(nullFD) }
        let inputFD = input.fileHandleForReading.fileDescriptor
        let outputFD = output.fileHandleForWriting.fileDescriptor
        guard posix_spawn_file_actions_adddup2(&actions, inputFD, STDIN_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, outputFD, STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, nullFD, STDERR_FILENO) == 0,
              posix_spawn_file_actions_addchdir_np(&actions, directory.path) == 0
        else { throw CredentialError.storageUnavailable }
        for fd in Set([inputFD, outputFD, nullFD, input.fileHandleForWriting.fileDescriptor, output.fileHandleForReading.fileDescriptor]) where fd > STDERR_FILENO {
            guard posix_spawn_file_actions_addclose(&actions, fd) == 0 else { throw CredentialError.storageUnavailable }
        }
        var mask = sigset_t(), defaults = sigset_t()
        sigemptyset(&mask); sigemptyset(&defaults)
        sigaddset(&defaults, SIGTERM); sigaddset(&defaults, SIGPIPE)
        guard posix_spawnattr_setsigmask(&attributes, &mask) == 0,
              posix_spawnattr_setsigdefault(&attributes, &defaults) == 0,
              posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)) == 0
        else { throw CredentialError.storageUnavailable }
        let argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
        let envp = environment.sorted { $0.key < $1.key }.map { strdup($0.key + "=" + $0.value) } + [nil]
        defer { argv.forEach { if let value = $0 { free(value) } }; envp.forEach { if let value = $0 { free(value) } } }
        guard argv.dropLast().allSatisfy({ $0 != nil }), envp.dropLast().allSatisfy({ $0 != nil }) else { throw CredentialError.storageUnavailable }
        var spawned: pid_t = 0
        let result = argv.withUnsafeBufferPointer { argvBuffer in
            envp.withUnsafeBufferPointer { envBuffer in
                posix_spawn(&spawned, executable.path, &actions, &attributes, argvBuffer.baseAddress!, envBuffer.baseAddress!)
            }
        }
        guard result == 0 else {
            #if ARL_OWNER_FIXTURE
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(result))
            #else
            throw CredentialError.storageUnavailable
            #endif
        }
        lock.withLock { pid = spawned; onReaped = reaped }
        #if ARL_OWNER_FIXTURE
        if !fixtureObserveAutomatically { return }
        #endif
        // The worker retains this exact child even if its request is cancelled.
        DispatchQueue.global(qos: .utility).async { [self] in
            while isRunning {
                pollExit()
                if lock.withLock({ ownershipLost }) { break }
                usleep(100000)
            }
        }
    }
    private func reapLocked() -> (live: Bool, callback: (@Sendable () -> Void)?) {
        guard pid > 0, exitCode == nil, !ownershipLost else { return (false, nil) }
        var status: Int32 = 0
        let observed = waitpid(pid, &status, WNOHANG)
        if observed == 0 { return (true, nil) }
        guard observed == pid else {
            // Another reaper or a permanent wait failure destroys ownership
            // proof. Never signal/retry this PID; retain the busy barrier.
            if observed < 0 && errno != EINTR { ownershipLost = true }
            return (false, nil)
        }
        exitCode = (status & 0x7f) == 0 ? ((status >> 8) & 0xff) : (128 + (status & 0x7f))
        let callback = onReaped; onReaped = nil
        return (false, callback)
    }
    func pollExit() {
        let result = lock.withLock { reapLocked() }
        result.callback?()
    }
    /// Reject a positive identity mismatch. If proc_pidinfo is unavailable,
    /// waitpid(WNOHANG)==0 still proves this is our unreaped direct child, and
    /// exclusive reaping under this lock keeps its PID reserved through kill.
    @discardableResult
    func signal(_ signal: Int32, expected: proc_bsdinfo?, identity: @Sendable (pid_t) -> proc_bsdinfo? = { MusicReadSystemIdentity.read($0) }) -> Bool {
        var callback: (@Sendable () -> Void)?
        let sent = lock.withLock { () -> Bool in
            let proof = reapLocked(); callback = proof.callback
            guard proof.live else { return false }
            if let now = identity(pid) {
                guard now.pbi_ppid == UInt32(getpid()), now.pbi_uid == getuid() else { return false }
                if let expected {
                    guard now.pbi_start_tvsec == expected.pbi_start_tvsec && now.pbi_start_tvusec == expected.pbi_start_tvusec else { return false }
                }
            }
            return kill(pid, signal) == 0
        }
        callback?()
        return sent
    }
}

/// Shared across all prepare/status/login/read transports. A request returns
/// after bounded cleanup, but the owner retains an unproved child indefinitely
/// and blocks a second reservation until its own waitpid confirms reaping.
final class MusicReadProcessOwner: @unchecked Sendable {
    static let shared = MusicReadProcessOwner()
    private struct Child {
        let generation: UUID
        let process: MusicReadOwnedChild
        var unproven = false
    }
    private let lock = NSLock()
    private var child: Child?
    private var lastReaped: UUID?
    func reserve(_ process: MusicReadOwnedChild) throws -> UUID {
        try lock.withLock {
            guard child == nil else { throw CredentialError.busy }
            let generation = UUID()
            child = Child(generation: generation, process: process)
            return generation
        }
    }
    func neverLaunched(_ generation: UUID, process: MusicReadOwnedChild) {
        lock.withLock {
            guard child?.generation == generation, child?.process === process else { return }
            child = nil
        }
    }
    func reaped(_ generation: UUID, process: MusicReadOwnedChild) {
        lock.withLock {
            guard child?.generation == generation, child?.process === process, !process.isRunning, process.terminationStatus >= 0 else { return }
            lastReaped = generation; child = nil
        }
    }
    func unproven(_ generation: UUID, process: MusicReadOwnedChild) {
        lock.withLock {
            guard child?.generation == generation, child?.process === process else { return }
            child?.unproven = true
        }
    }
    func status() -> MusicCleanupStatus {
        lock.withLock {
            guard let child else { return .init(phase: .idle, generation: nil, lastReapedGeneration: lastReaped) }
            return .init(phase: child.unproven ? .cleanupUnproven : .running, generation: child.generation, lastReapedGeneration: lastReaped)
        }
    }
}
