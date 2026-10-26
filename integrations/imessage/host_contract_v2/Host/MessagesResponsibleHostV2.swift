import Foundation
import AppKit
import Darwin

final class MessagesStopFlagV2: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func stop() { lock.lock(); value = true; lock.unlock() }
    var stopped: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

@MainActor final class MessagesResponsibleHostV2 {
    let policy:MessagesHostPolicyV2
    let policyHash:String
    let identity:NativePermissionIdentity
    let launchHash:String
    private var backend:MessagesBackendPipe!
    private var admissions:[String:(MessagesControlFrame,MessagesNativeIO.Peer)] = [:]
    private var selection:MessagesJSON?
    private var reviewed:MessagesJSON?
    private var scope:MessagesNativeScopeV2?
    private var metadataExpiry:Double = 0
    private var accessEvidence = "untested"
    private var accessAt:Double = 0
    private var permissionStop:MessagesStopFlagV2?
    private var lastReply:MessagesJSON?
    private var stopping = false
    private let run: MessagesRunJournalV2
    private var backendReady = false
    private let cleanupQueue = MessagesCleanupQueueV2()
    private var ceiling: Double { run.record.deadline }
    var remainingLifetime: Double { max(0, ceiling - Date().timeIntervalSince1970) }

    init(policy:MessagesHostPolicyV2,hash:String) throws {
        self.policy = policy; policyHash = hash
        identity = try NativePermissionIdentity.current(expectedBundle:"local.arl.messagesbridge")
        launchHash = MessagesNativeIO.hash(Data((hash+identity.executable_sha256+policy.runtime_closure_sha256+policy.imsg_sha256).utf8))
        try MessagesNativeIO.privateDirectory(policy.state_root)
        run = try MessagesRunJournalV2(root: policy.state_root, runID: policy.run_id, policyHash: hash, notAfter: policy.run_not_after)
        scope = run.record.scope
    }
    func start() async throws {
        try policy.verifyLaunch()
        let resources = Bundle.main.resourceURL!
        let cache = resources.appendingPathComponent("no-bytecode-cache").path
        guard access(cache,F_OK) != 0 else { throw MessagesTransportFault("identity_changed") }
        backend = try MessagesBackendPipe(python:policy.python_path,bootstrap:resources.appendingPathComponent("backend_bootstrap.py").path,cache:cache) { [weak self] operation,args in
            guard let self else { throw MessagesTransportFault("host_unavailable") }
            return try await self.native(operation,args)
        }
        let ready = try await backend.initialize(MessagesJSON([
            "identity":wireIdentity,"owner":owner,"mode":policy.mode,"state_root":policy.state_root,
            "scope_seed":policyHash,"database_path":policy.database_path,"imsg_path":policy.imsgPath,
            "imsg_sha256":policy.imsg_sha256,"attachment_roots":[]]))
        guard ready.value["ready"] as? Bool == true,
              let echoed = ready.value["identity"] as? [String: Any], NSDictionary(dictionary: echoed).isEqual(to: wireIdentity) else { throw MessagesTransportFault("host_unavailable") }
        // Pure owned status caches setup-session identity before serving requests; no OS/SQL/effect.
        lastReply = try await backendSnapshot()
        backendReady = true
    }
    private var owner:String { "messages:"+policy.run_id }
    private var wireIdentity:[String:Any] { ["helper_bundle_id":identity.helper_bundle_id,
        "executable_sha256":identity.executable_sha256,"designated_requirement_sha256":identity.designated_requirement_sha256,"launch_closure_sha256":launchHash] }
    private func ownCurrent() throws {
        guard try NativePermissionIdentity.current(expectedBundle:"local.arl.messagesbridge") == identity else { throw MessagesTransportFault("identity_changed") }
    }
    private func admitted(_ id:String,command:String? = nil) throws -> (MessagesControlFrame,MessagesNativeIO.Peer) {
        guard let value = admissions[id], value.1.signatureCurrent(), command == nil || value.0.command == command else { throw MessagesTransportFault("identity_unverified") }
        return value
    }
    private func checkCeiling() throws {
        try ownCurrent()
        try run.requireActive(); scope = run.record.scope
        guard policy.enabled == 1, !stopping, Date().timeIntervalSince1970 < ceiling else { throw MessagesTransportFault("activation_not_approved") }
    }
    private func persistScope() throws {
        if let scope { try run.setScope(scope) }
    }
    private func prerequisites() throws -> MessagesJSON {
        try ownCurrent()
        let now = Date().timeIntervalSince1970
        #if MESSAGES_HOST_FIXTURE
        let automation = "authorized_automation"
        let attribution = true
        let narrow = "verified"
        #else
        let attribution = policy.launch_attribution_verified == 1
        let automation = attribution ? try permissionPreflight(.messagesSend).state : "unknown"
        let narrow = now-accessAt <= 30 ? accessEvidence : "untested"
        #endif
        return MessagesJSON(["identity":wireIdentity,"observed_at":now,"implementation":"installed",
            "attribution_verified":attribution,"receive_access":narrow,"automation":automation,
            "readback_access":narrow,"executable_pinned":true,"request_route":attribution ? "available":"blocked_identity","settings_route":"available"])
    }

    func handle(_ bytes:Data,peer:MessagesNativeIO.Peer) async -> Data {
        var frame:MessagesControlFrame?
        var retainedAdmission = false
        do {
            let request = try MessagesControlWireV2.decode(bytes); frame = request
            try ownCurrent()
            guard peer.current(), admissions.count < 16 else { throw MessagesTransportFault("identity_unverified") }
            // Never overwrite a still-running admission for the same UUID.
            guard admissions[request.requestID] == nil else { throw MessagesTransportFault("busy") }
            admissions[request.requestID] = (request,peer)
            defer { if !retainedAdmission { admissions.removeValue(forKey:request.requestID) } }
            if ["begin", "reconnect"].contains(request.command), ["completed", "not_required"].contains(run.record.cleanup_state) { stopping = false }
            if !["snapshot","cancel","disable"].contains(request.command) { try checkCeiling() }
            if request.command == "cancel" || request.command == "disable" {
                if try run.cleanupReplay(requestID: request.requestID, command: request.command) != nil {
                    // Replay only reads current status. It cannot stop/rebind a newer session.
                    return try response(await backendSnapshot(), request)
                }
                stopping = true; permissionStop?.stop()
                let binding = cleanupBinding()
                let admission = try run.beginCleanup(requestID: request.requestID, command: request.command,
                                                     session: binding.0, generation: binding.1)
                scope = run.record.scope
                let task = cleanupQueue.enqueue { [self] in try await cancelAndStop(request, operation: admission.operation) }
                if permissionStop != nil, let lastReply {
                    // Native cancellation remains occupied until the OS call returns.
                    retainedAdmission = true
                    Task { [self] in
                        _ = try? await task.value
                        admissions.removeValue(forKey:request.requestID)
                    }
                    var value = lastReply.value
                    if var snapshot = value["snapshot"] as? [String:Any] {
                        snapshot["enabled"] = false; snapshot["phase"] = "canceling"; snapshot["cleanup"] = "unknown"; snapshot["last_error"] = "cancelled"; value["snapshot"] = snapshot
                    }
                    if var view = value["presentation"] as? [String:Any] { view["phase"] = "canceling"; view["cleanup"] = "unknown"; view["last_error"] = "cancelled"; value["presentation"] = view }
                    return try response(MessagesJSON(value),request)
                }
                let reply = try await task.value
                guard peer.signatureCurrent() else { throw MessagesTransportFault("identity_unverified") }
                lastReply = reply
                return try response(reply, request)
            }
            if request.command == "snapshot", permissionStop != nil, stopping, let lastReply {
                var value = lastReply.value
                if var snapshot = value["snapshot"] as? [String:Any] { snapshot["enabled"] = false; snapshot["phase"] = "canceling"; snapshot["cleanup"] = "unknown"; value["snapshot"] = snapshot }
                if var view = value["presentation"] as? [String:Any] { view["phase"] = "canceling"; view["cleanup"] = "unknown"; value["presentation"] = view }
                return try response(MessagesJSON(value),request)
            }
            if request.command == "select_group" {
                let details = try await backend.request("candidate_review",MessagesJSON(["candidate_id":request.arguments["candidate_id"]!]))
                guard await confirmGroup(details) else { throw MessagesTransportFault("cancelled") }
                selection = details; reviewed = nil
            }
            if request.command == "start_test" {
                guard run.record.scope?.consumed != true else { throw MessagesTransportFault("attempt_consumed") }
                let review = try await backend.request("review_plan",MessagesJSON([:]))
                guard let plan = review.value["plan"] as? [String:Any], plan["plan_id"] as? String == request.arguments["plan_id"],
                      let selectedPin = selection?.value["candidate_pin"] as? String,
                      MessagesV2Fields.matches(selectedPin, "^[a-f0-9]{64}$"),
                      plan["candidate_pin"] as? String == selectedPin,
                      await confirmPlan(review) else { throw MessagesTransportFault("activation_not_approved") }
                reviewed = review
            }
            let reply = try await backend.request("control",request.json,seconds:request.command == "permission_action" ? 195:15)
            guard peer.signatureCurrent() else { throw MessagesTransportFault("identity_unverified") }
            lastReply = reply
            return try response(reply,request)
        } catch {
            let code = (error as? MessagesTransportFault)?.code ?? "host_unavailable"
            var value:[String:Any] = ["schema_version":2,"ok":false,"error":["code":code]]
            if let frame { value["request_id"] = frame.requestID; value["command"] = frame.command }
            return (try? MessagesJSON(value).data) ?? Data()
        }
    }
    private func response(_ reply:MessagesJSON,_ request:MessagesControlFrame) throws -> Data {
        var value = reply.value
        // Core snapshots never complete native cleanup. Only correlated scoped stop replies do.
        value["schema_version"] = 2
        value["authority"] = try run.evidence(backendReady: backendReady).wireValue
        value["request_id"] = request.requestID; value["command"] = request.command
        return try MessagesJSON(value).data
    }

    private func backendSnapshot() async throws -> MessagesJSON {
        guard let backend else { throw MessagesTransportFault("host_unavailable") }
        return try await backend.request("control", MessagesJSON(["schema_version": 1, "request_id": UUID().uuidString.lowercased(), "command": "snapshot", "arguments": [:]]))
    }
    private func cleanupBinding() -> (String?, Int) {
        if let scope, !scope.revoked { return (scope.session_id, scope.generation) }
        // Never await before cleanup admission. A stale/missing cached binding fails closed; it
        // cannot be replaced by the session in a later completed snapshot or stop response.
        guard let core = lastReply?.value["snapshot"] as? [String: Any], let session = core["session_id"] as? String,
              MessagesV2Fields.canonicalUUID(session), let generation = MessagesNativeIO.integer(core["generation"]), generation > 0 else { return (nil, 0) }
        return (session, generation)
    }
    private func cancelAndStop(_ request: MessagesControlFrame, operation: MessagesCleanupOperationV2) async throws -> MessagesJSON {
        do {
            guard run.isCurrent(operation) else { return try await backendSnapshot() }
            _ = try await backend.request("control", request.json, seconds: 195)
            // A permission call remains occupied even after its cancel reply. Status cannot release it.
            let until = Date().timeIntervalSince1970 + 195
            while permissionStop != nil, run.isCurrent(operation), Date().timeIntervalSince1970 < until {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            guard run.isCurrent(operation), permissionStop == nil else {
                try run.failCleanup(operation); return try await backendSnapshot()
            }
            let stopped = try await backend.request("lifecycle_stop", MessagesJSON([:]), seconds: 25)
            // Pipe request-ID correlation associates this actual stop proof with the captured token.
            // The source's presentation cleanup string is deliberately not read here.
            if stopped.value["complete"] as? Bool == true, let proof = stopped.value["proof"] as? [String: Any] {
                if try !run.completeCleanup(operation, proof: proof, permissionPending: permissionStop != nil) { try run.failCleanup(operation) }
            } else { try run.failCleanup(operation) }
            scope = run.record.scope
            return try await backendSnapshot()
        } catch {
            try? run.failCleanup(operation)
            throw error
        }
    }

    private func native(_ operation:String,_ args:MessagesJSON) async throws -> MessagesJSON {
        try ownCurrent()
        let value = args.value
        switch operation {
        case "verify_ui":
            guard let id = value["request_id"] as? String, let action = value["action"] as? String,
                  value["owner"] as? String == owner else { throw MessagesTransportFault("identity_unverified") }
            let request = try admitted(id)
            guard action == request.0.command || action == "permission_action" && request.0.command == "permission_action" else { throw MessagesTransportFault("identity_unverified") }
            return MessagesJSON([:])
        case "observe": return try prerequisites()
        case "open_messages":
            _ = try admitted(value["request_id"] as? String ?? "",command:"open_messages")
            #if MESSAGES_HOST_FIXTURE
            return MessagesJSON(["outcome":"opened"])
            #else
            let config = NSWorkspace.OpenConfiguration(); config.activates = true
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier:"com.apple.MobileSMS") else { throw MessagesTransportFault("unsupported") }
            _ = try await NSWorkspace.shared.openApplication(at:url,configuration:config)
            return MessagesJSON(["outcome":"opened"])
            #endif
        case "permission_action":
            return try await permissions(value)
        case "access_evidence":
            _ = try admitted(value["request_id"] as? String ?? "",command:"permission_action")
            guard let access = value["access"] as? String, ["verified","blocked"].contains(access) else { throw MessagesTransportFault("invalid_evidence") }
            accessEvidence = access; accessAt = Date().timeIntervalSince1970
            return MessagesJSON([:])
        case "metadata_admit":
            _ = try admitted(value["request_id"] as? String ?? "",command:"discover_groups")
            try checkCeiling()
            guard policy.metadata_admitted == 1, MessagesNativeIO.integer(value["limit"]) == 20 else { throw MessagesTransportFault("metadata_scope_not_approved") }
            metadataExpiry = min(ceiling,Date().timeIntervalSince1970+900)
            return MessagesJSON([:])
        case "metadata_check":
            try checkCeiling()
            guard Date().timeIntervalSince1970 < metadataExpiry else { throw MessagesTransportFault("metadata_scope_not_approved") }
            return MessagesJSON([:])
        case "activate_trial":
            try checkCeiling()
            guard let expected = reviewed?.value, let plan = value["plan"] as? [String:Any],
                  let original = expected["plan"] as? [String:Any], NSDictionary(dictionary:plan).isEqual(to:original),
                  value["plan_hash"] as? String == expected["plan_hash"] as? String,
                  value["candidate_pin"] as? String == selection?.value["candidate_pin"] as? String,
                  scope?.consumed != true, let expires = plan["expires_at"] as? Double,
                  let generation = MessagesNativeIO.integer(plan["generation"]), expires > Date().timeIntervalSince1970,
                  let session = plan["session_id"] as? String, let operationID = plan["operation_id"] as? String,
                  let text = plan["send_text"] as? String else { throw MessagesTransportFault("activation_not_approved") }
            let leaseID = "lease_"+MessagesNativeIO.hash(Data(UUID().uuidString.utf8))
            scope = MessagesNativeScopeV2(lease_id:leaseID,session_id:session,generation:generation,candidate_pin:plan["candidate_pin"] as! String,
                owner:owner,group_id:value["group_id"] as! String,scope_id:value["scope_id"] as! String,plan_hash:expected["plan_hash"] as! String,
                operation_id:operationID,send_text_sha256:MessagesNativeIO.hash(Data(text.utf8)),expires_at:min(ceiling,expires),revoked:false,consumed:false,send_outcome:"not_started")
            try persistScope()
            return MessagesJSON(["lease_id":leaseID,"session_id":session,"generation":generation,"candidate_pin":scope!.candidate_pin,
                "owner":owner,"plan_hash":scope!.plan_hash,"expires_at":scope!.expires_at,"sends_remaining":1])
        case "scope_check":
            try checkCeiling()
            guard let scope, !scope.revoked, scope.expires_at > Date().timeIntervalSince1970,
                  value["lease_id"] as? String == scope.lease_id, value["candidate_pin"] as? String == scope.candidate_pin,
                  value["session_id"] as? String == scope.session_id, MessagesNativeIO.integer(value["generation"]) == scope.generation,
                  value["group_id"] as? String == scope.group_id, value["owner"] as? String == scope.owner,
                  ["receive","send"].contains(value["action"] as? String ?? "") else { throw MessagesTransportFault("activation_not_approved") }
            return MessagesJSON([:])
        case "consume_send":
            try checkCeiling()
            guard let scope, !scope.revoked, !scope.consumed, scope.expires_at > Date().timeIntervalSince1970,
                  value["lease_id"] as? String == scope.lease_id, value["operation_id"] as? String == scope.operation_id,
                  value["text_sha256"] as? String == scope.send_text_sha256 else { throw MessagesTransportFault("attempt_consumed") }
            try run.consume(operationID: scope.operation_id, textHash: scope.send_text_sha256); self.scope = run.record.scope
            return MessagesJSON([:])
        case "send_outcome":
            guard value["operation_id"] as? String == scope?.operation_id,
                  ["accepted","outcome_unknown"].contains(value["state"] as? String ?? "") else { throw MessagesTransportFault("send_unknown") }
            try run.outcome(operationID: value["operation_id"] as! String, state: value["state"] as! String); scope = run.record.scope; return MessagesJSON([:])
        case "stop_trial":
            if let scope, !scope.revoked {
                guard value["session_id"] as? String == scope.session_id, MessagesNativeIO.integer(value["generation"]) == scope.generation else { throw MessagesTransportFault("cleanup_unknown") }
            }
            try run.revoke(session: value["session_id"] as? String, generation: MessagesNativeIO.integer(value["generation"]) ?? 0); self.scope = run.record.scope
            return MessagesJSON(["grant_revoked":true,"source_stopped":true,"publisher_stopped":true])
        case "verify_mio","verify_event_observation": throw MessagesTransportFault("event_unproven")
        default: throw MessagesTransportFault("invalid_request")
        }
    }

    private func permissions(_ value:[String:Any]) async throws -> MessagesJSON {
        let id = value["request_id"] as? String ?? ""
        let request = try admitted(id,command:"permission_action")
        let capability = value["capability_id"] as? String ?? "", action = value["action"] as? String ?? ""
        guard ["messages.receive.v1","messages.send.v1"].contains(capability), ["request","open_settings","retest"].contains(action) else { throw MessagesTransportFault("invalid_request") }
        try checkCeiling()
        if action == "retest" {
            guard policy.metadata_admitted == 1 else { throw MessagesTransportFault("metadata_scope_not_approved") }
            return MessagesJSON(["outcome":"access_probe"])
        }
        #if MESSAGES_HOST_FIXTURE
        return MessagesJSON(["outcome":action == "open_settings" ? "opened_settings":"completed"])
        #else
        if action == "open_settings" || capability == "messages.receive.v1" {
            let fixed = capability == "messages.receive.v1" ? "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles":"x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
            return MessagesJSON(["outcome":NSWorkspace.shared.open(URL(string:fixed)!) ? "opened_settings":"settings_unavailable"])
        }
        guard policy.launch_attribution_verified == 1, permissionStop == nil else { throw MessagesTransportFault("identity_unverified") }
        let stop = MessagesStopFlagV2(); permissionStop = stop; defer { permissionStop = nil }
        let admission = try VerifiedPermissionAdmission(auditToken:request.1.token,pinnedControlRequirement:policy.control_requirement,
            requestID:UUID(uuidString:id)!,kind:.messagesSend,approvedHelperIdentity:identity)
        _ = try await requestNativePermission(admission,cancelled:{stop.stopped})
        return MessagesJSON(["outcome":stop.stopped ? "user_cancelled":"completed"])
        #endif
    }
    private func confirmGroup(_ details:MessagesJSON) async -> Bool {
        #if MESSAGES_HOST_FIXTURE
        return true
        #else
        guard let name = details.value["name"] as? String, let participants = details.value["participants"] as? [String] else { return false }
        return await confirm(title:"Allow this Messages group?",body:name+"\n\n"+participants.joined(separator:"\n")+"\n\nOnly this exact group and these participants will be admitted.")
        #endif
    }
    private func confirmPlan(_ review:MessagesJSON) async -> Bool {
        #if MESSAGES_HOST_FIXTURE
        return true
        #else
        guard let plan = review.value["plan"] as? [String:Any], let receive = plan["receive_text"] as? String,
              let send = plan["send_text"] as? String, let confirmation = plan["confirmation_text"] as? String,
              let selected = selection?.value, let pin = selected["candidate_pin"] as? String,
              MessagesV2Fields.matches(pin, "^[a-f0-9]{64}$"), plan["candidate_pin"] as? String == pin,
              let name = selected["name"] as? String, !name.isEmpty, name.count <= 120, !name.contains("\0"),
              let participants = selected["participants"] as? [String], (2...16).contains(participants.count),
              Set(participants).count == participants.count,
              participants.allSatisfy({ !$0.isEmpty && $0.count <= 256 && !$0.contains("\0") }) else { return false }
        return await confirm(title:"Run one bounded Messages test?",body:"One lifetime text attempt and two acceptance challenges. The adapter reads all bounded new selected-group rows before filtering; other new text and attachment metadata can be retained privately. Ordinary imsg independently matches recent outgoing text from sentAt minus two seconds for up to eight seconds, and can inspect routing metadata and a narrow empty-row diagnostic. This is not a two-row cap or a whole-chain zero-history promise. No attachment bytes, media, arbitrary backfill, other-group bodies or Mio disclosure. Private scoped content is cleaned; minimal tombstones remain. No automatic resend.\n\nRecipients (this exact group):\n"+name+"\n"+participants.joined(separator:"\n")+"\n\nFirst incoming:\n"+receive+"\n\nARL sends:\n"+send+"\n\nParticipant confirms afterwards:\n"+confirmation+"\n\nLocked-awake operation needs separate observed acceptance. This confirmation does not verify lock, sleep, logout or FileVault-first-unlock readiness. This does not disclose text to Mio.")
        #endif
    }
    private func confirm(title:String,body:String) async -> Bool {
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:560,height:200),styleMask:[.titled],backing:.buffered,defer:false)
        window.title = "ARL Messages Bridge"; window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = body
        alert.addButton(withTitle:"Confirm this exact scope"); alert.addButton(withTitle:"Cancel")
        let accepted = await withCheckedContinuation { continuation in alert.beginSheetModal(for:window) { result in continuation.resume(returning:result == .alertFirstButtonReturn) } }
        window.orderOut(nil); return accepted
    }
    func lifecycleStop() async {
        stopping = true; permissionStop?.stop()
        var complete = false
        do {
            let binding = cleanupBinding()
            let op = try run.beginSystemCleanup(session: binding.0, generation: binding.1); scope = run.record.scope
            let task = cleanupQueue.enqueue { [self] in
                guard let backend else { try run.failCleanup(op); throw MessagesTransportFault("host_unavailable") }
                let reply = try? await backend.request("lifecycle_stop", MessagesJSON([:]), seconds: 25)
                let reaped = await backend.terminate()
                if reaped, reply?.value["complete"] as? Bool == true, let proof = reply?.value["proof"] as? [String: Any] {
                    _ = try run.completeCleanup(op, proof: proof, permissionPending: permissionStop != nil)
                }
                if run.record.cleanup_state != "completed" { try run.failCleanup(op) }
                return MessagesJSON(["complete": run.isCurrent(op) && run.record.cleanup_state == "completed"])
            }
            complete = try await task.value.value["complete"] as? Bool == true
        } catch {
            if let backend { _ = await backend.terminate() }
        }
        backendReady = false
        try? run.shutdown()
        if !complete { try? FileHandle.standardError.write(contentsOf: Data("{\"schema_version\":2,\"cleanup\":\"unknown\",\"code\":\"host_unavailable\"}\n".utf8)) }
    }
}
