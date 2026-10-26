import Foundation
import Darwin
import Security
import AppKit

// A build-sealed local profile, never RPC/env/stdin policy. The shipped profile
// is disabled. An active profile/bundle/parent pin needs a separate review and
// approval; compiling this source does not register a caller or grant access.
@MainActor enum NotesControlledBootstrap {
    static func run() throws {
        guard let url = Bundle.main.url(forResource: "NotesProfile", withExtension: "json") else { throw ReviewFault("profile_invalid") }
        let raw = try Data(contentsOf: url)
        guard raw.count <= 4096, digest(raw) == NotesBuildSeal.profileHash else { throw ReviewFault("profile_invalid") }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &code) == errSecSuccess,
              let code, SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess else { throw ReviewFault("profile_invalid") }
        let p = try flatObject(raw, limit: 4096)
        guard Set(p.keys) == Set(["schema_version", "enabled", "caller_subject", "caller_requirement", "policy_epoch", "max_attempts", "expires_at_ms", "target_json"]), integer(p["schema_version"]) == 1 else { throw ReviewFault("profile_invalid") }
        guard integer(p["enabled"]) == 1 else { throw ReviewFault("host_disabled") }
        guard let subject = p["caller_subject"] as? String, identifier(subject),
              let requirement = p["caller_requirement"] as? String,
              requirement.range(of: "^cdhash H\"[a-f0-9]{40}\"$", options: .regularExpression) != nil,
              let epoch = integer(p["policy_epoch"]), epoch > 0,
              let budget = integer(p["max_attempts"]), (1...3).contains(budget),
              let expiry = integer(p["expires_at_ms"]), expiry > Int64(Date().timeIntervalSince1970 * 1000),
              expiry - Int64(Date().timeIntervalSince1970 * 1000) <= 300000,
              let targetJSON = p["target_json"] as? String,
              let t = try? flatObject(Data(targetJSON.utf8), limit: 3072), Set(t.keys) == Set(["alias", "account_id", "folder_id", "expected_name"]),
              let alias = t["alias"] as? String, let account = t["account_id"] as? String,
              let folder = t["folder_id"] as? String, let name = t["expected_name"] as? String,
              let pw = getpwuid(getuid()), let home = pw.pointee.pw_dir else { throw ReviewFault("profile_invalid") }
        let binding = NotesFolderBinding(alias: alias, accountID: account, folderID: folder, expectedName: name)
        try binding.validate()
        let parent = getppid()
        guard parent > 1 else { throw ReviewFault("caller_unverified") }
        // Fixed inherited connected FD, never a caller-specified socket/path.
        let registration = NotesPeerRegistration(subject: subject, pid: parent, requirement: requirement, epoch: UInt64(epoch), currentEpoch: {
            guard getppid() == parent, Int64(Date().timeIntervalSince1970 * 1000) < expiry,
                  let current = try? Data(contentsOf: url), digest(current) == NotesBuildSeal.profileHash else { return nil }
            return UInt64(epoch)
        })
        _ = try AuthenticatedCaller.fromRegisteredSocket(3, subject: subject, expectedPID: parent, requirement: requirement,
            registrationEpoch: UInt64(epoch), currentRegistrationEpoch: registration.currentEpoch)
        // The pre-existing state directory is created by a future reviewed
        // installer, not here. OS uid lookup avoids trusting a HOME override.
        let journalURL = URL(fileURLWithPath: String(cString: home)).appendingPathComponent("Library/Application Support/ARL/notes/state", isDirectory: true)
        let journal = try ConsumptionJournal(home: journalURL.path)
        let policy = NotesPolicy(epoch: epoch, callers: [subject: NotesCallerGrant(targets: [alias], nativeReview: true, workflowIssuers: [], maxAttempts: Int(budget))], targets: [alias: binding], issuerPublicKeys: [:])
        let engine = NotesApprovalEngine(journal: journal, policy: {
            registration.currentEpoch() == UInt64(epoch) ? policy : nil
        })
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let connection = try NotesHostConnection(fd: 3, registration: registration, engine: engine)
        // At most the sealed number of private requests; native review for
        // every create. No persistent listener/auto-renew/reconnect/replay.
        for _ in 0..<Int(budget) {
            let remaining = Double(expiry - Int64(Date().timeIntervalSince1970 * 1000)) / 1000
            guard remaining > 0 else { throw ReviewFault("approval_expired") }
            try connection.serveOne(deadline: ProcessInfo.processInfo.systemUptime + min(60, remaining))
        }
    }
}
