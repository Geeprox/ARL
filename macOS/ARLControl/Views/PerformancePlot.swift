import SwiftUI
import Charts

struct PerformancePlot: View {
    typealias Metric = PerformanceMetric
    typealias Point = PerformancePoint
    let samples: [PerformanceHistory.Sample]
    let metric: Metric
    let now: Date
    var height: CGFloat = 180
    var processID: String? = nil
    @State private var hover: Date?
    private var points: [Point] { PerformanceSeries.points(in: samples, metric: metric, processID: processID) }
    private var domain: ClosedRange<Date> {
        let end = max(now, samples.last?.load.sampledAt ?? now)
        return (samples.first?.load.sampledAt ?? end.addingTimeInterval(-60)).addingTimeInterval(-1)...max(end, (samples.first?.load.sampledAt ?? end).addingTimeInterval(10))
    }
    private var axisValues: [Double] { PerformanceScale.ticks(metric: metric, upper: upper) }
    private var upper: Double { PerformanceScale.upper(metric: metric, values: points.map(\.value)) }
    var body: some View {
        let chartPoints = points
        let selected = selectedSample
        VStack(alignment: .leading, spacing: 8) {
            if chartPoints.isEmpty {
                ContentUnavailableView(samples.isEmpty ? "等待首个样本" : "此指标尚无样本", systemImage: "chart.xyaxis.line", description: Text("等待测量")).help("取得测量记录后显示曲线")
                    .frame(height: max(50, height - 24))
            } else {
                Chart {
                    ForEach(chartPoints) { point in
                        LineMark(x: .value("时间", point.date), y: .value("数值", point.value), series: .value("区间", point.segment))
                            .foregroundStyle(by: .value("指标", point.displaySeries)).lineStyle(StrokeStyle(lineWidth: 1.8))
                            .interpolationMethod(metric == .pressure ? .stepEnd : .linear)
                        if chartPoints.count == 1 || point.date == selected?.load.sampledAt || point.id == chartPoints.last?.id {
                            PointMark(x: .value("时间", point.date), y: .value("数值", point.value))
                                .foregroundStyle(EditorialStyle.accent).symbolSize(point.id == chartPoints.last?.id ? 24 : 10)
                        }
                    }
                    if let selected {
                        RuleMark(x: .value("时间", selected.load.sampledAt)).foregroundStyle(.secondary.opacity(0.4)).lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    }
                }
                .chartXScale(domain: domain).chartYScale(domain: 0...upper)
                .chartForegroundStyleScale(range: [EditorialStyle.graphite, EditorialStyle.accent, .secondary, .brown])
                .chartLegend(processID == nil && (metric == .processCPU || metric == .processRSS) ? .visible : .hidden)
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 3)) { value in AxisValueLabel(format: .dateTime.minute().second()); AxisTick(); AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3])) } }
                .chartYAxis { AxisMarks(position: .leading, values: axisValues) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3])); AxisValueLabel {
                        if let number = value.as(Double.self) { Text(axisTitle(number)).font(.caption2) }
                    }
                } }
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        Rectangle().fill(.clear).contentShape(Rectangle()).onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                guard let frame = proxy.plotFrame else { hover = nil; return }
                                let rect = geometry[frame]
                                hover = rect.contains(location) ? proxy.value(atX: location.x - rect.minX, as: Date.self) : nil
                            case .ended: hover = nil
                            }
                        }
                        .gesture(SpatialTapGesture().onEnded { event in
                            guard let frame = proxy.plotFrame else { return }
                            let rect = geometry[frame]
                            if rect.contains(event.location) { hover = proxy.value(atX: event.location.x - rect.minX, as: Date.self) }
                        })
                    }
                }
                .frame(height: max(50, height - 24))
                .accessibilityLabel(accessibilityDescription)
                .help(points.first?.displayExplanation ?? "")
            }
            if let selected {
                HStack(spacing: 12) { Text(selected.load.sampledAt.formatted(date: .omitted, time: .standard)).font(.caption.monospaced()); Text(sampleTitle(selected.load)).font(.caption).foregroundStyle(.secondary).lineLimit(2); Spacer(minLength: 0) }
                    .frame(height: 18).textSelection(.enabled)
            } else { Color.clear.frame(height: 18) }
        }
    }
    private var selectedSample: PerformanceHistory.Sample? { guard let hover else { return nil }; return samples.min { abs($0.load.sampledAt.timeIntervalSince(hover)) < abs($1.load.sampledAt.timeIntervalSince(hover)) } }
    private var accessibilityDescription: String { "\(points.count) 个实际测量点。\(samples.last.map { sampleTitle($0.load) } ?? "等待采样")" }
    private func axisTitle(_ value: Double) -> String {
        switch metric { case .cpu, .processCPU: return "\(Int(value))%"; case .swap: return String(format: "%.1f GiB", value); case .processRSS: return "\(Int(value)) MiB"; case .pressure: return [0: "正常", 1: "警告", 2: "严重"][Int(value)] ?? "" }
    }
    private func sampleTitle(_ load: SystemLoad) -> String {
        switch metric {
        case .cpu: return "系统 CPU \(MetricFormat.percent(load.cpuPercent))"
        case .swap: return "交换空间 \(MetricFormat.bytes(load.swapUsedBytes))"
        case .pressure: return "内存压力 \(load.pressure)"
        case .processCPU: return load.processes.filter { processID == nil || $0.id == processID }.map { "\($0.id) \(MetricFormat.percent($0.cpu_percent))" }.joined(separator: " · ")
        case .processRSS: return load.processes.filter { processID == nil || $0.id == processID }.map { "\($0.id) \(MetricFormat.bytes($0.rss_bytes))" }.joined(separator: " · ")
        }
    }
}
