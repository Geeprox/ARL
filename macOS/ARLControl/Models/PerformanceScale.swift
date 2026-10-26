import Foundation

enum PerformanceScale {
    static func upper(metric: PerformanceMetric, values: [Double]) -> Double {
        if metric == .cpu { return 100 }
        if metric == .pressure { return 2.2 }
        let minimum: Double = metric == .swap ? 1 : metric == .processCPU ? 100 : 32
        return max(minimum, (values.max() ?? 0) * 1.15)
    }
    static func ticks(metric: PerformanceMetric, upper: Double) -> [Double] {
        metric == .pressure ? [0, 1, 2] : (0...4).map { Double($0) * upper / 4 }
    }
}
