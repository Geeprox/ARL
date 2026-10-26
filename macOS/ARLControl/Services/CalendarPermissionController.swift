import AppKit
import EventKit
import Foundation
import Observation

enum CalendarPermissionState: String, Codable, Sendable {
    case notDetermined, writeOnly, fullAccess, denied, restricted, unknown, disabled
    init(_ status: EKAuthorizationStatus) {
        self = switch status {
        case .notDetermined: .notDetermined
        case .writeOnly: .writeOnly
        case .fullAccess: .fullAccess
        case .denied: .denied
        case .restricted: .restricted
        @unknown default: .unknown
        }
    }
    var title: String {
        switch self {
        case .notDetermined: "尚未允许"
        case .writeOnly: "允许写入"
        case .fullAccess: "允许读写"
        case .denied: "未获允许"
        case .restricted: "系统限制"
        case .unknown: "待检查"
        case .disabled: "尚未开放"
        }
    }
}

/// TCC belongs to the installed ARL main process. Permission does not admit an
/// execution scope or make the separate remote Calendar effect host usable.
@MainActor @Observable final class CalendarPermissionController {
    private(set) var state: CalendarPermissionState = .unknown
    private(set) var observedAt: Date?
    private(set) var lastKnownState: CalendarPermissionState?
    private(set) var lastProbeFailed = false
    private(set) var busy = false
    private(set) var actionAdmissionHeld = false
    private(set) var message: String?
    private(set) var nativeStatus: Int32?
    private(set) var requestGranted: Bool?
    private(set) var requestErrorDomain: String?
    var requestDiagnostic: String? {
        if let requestGranted { return "completion=" + String(requestGranted) + " · status=" + state.rawValue }
        if let requestErrorDomain { return "domain=" + requestErrorDomain + " · status=" + state.rawValue }
        return nil
    }
    private let preferences: UserDefaults
    @ObservationIgnored private var polling: Task<Void, Never>?
    private let requestReadWrite: @MainActor () async throws -> Bool
    private let verifyReadWriteUsage: @MainActor () throws -> Void
    private let enabled: Bool
    private let readStatus: @MainActor () -> CalendarPermissionState
    private let requestAccess: @MainActor () async throws -> Bool
    private let verifyOwner: @MainActor () throws -> Void
    private let foreground: @MainActor () -> Bool

    init(enabled: Bool,
         readStatus: @escaping @MainActor () -> CalendarPermissionState = { .init(EKEventStore.authorizationStatus(for: .event)) },
         requestAccess: @escaping @MainActor () async throws -> Bool = {
             // A store is constructed only after an explicit foreground click.
             try await EKEventStore().requestWriteOnlyAccessToEvents()
         },
         verifyOwner: @escaping @MainActor () throws -> Void = {
             try AppleDirectAuthority.verifySelf()
             try AppleDirectAuthority.requireUserSession()
             guard Bundle.main.object(forInfoDictionaryKey: "NSCalendarsWriteOnlyAccessUsageDescription") as? String != nil,
                   Bundle.main.object(forInfoDictionaryKey: "NSCalendarsUsageDescription") == nil else {
                 throw AppleDirectFault("owner_not_ready")
             }
         },
         foreground: @escaping @MainActor () -> Bool = { NSApp.isActive },
         preferences: UserDefaults = .standard,
         startAutomatically: Bool = true,
         requestReadWrite: @escaping @MainActor () async throws -> Bool = {
             try await EKEventStore().requestFullAccessToEvents()
         },
         verifyReadWriteUsage: @escaping @MainActor () throws -> Void = {
             guard let text = Bundle.main.object(forInfoDictionaryKey: "NSCalendarsFullAccessUsageDescription") as? String,
                   !text.isEmpty else { throw AppleDirectFault("owner_not_ready") }
         }) {
        self.enabled=enabled;self.readStatus=readStatus;self.requestAccess=requestAccess
        self.verifyOwner=verifyOwner;self.foreground=foreground;self.preferences=preferences
        self.requestReadWrite=requestReadWrite;self.verifyReadWriteUsage=verifyReadWriteUsage
        if enabled, let raw=preferences.string(forKey:"calendarLastPermissionV1"),
           let previous=CalendarPermissionState(rawValue:raw), previous != .unknown, previous != .disabled,
           let at=preferences.object(forKey:"calendarPermissionObservedAtV1") as? Date {
            state=previous;lastKnownState=previous;observedAt=at
        }
        refresh()
        if enabled && startAutomatically {
            polling=Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    let seconds=self?.foreground() == true ? 30.0:120.0
                    do { try await Task.sleep(for:.seconds(seconds)) } catch { return }
                    guard !Task.isCancelled else { return }
                    self?.refresh()
                }
            }
        }
    }
    deinit { polling?.cancel() }
    var canAct: Bool { enabled && !actionAdmissionHeld && !busy }
    func suspendForExit() { actionAdmissionHeld = true }
    func resumeAfterCancelledExit() { actionAdmissionHeld = false }
    func refresh() {
        guard !busy, !actionAdmissionHeld else { return }
        guard enabled else { state = .disabled; return }
        let value = readStatus()
        lastProbeFailed = value == .unknown
        guard value != .unknown else { return }
        observe(value)
    }
    private func observe(_ value: CalendarPermissionState) {
        state = value
        if value != .unknown {
            lastKnownState = value; observedAt = Date(); lastProbeFailed = false
            if value != .disabled {
                preferences.set(value.rawValue,forKey:"calendarLastPermissionV1")
                preferences.set(observedAt,forKey:"calendarPermissionObservedAtV1")
            }
        }
        else { lastProbeFailed = true }
    }
    func request() async {
        guard enabled, !actionAdmissionHeld, !busy, foreground() else { return }
        // A click uses the current raw status for admission, never a cached grant.
        observe(readStatus());message=nil;nativeStatus=nil;requestGranted=nil;requestErrorDomain=nil
        guard state == .notDetermined else {
            message = state == .denied ? "请在系统设置中允许日历。" : "已检查当前权限。"
            return
        }
        do { try verifyOwner() }
        catch { message="应用身份未通过核验。";return }
        busy=true
        defer { busy=false }
        do {
            let granted = try await requestAccess()
            requestGranted = granted
            observe(readStatus())
            switch state {
            case .writeOnly, .fullAccess: message = granted ? "已允许添加事件。" : "权限已变化，请核对状态。"
            case .denied: message = "未获允许，请到系统设置查看。"
            case .restricted: message = "系统限制了日历权限。"
            default: message = "权限尚未决定，请查看详情。"
            }
        } catch {
            let error=error as NSError
            nativeStatus=Int32(exactly:error.code)
            requestErrorDomain = ["EKErrorDomain", NSCocoaErrorDomain, NSOSStatusErrorDomain, NSPOSIXErrorDomain].contains(error.domain) ? error.domain : "other"
            observe(readStatus())
            message="授权请求未完成，请查看详情。"
        }
    }
    /// Explicit business goal: list/query/edit and verify saved results. This
    /// method is only called by the visible permission action; never by polling,
    /// page appearance, the handler, Mio or the existing write-only request().
    func requestFullAccess() async {
        guard enabled, !actionAdmissionHeld, !busy, foreground() else { return }
        let current=readStatus();observe(current)
        message=nil;nativeStatus=nil;requestGranted=nil;requestErrorDomain=nil
        guard current == .notDetermined || current == .writeOnly else {
            message=current == .fullAccess ? "已允许查看及编辑日程。":"请在系统设置中核对日历。"
            return
        }
        do { try verifyOwner(); try verifyReadWriteUsage() }
        catch { message="应用身份未通过核验。";return }
        busy=true;defer{busy=false}
        do {
            requestGranted=try await requestReadWrite();observe(readStatus())
            message=state == .fullAccess ? "已允许查看及编辑日程。":"当前权限尚未允许查看。"
        } catch {
            let value=error as NSError;nativeStatus=Int32(exactly:value.code)
            requestErrorDomain=["EKErrorDomain",NSCocoaErrorDomain,NSOSStatusErrorDomain,NSPOSIXErrorDomain].contains(value.domain) ? value.domain:"other"
            observe(readStatus());message="授权请求未完成，请稍后再试。"
        }
    }

}
