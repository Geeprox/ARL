import Foundation

enum PerformanceTimeRange: Int, CaseIterable, Identifiable, Sendable {
    case session = 0, minute = 60, fiveMinutes = 300, fifteenMinutes = 900, hour = 3600
    var id: Int { rawValue }
    var title: String { self == .session ? "会话" : "\(rawValue / 60) 分钟" }
    var seconds: TimeInterval? { self == .session ? nil : Double(rawValue) }
    func isEligible(span: TimeInterval, selection: Self) -> Bool { self == .session || self == selection || span >= Double(rawValue) }
}
