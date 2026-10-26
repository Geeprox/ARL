import SwiftUI

struct MetricsView: View {
    let store: RuntimeStore
    @State private var range: PerformanceTimeRange = .session
    @State private var processMemory = true
    @State private var explaining = false
    private let columns = [GridItem(.flexible()), GridItem(.flexible())]
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                TimelineView(.periodic(from: .now, by: 1)) { timeline in
                    let state = sampleState(at: timeline.date)
                    HStack(spacing: 12) {
                        StatusBadge(title: state.title, color: state.current != nil ? EditorialStyle.accent : .secondary)
                        Text("\(visibleSamples(at: timeline.date).count) 个样本").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                Spacer(minLength: 8)
                Button { explaining.toggle() } label: { Image(systemName: "info.circle") }.buttonStyle(.borderless).help("指标说明").popover(isPresented: $explaining) { MetricExplanationView() }
                Text("时间范围").font(.caption).foregroundStyle(.secondary)
                PerformanceRangeSelector(selection: $range, historySpan: store.history.span)
            }.frame(height: 34)
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                let state = sampleState(at: timeline.date)
                let current = state.current
                let samples = visibleSamples(at: timeline.date)
                VStack(alignment: .leading, spacing: 16) {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                        DetailCard(title: "", height: 270) {
                            HStack(spacing: 8) {
                                metricTitle(processMemory ? "内存用量" : "处理器").help(processMemory ? "ARL进程实际占用的内存" : "ARL进程的处理器用量")
                                if processMemory { Text("内存用量").help("进程实际占用的内存").font(.caption).foregroundStyle(.secondary) }
                                Spacer(minLength: 0)
                                Menu { Button("内存用量") { processMemory = true }; Button("处理器") { processMemory = false } } label: { Image(systemName: "ellipsis").font(.callout) }.menuStyle(.borderlessButton).fixedSize().help("切换进程指标")
                            }.frame(height: 18)
                            metricValue(processValue(current), primary: true)
                            PerformancePlot(samples: samples, metric: processMemory ? .processRSS : .processCPU, now: timeline.date, height: 140, processID: "runtime")
                        }.help(("实际内存用量，CPU可超过100%" + "\n" + "ARL 后台服务 RSS；进程 CPU 可超过 100%"))
                        metricCard("处理器", value: MetricFormat.percent(current?.cpuPercent), primary: true) {
                            PerformancePlot(samples: samples, metric: .cpu, now: timeline.date, height: 140)
                        }.help("整台电脑的处理器用量\n系统 CPU：0–100%")
                        metricCard("内存压力", value: current?.pressure ?? "未知", color: state.pressureColor) {
                            PressureHistoryStrip(samples: samples, now: timeline.date).frame(height: 90, alignment: .center)
                        }.help(("系统报告的压力等级，未确认卡顿" + "\n" + "macOS 报告的等级；不代表已观察到卡顿"))
                        metricCard("临时内存", value: MetricFormat.bytes(current?.swapUsedBytes)) {
                            PerformancePlot(samples: samples, metric: .swap, now: timeline.date, height: 90)
                        }.help("系统临时用硬盘代替的内存")
                    }
                    processTable(current)
                    HStack { Text(state.sampleTimeTitle); Spacer(); Text(("本次运行，最多1小时" + "\n" + "本次会话 · 最多 1 小时")); if let total = current?.memoryTotalBytes { Text("物理内存 \(MetricFormat.bytes(total))") } }.font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
    private func processTable(_ current: SystemLoad?) -> some View {
        DetailCard(title: "后台程序") {
            HStack { Text("名称"); Spacer(); Text("处理器").frame(width: 80, alignment: .trailing); Text("内存用量").frame(width: 100, alignment: .trailing) }.font(.caption).foregroundStyle(.secondary)
            Divider()
            ForEach(current?.processes ?? []) { process in
                HStack(spacing: 12) {
                    Image(systemName: "cpu").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(process.id == "runtime" ? "ARL 后台" : process.id).font(.callout.weight(.medium))
                        Text(process.app_ids.map { AppIdentity.presentation($0).name }.joined(separator: "、")).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer(minLength: 10)
                    Text(MetricFormat.percent(process.cpu_percent)).monospacedDigit().frame(width: 80, alignment: .trailing)
                    Text(MetricFormat.bytes(process.rss_bytes)).monospacedDigit().frame(width: 100, alignment: .trailing)
                }.frame(minHeight: 40).help(process.stateTitle)
            }
            if current == nil { Text("暂无测量数据").font(.callout).foregroundStyle(.secondary) }
        }.help("由本服务管理的后台程序")
    }
    private func metricTitle(_ title: String) -> some View {
        HStack(spacing: 9) { Rectangle().fill(EditorialStyle.graphite).frame(width: 12, height: 1); Text(title).font(.headline).lineLimit(1) }
    }
    private func metricValue(_ value: String, color: Color = EditorialStyle.graphite, primary: Bool) -> some View {
        Text(value).font(.system(size: primary ? 36 : 25, weight: .semibold)).monospacedDigit().foregroundStyle(color)
            .lineLimit(1).minimumScaleFactor(0.75).frame(height: primary ? 48 : 32, alignment: .leading)
    }
    private func metricCard<Content: View>(_ title: String, value: String, color: Color = EditorialStyle.graphite, primary: Bool = false, @ViewBuilder content: @escaping () -> Content) -> some View {
        DetailCard(title: "", height: primary ? 270 : 204) {
            metricTitle(title).frame(height: 18, alignment: .leading)
            metricValue(value, color: color, primary: primary)
            content()
        }
    }
    private func processValue(_ current: SystemLoad?) -> String {
        guard let process = current?.processes.first(where: { $0.id == "runtime" }) else { return "—" }
        return processMemory ? MetricFormat.bytes(process.rss_bytes) : MetricFormat.percent(process.cpu_percent)
    }
    private func visibleSamples(at now: Date) -> [PerformanceHistory.Sample] { store.history.visible(seconds: range.seconds, now: now) }
    private func sampleState(at now: Date) -> ResourceSampleState {
        ResourceSampleState(load: store.control.metrics.value, connected: store.connected, now: now)
    }
}
