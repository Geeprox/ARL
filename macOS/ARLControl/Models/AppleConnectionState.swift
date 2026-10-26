import Foundation

enum AppleStatusIssue: String, Sendable {
    case targetNotRunning = "target_not_running"
    case permissionUnknown = "permission_unknown"
    case ownerUnverified = "owner_unverified"
    case probeUnavailable = "probe_unavailable"
    var title: String {
        switch self {
        case .targetNotRunning: "应用尚未运行，最近权限已保留。"
        case .permissionUnknown: "系统状态暂未确定，将自动更新。"
        case .ownerUnverified: "应用身份未通过核验，请查看安装。"
        case .probeUnavailable: "状态暂未更新，将自动重试。"
        }
    }
}
struct AppleStatusProbeFailure: Error, Equatable, Sendable {
    let issue: AppleStatusIssue
    let nativeStatus: Int32?
    init(_ issue: AppleStatusIssue, nativeStatus: Int32? = nil) {
        self.issue = issue; self.nativeStatus = nativeStatus
    }
}
/// Observations are display evidence. Every business backend still checks its
/// current owner, OS permission, exact target and once-only journal before effect.
struct AppleConnectionState<Value: Equatable & Sendable>: Sendable {
    var value: Value?
    var observedAt: Date?
    var lastAttemptAt: Date?
    var refreshing = false
    var lastFailure: AppleStatusProbeFailure?
    var restored = false
    var showingLastKnown: Bool { value != nil && (restored || lastFailure != nil) }
    mutating func accept(_ value: Value, at date: Date) {
        self.value = value; observedAt = date; lastAttemptAt = date
        refreshing = false; lastFailure = nil; restored = false
    }
}
