import Foundation

/// Session-only samples. Outages, missing values and delayed samples break lines.
struct PerformanceHistory: Sendable {
    struct Sample: Identifiable, Sendable {
        let load: SystemLoad
        let segment: Int
        var id: Date { load.sampledAt }
    }
    private(set) var samples: [Sample] = []
    private var segment = 0
    private var interrupted = false
    static let capacity = 720
    mutating func interrupt() { interrupted = true }
    mutating func append(_ load: SystemLoad) {
        if let last = samples.last {
            guard load.sampledAt > last.load.sampledAt else { return }
            if interrupted || load.sampledAt.timeIntervalSince(last.load.sampledAt) > 15 { segment += 1 }
        }
        interrupted = false
        samples.append(Sample(load: load, segment: segment))
        samples.removeAll { load.sampledAt.timeIntervalSince($0.load.sampledAt) > 3600 }
        if samples.count > Self.capacity { samples.removeFirst(samples.count - Self.capacity) }
    }
    var span: TimeInterval { guard let first = samples.first, let last = samples.last else { return 0 }; return last.load.sampledAt.timeIntervalSince(first.load.sampledAt) }
    func visible(seconds: TimeInterval?, now: Date) -> [Sample] {
        guard let seconds else { return samples }
        return samples.filter { $0.load.sampledAt >= now.addingTimeInterval(-seconds) && $0.load.sampledAt <= now }
    }
    static func nearest(to date: Date, in visible: [Sample]) -> Sample? {
        var lower = visible.startIndex
        var upper = visible.endIndex
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if visible[middle].id < date { lower = middle + 1 }
            else { upper = middle }
        }
        if lower == visible.startIndex { return visible.first }
        if lower == visible.endIndex { return visible.last }
        let previous = visible[lower - 1]
        let next = visible[lower]
        return date.timeIntervalSince(previous.id) <= next.id.timeIntervalSince(date) ? previous : next
    }
}

enum MetricFormat {
    static func percent(_ value: Double?) -> String { value.map { String(format: "%.1f%%", $0) } ?? "—" }
    static func bytes(_ value: UInt64?) -> String { value.map { ByteCountFormatter.string(fromByteCount: Int64(clamping: $0), countStyle: .memory) } ?? "—" }
}
