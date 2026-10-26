import Foundation

/// Current readings expire independently of retained historical observations.
struct ResourceSampleState: Sendable {
    enum Status: Sendable { case current, expired, invalidTime, waiting, disconnected }
    static let maximumAge: TimeInterval = 15
    let status: Status
    let current: SystemLoad?
    let sampledAt: Date?

    init(load: SystemLoad?, connected: Bool, now: Date) {
        let timestamp = load?.sampledAt
        let age = timestamp.map { now.timeIntervalSince($0) } ?? -.infinity
        let validTime = timestamp.map { $0.timeIntervalSince1970.isFinite && $0.timeIntervalSince1970 > 0 } ?? false
        sampledAt = validTime ? timestamp : nil
        if !connected { status = .disconnected }
        else if load == nil { status = .waiting }
        else if !validTime || !age.isFinite || age < 0 { status = .invalidTime }
        else if age >= Self.maximumAge { status = .expired }
        else { status = .current }
        current = status == .current ? load : nil
    }

    var title: String {
        switch status {
        case .current: "正在采样"
        case .expired: "数据过期"
        case .invalidTime: "时间异常"
        case .waiting: "等待采样"
        case .disconnected: "已断开 · 历史样本"
        }
    }
    var sampleTimeTitle: String {
        guard let sampledAt else { return "尚无采样时间" }
        return "采样于 \(sampledAt.formatted(date: .omitted, time: .standard))"
    }
}
