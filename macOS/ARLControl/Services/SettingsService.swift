import Foundation
import Darwin
import CryptoKit

actor SettingsService {
    let home: URL
    let demo: Bool
    let nativeActionsHeld: Bool
    private var remindersRestore: (id:UUID,task:Task<RemindersFirstReply,Error>)?
    private var lastModulesRead: TimeInterval?
    private var cachedModules: MetadataFeature<ModulesSnapshot> = .unsupported
    private var lastCalendarRead: TimeInterval?
    private var cachedCalendarPermission: MetadataFeature<MioCalendarPermissionStatus> = .unsupported
    init(home: URL, demo: Bool = false, nativeActionsHeld: Bool = false) { self.home = home; self.demo = demo; self.nativeActionsHeld = nativeActionsHeld }
    static var defaultHome: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/ARL") }
    func read() async throws -> RuntimeSnapshot {
        if demo { return try RuntimeSnapshot.decode(Data(Self.fixture.utf8)) }
        if FileManager.default.fileExists(atPath: home.appendingPathComponent("disabled").path) { throw ARLError(code: "user_disabled") }
        var info = stat()
        guard lstat(home.path, &info) == 0 else { throw ARLError(code: "disconnected") }
        guard (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == geteuid(), (info.st_mode & 0o077) == 0 else { throw ARLError(code: "unsafe_home") }
        let client = ARLClient(home: home, app: "settings") // No launcher or tool execution.
        let reply = try await client.settingsMetadata(.overview)
        let snapshot = try RuntimeSnapshot.decode(JSONEncoder().encode(reply))
        guard snapshot.protocol == "arl/1", snapshot.schema_version == 1 else { throw ARLError(code: "unsupported_protocol") }
        return snapshot
    }
    func readRuntimeDescription() async -> MetadataFeature<ARLJSON> {
        guard !demo else { return .unsupported }
        do { return .available(try await ARLClient(home: home, app: "settings").describeRuntime()) }
        catch let error as ARLError where error.code == "unknown_method" { return .unsupported }
        catch { return .unavailable((error as? ARLError)?.code ?? "invalid_response") }
    }
    func readControlPlane() async throws -> ControlPlaneState {
        if demo { return try ControlPlaneSnapshot.decode(Data(ControlFixtures.snapshot.utf8)).presentation }
        let client = ARLClient(home: home, app: "settings")
        do {
            let started = ProcessInfo.processInfo.systemUptime
            let reply = try await client.settingsMetadata(.snapshot, timeout: 3)
            return try ControlPlaneSnapshot.decode(JSONEncoder().encode(reply)).presented(atUptime: started, iconHome: home)
        } catch let error as ARLError where error.code == "unknown_method" {
            return ControlPlaneState() // Legacy overview remains useful; no inferred evidence.
        }
    }
    func readApplicationIcon(_ icon: RegisteredApplicationIcon) async throws -> Data {
        guard !demo else { throw ARLError(code:"application_icon_unavailable") }
        let reply = try await ARLClient(home:home, app:"settings").rpc("settings.app_icon.v1",
            params:["app_id":.string(icon.app_id), "sha256":.string(icon.sha256)], timeout:3)
        let raw = try JSONEncoder().encode(reply)
        let row = try WireSchema.object(JSONSerialization.jsonObject(with:raw),
            ["app_id","sha256","mime_type","width","height","bytes","png_base64"])
        let metadata = row.filter { $0.key != "png_base64" }
        try RegisteredApplicationIcon.validate(metadata, appID:icon.app_id)
        let received = try JSONDecoder().decode(RegisteredApplicationIcon.self, from:JSONSerialization.data(withJSONObject:metadata))
        guard received == icon, let encoded = row["png_base64"] as? String, encoded.utf8.count <= 10924,
              let bytes = Data(base64Encoded:encoded), bytes.count == icon.bytes,
              bytes.base64EncodedString() == encoded,
              bytes.prefix(8) == Data([137,80,78,71,13,10,26,10]),
              SHA256.hash(data:bytes).map({ String(format:"%02x",$0) }).joined() == icon.sha256
        else { throw ARLError(code:"invalid_response") }
        return bytes
    }
    func readModules() async -> MetadataFeature<ModulesSnapshot> {
        if demo { return .unsupported }
        let now = ProcessInfo.processInfo.systemUptime
        if let lastModulesRead, now - lastModulesRead < 5 { return cachedModules }
        lastModulesRead = now
        do {
            let reply = try await ARLClient(home: home, app: "settings").rpc("settings.modules_snapshot", params: [:], timeout: 3)
            cachedModules = .available(try ModulesSnapshot.decode(JSONEncoder().encode(reply)))
        } catch let error as ARLError where error.code == "unknown_method" {
            cachedModules = .unsupported
        } catch {
            cachedModules = .unavailable((error as? ARLError)?.code ?? "invalid_response")
        }
        return cachedModules
    }
    func readMioCalendarPermission() async -> MetadataFeature<MioCalendarPermissionStatus> {
        guard !nativeActionsHeld, !demo else { return .unsupported }
        let now = ProcessInfo.processInfo.systemUptime
        if let lastCalendarRead, now - lastCalendarRead < 5 { return cachedCalendarPermission }
        lastCalendarRead = now
        do { cachedCalendarPermission = .available(try await MioCalendarStatusClient(home: home).read()) }
        catch MioCalendarStatusFault.notDeployed { cachedCalendarPermission = .unsupported }
        catch MioCalendarStatusFault.identityUnverified { cachedCalendarPermission = .unavailable("identity_unverified") }
        catch MioCalendarStatusFault.invalidResponse { cachedCalendarPermission = .unavailable("invalid_response") }
        catch { cachedCalendarPermission = .unavailable("probe_unavailable") }
        return cachedCalendarPermission
    }
    func readPermissions() async -> MetadataFeature<ApplePermissionSnapshot> {
        guard !nativeActionsHeld else { return .available(.untested) }
        if demo { return .unsupported }
        let native=RemindersNativeClient(home:home)
        // The installed main/native controllers own their status. Do not ask
        // the metadata-only Python host for the retired permission RPC.
        if native.configured {
            let evidence=(try? await native.call(RemindersFirstFrame(action:.snapshot,requestID:UUID())))?.snapshot
            return .available(ApplePermissionSnapshot.untested.overlayReminders(evidence))
        }
        return .available(.untested)
    }
    func remindersConfigured()->Bool { !nativeActionsHeld && !demo && RemindersNativeClient(home:home).configured }
    func remindersServiceState()->RemindersServiceState { nativeActionsHeld ? .sourceHeld:demo ? .preview:RemindersNativeClient(home:home).configurationState() }
    func readRemindersFirst() async -> MetadataFeature<RemindersFirstSnapshot> {
        guard !nativeActionsHeld else { return .unsupported }
        guard !demo,RemindersNativeClient(home:home).configured else{return .unsupported}
        do {guard let value=try await RemindersNativeClient(home:home).call(RemindersFirstFrame(action:.snapshot,requestID:UUID())).snapshot else{throw RemindersTransportFault("invalid_response")};return .available(value)}
        catch{return .unavailable((error as? RemindersTransportFault)?.code ?? "disconnected")}
    }
    func performRemindersFirst(_ action:RemindersFirstAction,requestID:UUID,launch:Bool=false) async throws->RemindersFirstReply {
        guard !nativeActionsHeld else{throw ARLError(code:"source_authorization_held")}
        guard !demo else{throw ARLError(code:"demo_mode")}
        return try await RemindersNativeClient(home:home).call(RemindersFirstFrame(action:action,requestID:requestID),launch:launch)
    }
    /// Restore only an already configured, enabled, signature-verified native
    /// service. Snapshot cannot request TCC, change activation or save content.
    func restoreRemindersConnection() async throws -> RemindersFirstReply {
        guard !nativeActionsHeld,!demo else { throw ARLError(code:"source_authorization_held") }
        if let pending=remindersRestore {
            return try await withTaskCancellationHandler(operation:{ try await pending.task.value },onCancel:{ pending.task.cancel() })
        }
        let native=RemindersNativeClient(home:home),id=UUID()
        guard native.configured else { throw RemindersTransportFault("configuration_required") }
        let work=Task { try await native.call(RemindersFirstFrame(action:.snapshot,requestID:UUID()),launch:true) }
        remindersRestore=(id,work)
        defer { if remindersRestore?.id==id { remindersRestore=nil } }
        return try await withTaskCancellationHandler(operation:{ try await work.value },onCancel:{ work.cancel() })
    }
    func performRemindersTask(_ frame: RemindersFirstFrame) async throws -> RemindersFirstReply {
        guard !nativeActionsHeld else{throw ARLError(code:"source_authorization_held")}
        guard !demo,RemindersTaskContract.actions.contains(frame.action) else{throw ARLError(code:"invalid_arguments")}
        return try await RemindersNativeClient(home:home).call(frame)
    }
    func performRemindersProduct(_ frame:RemindersProductFrame)async throws->RemindersProductReply {
        guard !nativeActionsHeld,!demo else{throw ARLError(code:"source_authorization_held")}
        return try await RemindersNativeClient(home:home).callProduct(frame)
    }
    func performPermission(_ capability: String, action: String, requestID: UUID) async throws -> (ApplePermissionSnapshot,String) {
        guard !nativeActionsHeld,!demo else{throw ARLError(code:"source_authorization_held")}
        guard ApplePermissionSnapshot.ids.contains(capability), action == "retest" else{throw ARLError(code:"dedicated_setup_required")}
        return ((await readPermissions()).value ?? .untested,"refreshed")
    }
    func readLogs(cursor: String? = nil, level: String? = nil, event: String? = nil) async throws -> RedactedLogPage {
        if demo { return try ControlLogResponse.decode(Data(ControlFixtures.logs.utf8)).presentation }
        var params: [String: ARLJSON] = ["limit": .number(100)]
        if let cursor { guard cursor.count <= 64 else { throw ARLError(code: "invalid_cursor") }; params["cursor"] = .string(cursor) }
        if let level { guard ["info","warning","error"].contains(level) else { throw ARLError(code:"invalid_arguments") }; params["level"] = .string(level) }
        if let event { guard WireSchema.events.contains(event) else { throw ARLError(code:"invalid_arguments") }; params["event"] = .string(event) }
        let reply = try await ARLClient(home:home,app:"settings").settingsMetadata(.logs,params:params,timeout:3)
        return try ControlLogResponse.decode(JSONEncoder().encode(reply)).presentation
    }
    func exportLogs() async throws -> ControlLogExport {
        if demo { return try .filtered(ControlLogResponse.decode(Data(ControlFixtures.logs.utf8)).records) }
        let reply = try await ARLClient(home:home,app:"settings").settingsMetadata(.logsExport,params:["limit":.number(500)],timeout:3)
        return try ControlLogExport.decode(JSONEncoder().encode(reply))
    }
    static let fixture = """
    {"schema_version":1,"protocol":"arl/1","version":"0.1.1","health":{"live":true,"ready":true,"ui_required":false},"queue":{"available":true,"counts":{"queued":0,"running":0,"succeeded":12,"failed":0,"cancelled":0,"needs_unlock":0,"needs_review":0}},"providers":[{"name":"ollama","availability":"unavailable","models":[],"paid":false,"inference_policy":"disabled","allowed_apps":[]},{"name":"codex_app_server","availability":"disabled","models":[],"paid":true,"inference_policy":"disabled","allowed_apps":[]},{"name":"jev","availability":"disabled","models":[],"paid":true,"inference_policy":"disabled","allowed_apps":[]},{"name":"mock","availability":"ready","models":["deterministic-v1"],"paid":false,"inference_policy":"explicit_route_only","allowed_apps":["sample_app"]}],"capabilities":[{"name":"runtime.ping","availability":"ready","identity_gate":"none","authorization_gate":"not_required"},{"name":"text.sha256","availability":"ready","identity_gate":"none","authorization_gate":"not_required"},{"name":"apple.calendar.list","availability":"needs_permission","identity_gate":"verified_peer_required","authorization_gate":"permission_required"},{"name":"apple.reminders.list","availability":"needs_permission","identity_gate":"verified_peer_required","authorization_gate":"permission_required"},{"name":"mio_maps_geo","availability":"unavailable","identity_gate":"verified_peer_required","authorization_gate":"authorization_not_checked"}],"policy":{"local_inference_enabled":false,"paid_inference_enabled":false,"automatic_fallback":false,"model_downloads":false,"identity_verifier_configured":false},"budgets":[{"app":"sample_app","max_pending":64,"max_calls":1000,"max_output_tokens":256,"max_prompt_utf8_bytes":1024},{"app":"sample_remote","max_pending":64,"max_calls":1000,"max_output_tokens":256,"max_prompt_utf8_bytes":1024},{"app":"mio","max_pending":64,"max_calls":1000,"max_output_tokens":256,"max_prompt_utf8_bytes":1024},{"app":"settings","max_pending":0,"max_calls":0,"max_output_tokens":0,"max_prompt_utf8_bytes":1024}]}
    """
}
