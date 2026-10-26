import Foundation
import AppKit
import ApplicationServices
import Security
import Darwin

enum AppleDirectStep: String, Sendable, Codable {
    case notesAccountName = "notes.account_name", notesFolderName = "notes.folder_name"
    case messagesCount = "messages.account_count", messagesMetadata = "messages.metadata"
    case messagesIndexedMetadata = "messages.indexed_metadata", messagesStableMetadata = "messages.stable_metadata"
    case messagesAccountID = "messages.account_id", messagesDescription = "messages.account_description"
    case messagesServiceType = "messages.service_type", messagesEnabled = "messages.enabled"
    case messagesConnection = "messages.connection_status", messagesParticipantID = "messages.participant_id"
    case messagesHandle = "messages.handle"
}
enum AppleDirectValueIssue: String, Sendable, Codable { case empty, tooLong = "too_long", controlCharacter = "control_character" }

enum AppleDirectSessionIssue: String, Sendable, Codable {
    case dictionaryUnavailable = "session_dictionary_unavailable"
    case userIdentityUnavailable = "session_user_identity_unavailable"
    case differentUser = "different_user_session"
    case notOnConsole = "session_not_on_console"
    case loginIncomplete = "session_login_incomplete"
    case screenLocked = "screen_locked"
}

/// Recovery metadata describes a blocked precondition; it never opens an app,
/// asks for consent, selects a target, retries a request or expands its scope.
enum ApplePublicPrecondition {
    static func recovery(tool: String, code: String, sessionIssue: AppleDirectSessionIssue? = nil) -> [String: Any]? {
        var detail: [String: Any] = ["requires_user_action": true, "automatic_retry": false]
        if tool.hasPrefix("mio_notes_") {
            detail["target_bundle_id"] = "com.apple.Notes"
            switch code {
            case "user_session_unavailable":
                detail["reason"] = sessionIssue?.rawValue ?? code
                detail["required_action"] = sessionIssue == .screenLocked ? "unlock_existing_user_session" : "restore_existing_console_session"
                detail["next_step"] = sessionIssue == .screenLocked
                    ? "请由用户解锁当前 Mac 会话后重新检查备忘录；本次不会自动重试，也无需为此更改权限。"
                    : "请由用户确认当前 Mac 已登录且处于可用的控制台会话，再重新检查备忘录；本次不会自动重试。"
            case "open_target_application":
                detail["required_action"] = "open_notes"
                detail["next_step"] = "请由用户打开备忘录，再重新检查连接；此响应不会启动应用或请求权限。"
            case "needs_permission":
                detail["permission_owner_bundle_id"] = "local.arl.control"
                detail["required_permission"] = "automation_notes"
                detail["required_action"] = "review_notes_automation_permission"
                detail["next_step"] = "请在 ARL 备忘录连接页主动允许访问；若系统已拒绝，请在系统设置的隐私与安全性 → 自动化中核对 ARL 对备忘录的权限。"
            case "target_required":
                detail["required_action"] = "select_notes_folder"
                detail["next_step"] = "请在 ARL 中选择本次允许访问的备忘录文件夹，再重新检查；不会自动选择或扩大访问范围。"
            default: return nil
            }
        } else if tool.hasPrefix("mio_reminders_") && code == "needs_permission" {
            detail["reason"] = code
            detail["permission_owner_bundle_id"] = "local.arl.remindersbridge"
            detail["permission_owner_display_name"] = "ARL 提醒事项服务"
            detail["required_permission"] = "reminders_full_access"
            detail["required_action"] = "review_reminders_permission"
            detail["next_step"] = "请在 ARL 提醒事项页点击允许访问，由用户处理系统授权；若已拒绝，请在系统设置的隐私与安全性 → 提醒事项中核对 ARL 提醒事项服务。授权后仍须选择允许访问的来源与列表，不要点击保存测试来替代授权检查。"
        } else if tool.hasPrefix("mio_calendar_") && ["needs_permission", "needs_full_access"].contains(code) {
            detail["reason"] = code
            detail["permission_owner_bundle_id"] = "local.arl.control"
            detail["required_permission"] = "calendar_full_access"
            detail["required_action"] = "review_calendar_permission"
            detail["next_step"] = "请在 ARL 日历连接页核对完整访问权限；系统授权由用户操作，本次不会请求权限或重试事件写入。"
        } else { return nil }
        return detail
    }
}

struct AppleDirectFault: Error, Sendable, Codable {
    let code: String
    let nativeStatus: Int32?
    let step: AppleDirectStep?
    let valueIssue: AppleDirectValueIssue?
    let sessionIssue: AppleDirectSessionIssue?
    var businessLogAvailable:Bool? = nil
    init(_ code: String, nativeStatus: Int32? = nil, step: AppleDirectStep? = nil, valueIssue: AppleDirectValueIssue? = nil, sessionIssue: AppleDirectSessionIssue? = nil) {
        self.code = code; self.nativeStatus = nativeStatus; self.step = step; self.valueIssue = valueIssue; self.sessionIssue = sessionIssue
    }
    func at(_ step: AppleDirectStep, issue: AppleDirectValueIssue? = nil) -> Self {
        var copy=Self(code,nativeStatus:nativeStatus,step:self.step ?? step,valueIssue:valueIssue ?? issue,sessionIssue:sessionIssue)
        copy.businessLogAvailable=businessLogAvailable
        return copy
    }
    var diagnostic: String {
        [code, step?.rawValue, valueIssue?.rawValue, sessionIssue?.rawValue, nativeStatus.map { "OSStatus " + String($0) }]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

final class AppleDirectCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    func cancel() { lock.lock(); stopped = true; lock.unlock() }
    func check() throws {
        lock.lock(); defer { lock.unlock() }
        if stopped { throw AppleDirectFault("cancelled") }
    }
}

// One queue belongs to RuntimeStore. Descriptors never cross this queue.
final class AppleDirectExecutor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "local.arl.control.apple-events", qos: .userInitiated)
    func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try body() }) }
        }
    }
}

enum AppleDirectTarget: Sendable {
    case notes, messages
    var identifier: String { self == .notes ? "com.apple.Notes" : "com.apple.MobileSMS" }
    var path: String { self == .notes ? "/System/Applications/Notes.app" : "/System/Applications/Messages.app" }
}

enum AppleDirectDispatch {
    static func perform<T>(check: () throws -> Void, preflight: () throws -> AppleDirectPermission,
                           deliver: () throws -> T) throws -> T {
        try check()
        guard try preflight() == .authorized else { throw AppleDirectFault("needs_permission") }
        // Preflight can block. A late success never overrides cancellation,
        // session loss, process-generation change or the original deadline.
        try check()
        return try deliver()
    }
}

enum AppleDirectPermission: String, Sendable {
    case authorized, notDetermined, denied, unknown
}

/// AppleEvents.h requires an already-running target even for ask=false.
/// Silent refresh never opens it and never sends an Apple event.
enum AppleDirectAuthorization {
    static func permission(target: AppleDirectTarget, ask: Bool) throws -> AppleDirectPermission {
        try AppleDirectAuthority.verifySelf()
        if ask { try AppleDirectAuthority.requireUserSession() }
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: target.identifier)
        guard apps.count == 1, let app = apps.first, !app.isTerminated,
              app.bundleURL?.path == target.path else { throw AppleDirectFault("open_target_application") }
        var code: SecCode?, rule: SecRequirement?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid as String: app.processIdentifier] as CFDictionary, [], &code) == errSecSuccess,
              let code,
              SecRequirementCreateWithString(("anchor apple and identifier \"" + target.identifier + "\"") as CFString, [], &rule) == errSecSuccess,
              let rule, SecCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), rule) == errSecSuccess else { throw AppleDirectFault("target_identity_changed") }
        let address = NSAppleEventDescriptor(processIdentifier: app.processIdentifier)
        let status = AEDeterminePermissionToAutomateTarget(address.aeDesc, typeWildCard, typeWildCard, ask)
        switch status {
        case noErr: return .authorized
        case -1744: return .notDetermined
        case -1743: return .denied
        default: throw AppleDirectFault("permission_unknown", nativeStatus: status)
        }
    }
    /// An explicit connect click first rechecks silently. Existing grants and
    /// denials never cause another consent request.
    static func requestIfNeeded(stop: AppleDirectCancellation,
                                check: @Sendable (Bool) throws -> AppleDirectPermission) throws -> AppleDirectPermission {
        try stop.check()
        let value = try check(false)
        guard value == .notDetermined else { return value }
        try stop.check()
        let requested = try check(true)
        try stop.check()
        return requested
    }
    /// This is called only by a foreground action, never by the status poller.
    @MainActor static func prepareForUserAction(_ target: AppleDirectTarget, stop: AppleDirectCancellation) async throws {
        try stop.check()
        guard NSApplication.shared.isActive else { throw AppleDirectFault("user_action_unavailable") }
        if NSRunningApplication.runningApplications(withBundleIdentifier: target.identifier).isEmpty {
            let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = false
            _ = try await NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: target.path), configuration: configuration)
        }
        try stop.check()
    }
    static func failure(_ error: Error) -> AppleStatusProbeFailure {
        let fault = error as? AppleDirectFault
        let issue: AppleStatusIssue = switch fault?.code {
        case "open_target_application": .targetNotRunning
        case "owner_not_ready", "target_identity_changed": .ownerUnverified
        case "permission_unknown": .permissionUnknown
        default: .probeUnavailable
        }
        return .init(issue, nativeStatus: fault?.nativeStatus)
    }
}

@MainActor enum AppleDirectStatus {
    static func make(target: AppleDirectTarget, enabled: Bool, executor: AppleDirectExecutor,
                     preferences: UserDefaults, startAutomatically: Bool,
                     check: @escaping @Sendable (Bool) throws -> AppleDirectPermission) -> AppleStatusCoordinator<AppleDirectPermission> {
        let key = "appleDirectPermissionObservationV1." + target.identifier
        let owner = Bundle.main.bundleURL.path + "|" + AppleDirectAuthority.controlRequirement
        var initial = AppleConnectionState<AppleDirectPermission>()
        if enabled, let saved = preferences.dictionary(forKey: key), saved["owner"] as? String == owner,
           let raw = saved["permission"] as? String, let permission = AppleDirectPermission(rawValue: raw), permission != .unknown,
           let seconds = saved["observedAt"] as? Double, seconds.isFinite, seconds > 0, seconds <= Date().timeIntervalSince1970 {
            initial.value = permission; initial.observedAt = Date(timeIntervalSince1970: seconds); initial.restored = true
        }
        return .init(enabled: enabled, initial: initial, persist: { value, date in
            guard value != .unknown else { return }
            preferences.set(["owner": owner, "permission": value.rawValue, "observedAt": date.timeIntervalSince1970], forKey: key)
        }, startAutomatically: startAutomatically, probe: {
            do {
                let value = try await executor.run { try check(false) }
                guard value != .unknown else { throw AppleStatusProbeFailure(.permissionUnknown) }
                return value
            } catch let failure as AppleStatusProbeFailure { throw failure }
            catch { throw AppleDirectAuthorization.failure(error) }
        })
    }
}

enum AppleDirectAuthority {
    static func validEntitlements(_ values: [String: Any]) -> Bool {
        let expected = Set(["com.apple.security.automation.apple-events", "com.apple.security.personal-information.calendars"])
        return Set(values.keys) == expected && values.values.allSatisfy { value in
            guard let boolean = value as? NSNumber else { return false }
            return CFGetTypeID(boolean) == CFBooleanGetTypeID() && boolean.boolValue
        }
    }
    static let controlRequirement = "identifier \"local.arl.control\" and certificate leaf = H\"cd85ba24208488935f9ac0bec63e4be6aae189c4\" and certificate leaf[subject.OU] = \"LGZF25R84Z\""
    static func verifySelf() throws {
        var own: SecCode?, staticCode: SecStaticCode?, rule: SecRequirement?, info: CFDictionary?
        let installed = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Applications/ARL.app")
        guard Bundle.main.bundleURL.standardizedFileURL == installed,
              Bundle.main.bundleURL.resolvingSymlinksInPath() == installed,
              Bundle.main.object(forInfoDictionaryKey: "NSAppleEventsUsageDescription") as? String != nil,
              SecCodeCopySelf([], &own) == errSecSuccess, let own,
              SecRequirementCreateWithString(controlRequirement as CFString, [], &rule) == errSecSuccess, let rule,
              SecCodeCheckValidity(own, SecCSFlags(rawValue: kSecCSStrictValidate), rule) == errSecSuccess,
              SecCodeCopyStaticCode(own, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let fields = info as? [String: Any],
              let entitlements = fields[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
              validEntitlements(entitlements),
              let flags = fields[kSecCodeInfoFlags as String] as? NSNumber,
              flags.uint32Value & SecCodeSignatureFlags.runtime.rawValue != 0 else {
            throw AppleDirectFault("owner_not_ready")
        }
    }
    static func sessionIssue(_ session: [String: Any]?, uid: uid_t) -> AppleDirectSessionIssue? {
        guard let session else { return .dictionaryUnavailable }
        guard let actualUID = session[kCGSessionUserIDKey as String] as? NSNumber else { return .userIdentityUnavailable }
        guard actualUID.uint32Value == uid else { return .differentUser }
        guard session[kCGSessionOnConsoleKey as String] as? Bool == true else { return .notOnConsole }
        guard session[kCGSessionLoginDoneKey as String] as? Bool == true else { return .loginIncomplete }
        guard session["CGSSessionScreenIsLocked"] as? Bool != true else { return .screenLocked }
        return nil
    }
    static func sessionIsAvailable(_ session: [String: Any], uid: uid_t) -> Bool {
        sessionIssue(session, uid: uid) == nil
    }
    static func requireUserSession() throws {
        if let issue = sessionIssue(CGSessionCopyCurrentDictionary() as? [String: Any], uid: getuid()) {
            throw AppleDirectFault("user_session_unavailable", sessionIssue: issue)
        }
    }
}

// Only foreground actions or visible-page metadata loading construct a session.
// The status poller never constructs it; no script, listener, database or Contacts fallback exists.
final class AppleDirectSession {
    let target: AppleDirectTarget
    private let pid: pid_t
    private let launchDate: Date
    private let stop: AppleDirectCancellation
    private let deadline = ProcessInfo.processInfo.systemUptime + 20
    private let expires: Date
    init(target: AppleDirectTarget, stop: AppleDirectCancellation, expires: Date) throws {
        self.target = target; self.stop = stop; self.expires = expires
        try AppleDirectAuthority.verifySelf()
        try AppleDirectAuthority.requireUserSession()
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: target.identifier)
        guard apps.count == 1, let app = apps.first, !app.isTerminated,
              app.bundleURL?.path == target.path, let date = app.launchDate else {
            throw AppleDirectFault("open_target_application")
        }
        pid = app.processIdentifier; launchDate = date
        try check()
    }
    func check() throws {
        try stop.check()
        guard Date() < expires, ProcessInfo.processInfo.systemUptime < deadline else {
            throw AppleDirectFault("request_expired")
        }
        try AppleDirectAuthority.requireUserSession()
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
              app.bundleURL?.path == target.path, app.launchDate == launchDate else {
            throw AppleDirectFault("target_changed")
        }
        var code: SecCode?, rule: SecRequirement?
        let requirement = "anchor apple and identifier \"" + target.identifier + "\""
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid as String: pid] as CFDictionary, [], &code) == errSecSuccess,
              let code, SecRequirementCreateWithString(requirement as CFString, [], &rule) == errSecSuccess, let rule,
              SecCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), rule) == errSecSuccess else {
            throw AppleDirectFault("target_identity_changed")
        }
        try stop.check()
        guard Date() < expires, ProcessInfo.processInfo.systemUptime < deadline else { throw AppleDirectFault("request_expired") }
    }
    func permission(ask: Bool) throws -> AppleDirectPermission {
        try check()
        let target = NSAppleEventDescriptor(processIdentifier: pid)
        let result = AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, ask)
        // The system consent call is synchronous and may await the user. A
        // cancellation never claims that it dismissed or reversed OS consent.
        switch result {
        case noErr: return .authorized
        case -1744: return .notDetermined
        case -1743: return .denied
        default: return .unknown
        }
    }
    func send(eventClass: UInt32 = 0x636f7265, eventID: UInt32,
              parameters: [UInt32: NSAppleEventDescriptor]) throws -> NSAppleEventDescriptor {
        try check()
        let event = NSAppleEventDescriptor(eventClass: eventClass, eventID: eventID,
            targetDescriptor: .init(processIdentifier: pid), returnID: -1, transactionID: 0)
        for (key, value) in parameters { event.setParam(value, forKeyword: key) }
        return try AppleDirectDispatch.perform(check: check, preflight: { try self.permission(ask: false) }) {
          let remaining = min(deadline - ProcessInfo.processInfo.systemUptime, expires.timeIntervalSinceNow)
          guard remaining > 0 else { throw AppleDirectFault("request_expired") }
          do {
            let reply = try event.sendEvent(options: .init(rawValue: UInt(kAEWaitReply | kAENeverInteract | kAEDontRecord | kAEDoNotPromptForUserConsent)), timeout: min(5, remaining))
            if let error = reply.paramDescriptor(forKeyword: 0x6572726e), error.int32Value != 0 {
                throw AppleDirectFault(error.int32Value == -1728 ? "target_not_found" : "automation_failed", nativeStatus: error.int32Value)
            }
            return reply.paramDescriptor(forKeyword: 0x2d2d2d2d) ?? .null()
        } catch let error as AppleDirectFault { throw error }
          catch {
              let system = error as NSError
              let status = system.domain == NSOSStatusErrorDomain ? Int32(exactly: system.code) : nil
              throw AppleDirectFault("automation_unconfirmed", nativeStatus: status)
          }
        }
    }
}

enum AppleDirectDescriptor {
    static func countParameters(_ kind: UInt32, parent: NSAppleEventDescriptor = .null()) -> [UInt32: NSAppleEventDescriptor] {
        // CocoaStandard.sdef and the system AppleScript compiler use the
        // container as direct object, with the element class in 'kocl'.
        [UInt32(keyDirectObject): parent, UInt32(keyAEObjectClass): .init(typeCode: kind)]
    }
    static func specifier(_ kind: UInt32, form: UInt32, key: NSAppleEventDescriptor,
                          parent: NSAppleEventDescriptor = .null()) throws -> NSAppleEventDescriptor {
        let record = NSAppleEventDescriptor.record()
        record.setDescriptor(.init(typeCode: kind), forKeyword: 0x77616e74)
        record.setDescriptor(parent, forKeyword: 0x66726f6d)
        record.setDescriptor(.init(enumCode: form), forKeyword: 0x666f726d)
        record.setDescriptor(key, forKeyword: 0x73656c64)
        guard let value = record.coerce(toDescriptorType: typeObjectSpecifier) else { throw AppleDirectFault("encoding_failed") }
        return value
    }
    static func all(_ kind: UInt32, parent: NSAppleEventDescriptor = .null()) throws -> NSAppleEventDescriptor {
        // Absolute ordinals use 'abso', not the unrelated 'enum' descriptor.
        guard let ordinal = NSAppleEventDescriptor(descriptorType: typeAbsoluteOrdinal,
            data: Data([0x61, 0x6c, 0x6c, 0x20])) else { throw AppleDirectFault("encoding_failed") }
        return try specifier(kind, form: UInt32(formAbsolutePosition), key: ordinal, parent: parent)
    }
    static func object(_ kind: UInt32, id: String, parent: NSAppleEventDescriptor = .null()) throws -> NSAppleEventDescriptor {
        try specifier(kind, form: 0x49442020, key: .init(string: id), parent: parent)
    }
    static func property(_ code: UInt32, of object: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor {
        try specifier(0x70726f70, form: 0x70726f70, key: .init(typeCode: code), parent: object)
    }
    static func indexed(_ kind: UInt32, index: Int, parent: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor {
        guard index > 0, index <= Int(Int32.max) else { throw AppleDirectFault("invalid_index") }
        return try specifier(kind, form: 0x696e6478, key: .init(int32: Int32(index)), parent: parent)
    }
}
