import Foundation
import Darwin

enum NotesV2Bootstrap {
    static func run(permissionSetup: Bool = false) throws {
        let kind = permissionSetup ? "permission_setup" : "notes_first_use"
        let resource = permissionSetup ? "NotesPermissionProfile" : "NotesV2Profile"
        let expectedHash = permissionSetup ? NotesV2BuildSeal.permissionProfileHash : NotesV2BuildSeal.profileHash
        guard let profileURL = Bundle.main.url(forResource: resource, withExtension: "json") else { throw NativeFault("profile_invalid") }
        let raw = try Data(contentsOf: profileURL), now = Int64(Date().timeIntervalSince1970 * 1000)
        let p = try NotesV2Profile.parse(raw, expectedSHA256: expectedHash, now: now, expectedKind: kind)
        guard Bundle.main.bundleIdentifier == NotesV2CodePin.signingIdentifier else { throw NativeFault("helper_modified") }
        let parent = getppid(); guard parent > 1 else { throw NativeFault("caller_unverified") }
        let deadline = ProcessInfo.processInfo.systemUptime + Double(p.expiresAtMS - now) / 1000
        let currentEpoch: () -> UInt64? = {
            guard getppid() == parent, ProcessInfo.processInfo.systemUptime < deadline,
                  Int64(Date().timeIntervalSince1970 * 1000) < p.expiresAtMS,
                  let current = try? Data(contentsOf: profileURL), digest(current) == p.rawSHA256 else { return nil }
            guard getppid() == parent, ProcessInfo.processInfo.systemUptime < deadline,
                  Int64(Date().timeIntervalSince1970 * 1000) < p.expiresAtMS else { return nil }; return p.epoch
        }
        let peer = try AuthenticatedCaller.fromRegisteredSocket(3, subject: p.callerSubject, expectedPID: parent,
            requirement: p.callerRequirement, registrationEpoch: p.epoch, currentRegistrationEpoch: currentEpoch)
        let channel = try NotesV2Channel(fd: 3, admitted: {
            guard peer.isCurrent(), currentEpoch() == p.epoch else { throw NativeFault("caller_unverified") }
        })
        let first = try channel.receive(deadline: min(deadline, ProcessInfo.processInfo.systemUptime + 10))
        let registration = try flatObject(first, limit: 1024)
        guard Set(registration.keys) == Set(["schema_version", "method", "executable_sha256", "designated_requirement_sha256"]),
              integer(registration["schema_version"]) == 2, registration["method"] as? String == "register_identity",
              let exec = registration["executable_sha256"] as? String, let dr = registration["designated_requirement_sha256"] as? String else { throw NativeFault("invalid_registration") }
        let codePin = NotesV2CodePin(executableSHA256: exec, designatedRequirementSHA256: dr)
        try codePin.verifyResponsibleSelf()
        let journalPath: String
        #if NOTES_SYNTHETIC
        journalPath = p.syntheticJournal
        #else
        guard let account = getpwuid(getuid()), let home = account.pointee.pw_dir else { throw NativeFault("journal_unavailable") }
        journalPath = URL(fileURLWithPath: String(cString: home)).appendingPathComponent(permissionSetup
            ? "Library/Application Support/ARL/notes-v2/permission-state" : "Library/Application Support/ARL/notes-v2/state").path
        #endif
        let journalGuard = try NotesV2JournalGuard(path: journalPath, device: p.journalDevice, inode: p.journalInode)
        let journal = try ConsumptionJournal(home: journalPath); try journalGuard.verify()
        func admission() throws {
            try NotesV2Admission.check(pin: { try codePin.verifyResponsibleSelf(); try journalGuard.verify() },
                current: { peer.isCurrent() && currentEpoch() == p.epoch }, cancelled: { !channel.connected() })
        }
        let notesSession: NotesV2OwnerSession?
        if let plan = p.plan {
            notesSession = try NotesV2OwnerSession.fromRegisteredSocket(fd: 3, subject: p.callerSubject, expectedPID: parent,
                peerRequirement: p.callerRequirement, epoch: p.epoch, currentEpoch: currentEpoch, plan: plan,
                codePin: codePin, journal: journal, journalCheck: journalGuard.verify, permitID: p.permitID, cancelled: { !channel.connected() })
        } else { notesSession = nil }
        let permissionSession: NotesPermissionRequestSession?
        if let plan = p.permissionPlan {
            #if NOTES_SYNTHETIC
            let surface: NotesPermissionSurface = SyntheticNotesPermissionSurface()
            #else
            let surface: NotesPermissionSurface = NativeNotesPermissionSurface()
            #endif
            permissionSession = try NotesPermissionRequestSession(plan: plan, surface: surface, verifyAdmission: admission,
                consumeRequest: { id in
                    try admission()
                    try journal.consume(operationID: id, permitID: p.permitID, subject: p.callerSubject, epoch: Int64(p.epoch), budget: 1)
                    try admission()
                }, acquireLease: journalGuard.permissionLease)
        } else { permissionSession = nil }
        let selfIdentity = try NotesV2ObservedIdentity.inspect(Bundle.main.executableURL!)
        let ready: [String: Any] = ["host_mode": NotesV2Profile.synthetic ? "synthetic" : "notes", "session_kind": kind,
            "profile_sha256": p.rawSHA256, "source_closure_sha256": NotesV2BuildSeal.sourceHash, "peer_pid": parent, "host_pid": getpid(),
            "identity": selfIdentity.object, "kernel_peer_verified": true, "self_code_pin_verified": true, "notes_events_sent": 0, "permission_queries": 0]
        try channel.send(NotesV2Wire.response(method: "bootstrap", result: ready), deadline: deadline)
        let maximum = permissionSetup ? 3 : 4
        var snapshots = 0
        for index in 0...maximum {
            let frame = try channel.receive(deadline: deadline)
            var fields = try flatObject(frame, limit: NotesV2Wire.requestLimit - 1)
            let response: Data
            if fields["method"] as? String == "finish" {
                guard Set(fields.keys) == Set(["schema_version", "method"]), integer(fields["schema_version"]) == 2 else { throw NativeFault("unsupported_operation") }; return
            }
            guard index < maximum else { throw NativeFault("unsupported_operation") }
            if fields["method"] as? String == "permissions_snapshot" {
                guard Set(fields.keys) == Set(["schema_version", "method"]), integer(fields["schema_version"]) == 2,
                      snapshots < (permissionSetup ? 2 : 1) else { throw NativeFault("unsupported_operation") }
                try admission(); snapshots += 1
                let result = try NotesV2Catalog.snapshot(identity: selfIdentity, manualCapability: p.permissionPlan?.capability, admitted: admission)
                try admission(); response = try NotesV2Wire.response(method: "permissions_snapshot", result: result)
            } else if fields["method"] as? String == "permissions_request" {
                guard integer(fields.removeValue(forKey: "schema_version")) == 2 else { throw NativeFault("invalid_arguments") }
                fields.removeValue(forKey: "method")
                do {
                    guard let session = permissionSession else { throw NotesFirstUseOutcomeFault(code: "permission_setup_required", indeterminate: false) }
                    var result = try session.request(fields)
                    result["identity"] = selfIdentity.object; result["observed_at_ms"] = Int64(Date().timeIntervalSince1970 * 1000)
                    result["surface_scope"] = NotesV2Profile.synthetic ? "synthetic_only" : "native_permission_api"
                    response = try NotesV2Wire.response(method: "permissions_request", result: result)
                } catch let error as NotesFirstUseOutcomeFault {
                    response = try NotesV2Wire.response(method: "permissions_request", error: error)
                }
            } else {
                guard let session = notesSession else { throw NativeFault("notes_execution_not_granted") }
                response = try session.handle(frame)
            }
            try channel.send(response, deadline: deadline)
        }
    }
}
