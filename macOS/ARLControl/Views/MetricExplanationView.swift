import SwiftUI

struct MetricExplanationView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("用量说明").font(.headline)
            Text(("显示实际内存占用，程序统计范围见详情" + "\n" + "ARL 驻留内存为后台服务进程的 RSS。其他受控进程单独列出，共享进程计一次；未列出的窗口进程不计入。")).font(.callout)
            Text(("系统内存压力不代表已发生卡顿" + "\n" + "内存压力由 macOS 报告。当前未测量交换速率或响应延迟，压力等级不代表已观察到卡顿。")).font(.callout).foregroundStyle(.secondary)
        }.padding(18).frame(width: 310)
    }
}
