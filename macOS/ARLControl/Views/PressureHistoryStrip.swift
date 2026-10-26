import SwiftUI

struct PressureHistoryStrip: View {
    let samples: [PerformanceHistory.Sample]
    let now: Date
    @State private var selected: PerformanceHistory.Sample?
    private var start: Date { samples.first?.load.sampledAt ?? now.addingTimeInterval(-60) }
    private var duration: Double { max(10, now.timeIntervalSince(start)) }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if samples.isEmpty { Text("等待测量").font(.caption).foregroundStyle(.secondary).frame(height: 28) }
            else {
                Canvas { context, size in
                    for (index, sample) in samples.enumerated() {
                        let x = sample.load.sampledAt.timeIntervalSince(start) / duration * size.width
                        let next = index + 1 < samples.count ? samples[index + 1] : nil
                        let continuous = next.map { $0.segment == sample.segment && $0.load.sampledAt.timeIntervalSince(sample.load.sampledAt) <= 15 } ?? false
                        let width = continuous ? max(1, (next!.load.sampledAt.timeIntervalSince(sample.load.sampledAt)) / duration * size.width) : 2
                        context.fill(Path(roundedRect: CGRect(x: x, y: 3, width: width, height: 18), cornerRadius: 1), with: .color(color(sample.load.pressure)))
                    }
                }.frame(height: 26).overlay {
                    GeometryReader { geometry in
                        Rectangle().fill(.clear).contentShape(Rectangle()).onContinuousHover { phase in
                            switch phase { case .active(let point):
                                let date = start.addingTimeInterval(point.x / geometry.size.width * duration)
                                selected = samples.min { abs($0.load.sampledAt.timeIntervalSince(date)) < abs($1.load.sampledAt.timeIntervalSince(date)) }
                            case .ended: selected = nil }
                        }
                    }
                }.accessibilityLabel("内存压力历史，\(samples.count) 个实际样本")
            }
            HStack {
                if let selected { Text("\(selected.load.sampledAt.formatted(date: .omitted, time: .standard)) · \(selected.load.pressure)") }
                else { Text("正常 / 警告 / 严重"); Spacer(); Text("本次运行") }
            }.font(.caption2).foregroundStyle(.secondary)
        }
    }
    private func color(_ pressure: String) -> Color { switch pressure { case "正常": .green.opacity(0.7); case "警告": .orange; case "严重": .red; default: .secondary.opacity(0.3) } }
}
