import Foundation

enum PerformanceMetric: String, Sendable { case cpu, pressure, swap, processCPU, processRSS }
struct PerformancePoint: Identifiable, Sendable {
    let date: Date; let value: Double; let series: String; let segment: String
    var id: String { "\(series)-\(date.timeIntervalSince1970)" }
    var displaySeries: String {
        switch series { case "系统 CPU": "处理器"; case "交换空间": "临时内存"; default: series }
    }
    var displayExplanation: String {
        switch series { case "系统 CPU": "整台电脑的处理器用量"; case "交换空间": "系统临时用硬盘代替的内存"; default: displaySeries }
    }
}
enum PerformanceSeries {
    static func points(in samples: [PerformanceHistory.Sample], metric: PerformanceMetric, processID: String? = nil) -> [PerformancePoint] {
        var result: [PerformancePoint] = []
        var runs: [String: Int] = [:]
        var missing: Set<String> = []
        for sample in samples {
            let values: [(String, Double?)]
            switch metric {
            case .cpu: values = [("系统 CPU", sample.load.cpuPercent)]
            case .swap: values = [("交换空间", sample.load.swapUsedBytes.map { Double($0) / 1_073_741_824 })]
            case .pressure: values = [("内存压力", ["正常": 0.0, "警告": 1.0, "严重": 2.0][sample.load.pressure])]
            case .processCPU: values = sample.load.processes.filter { processID == nil || $0.id == processID }.map { ($0.id, $0.cpu_percent) }
            case .processRSS: values = sample.load.processes.filter { processID == nil || $0.id == processID }.map { ($0.id, $0.rss_bytes.map { Double($0) / 1_048_576 }) }
            }
            let present = Set(values.map(\.0))
            for name in Set(runs.keys).subtracting(present) { missing.insert(name) }
            for (name, value) in values {
                runs[name, default: 0] += 0
                guard let value else { missing.insert(name); continue }
                if missing.remove(name) != nil { runs[name, default: 0] += 1 }
                result.append(PerformancePoint(date: sample.load.sampledAt, value: value, series: name, segment: "\(name)-\(sample.segment)-\(runs[name, default: 0])"))
            }
        }
        return result
    }
}
