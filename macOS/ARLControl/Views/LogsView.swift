import SwiftUI
import UniformTypeIdentifiers

struct MetadataLogDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    let data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { throw CocoaError(.fileReadUnsupportedScheme) }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents:data) }
}
struct LogsView: View {
    let store: RuntimeStore
    @State private var search = ""
    @State private var level = "all"
    @State private var selected: Int?
    @State private var exporting = false
    @State private var exportData = Data()
    @State private var exportError = false
    @State private var preparing = false
    @State private var exportNotice: String?
    @FocusState private var logFocused: Bool
    private var feature: MetadataFeature<RedactedLogPage> { store.control.logs }
    private var filtered: [RedactedLogEntry] {
        (feature.value?.entries ?? []).filter {
            (level == "all" || $0.level == level) && (search.isEmpty || $0.searchableText.localizedCaseInsensitiveContains(search) || $0.eventTitle.localizedCaseInsensitiveContains(search) || ($0.app_id.map { AppIdentity.presentation($0).name.localizedCaseInsensitiveContains(search) } ?? false))
        }
    }
    private var selectedEntry: RedactedLogEntry? { filtered.first { $0.id == selected } }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                EditorialHeading(title: "运行记录", subtitle: "运行记录")
                Spacer()
                if let label = store.previewLabel { StatusBadge(title: label) }
                Menu {
                    Button("导出结果") {
                        do { let export = try ControlLogExport.filtered(filtered); exportData = export.content; exporting = true; exportNotice = "已载入的筛选结果 · \(export.count) 条" } catch { exportError = true }
                    }.help("只导出已载入的筛选结果").disabled(filtered.isEmpty)
                    Button("导出近况") { exportRecent() }.help("导出最近15分钟的运行记录")
                } label: { Label("导出", systemImage: "square.and.arrow.up") }.disabled(feature.value == nil || preparing)
                if preparing { ProgressView().controlSize(.small) }
            }
            HStack(spacing: 12) {
                TextField("查找记录", text: $search).help("输入事件、应用或状态代码").textFieldStyle(.roundedBorder).accessibilityLabel("查找记录")
                Picker("级别", selection: $level) { Text("全部级别").tag("all"); Text("信息").tag("info"); Text("警告").tag("warning"); Text("错误").tag("error") }.frame(width: 135)
            }.disabled(feature.value == nil)
            HStack(alignment: .top, spacing: 0) {
                VStack(spacing: 0) {
                    HStack { Text("时间").frame(width: 85, alignment: .leading); Text("事件").frame(maxWidth: .infinity, alignment: .leading); Text("应用").frame(width: 120, alignment: .leading) }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 10).background(EditorialStyle.canvas)
                    Divider()
                    List(filtered, selection: $selected) { entry in
                        HStack(spacing: 12) {
                            Text(Date(timeIntervalSince1970: Double(entry.at_ms) / 1000), format: .dateTime.hour().minute().second()).font(.caption.monospaced()).foregroundStyle(.secondary).frame(width: 85, alignment: .leading)
                            HStack(spacing: 7) { Circle().fill(levelColor(entry.level)).frame(width: 5, height: 5); Text(entry.eventTitle).lineLimit(1) }.frame(maxWidth: .infinity, alignment: .leading)
                            Text(entry.app_id.map { AppIdentity.presentation($0).name } ?? "后台服务").font(.callout).foregroundStyle(.secondary).lineLimit(1).frame(width: 120, alignment: .leading)
                        }.padding(.vertical, 3).tag(entry.id)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("\(Date(timeIntervalSince1970: Double(entry.at_ms) / 1000).formatted(date: .omitted, time: .standard))，\(entry.eventTitle)，\(entry.app_id.map { AppIdentity.presentation($0).name } ?? "后台服务")，\(levelTitle(entry.level))")
                    }.listStyle(.plain).scrollContentBackground(.hidden).background(EditorialStyle.panel)
                    .focusable().focused($logFocused)
                    .onKeyPress(.downArrow) { selectAdjacent(1); return .handled }
                    .onKeyPress(.upArrow) { selectAdjacent(-1); return .handled }
                    .modifier(LogScrollTrigger(load: { store.requestLogPage() }))
                    .overlay {
                        if filtered.isEmpty {
                            ContentUnavailableView(emptyTitle, systemImage: store.logReadError != nil && feature.value == nil ? "exclamationmark.circle" : "list.bullet.rectangle", description: Text(emptyDescription))
                        }
                    }
                }
                if let entry = selectedEntry {
                    Divider()
                    VStack(alignment: .leading, spacing: 14) {
                        HStack { Text("记录详情").font(.headline); Spacer(); Button { selected = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).help("关闭详情") }
                        ScrollView {
                            VStack(alignment: .leading, spacing: 14) {
                                Text(entry.eventTitle).font(.title3.weight(.medium))
                                StatusBadge(title: levelTitle(entry.level), color: levelColor(entry.level))
                                Divider()
                                detail("时间", Date(timeIntervalSince1970: Double(entry.at_ms) / 1000).formatted())
                                detail("应用", entry.app_id.map { AppIdentity.presentation($0).name } ?? "后台服务")
                                detail("事件", entry.event)
                                if let code = entry.code { detail("状态代码", code) }
                                detail("序号", String(entry.sequence))
                                Spacer()
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }.padding(18).frame(width: 230).background(EditorialStyle.canvas)
                }
            }.modifier(EditorialSurface()).frame(maxHeight: .infinity)
            HStack {
                if feature.value != nil { Text(("筛选结果" + "\n" + "\(filtered.count) 条结果 · 已载入 \(feature.value?.entries.count ?? 0) 条")).font(.caption).foregroundStyle(.secondary) }
                if let date = store.lastLogSuccess { Text("读取于 \(date.formatted(date: .omitted, time: .standard))").font(.caption).foregroundStyle(.secondary) }
                if feature.value?.truncated == true { Text("部分记录已过期").font(.caption).foregroundStyle(.orange) }
                Spacer()
                if store.logPaging.inFlight != nil { ProgressView().controlSize(.small) }
                else if store.logReadError != nil { Text(feature.value == nil ? "加载失败" : "刷新失败，显示上次结果").font(.caption).foregroundStyle(.orange); Button("重试") { store.requestLogPage(retry: true) }.disabled(store.snapshot == nil) }
                else if store.logPaging.reachedLimit { Text("已载入上限").font(.caption).foregroundStyle(.secondary) }
            }
            if let exportNotice { Text(exportNotice).font(.caption).foregroundStyle(.secondary) }
        }
        .onChange(of: search) { _, _ in
            if let selected, !filtered.contains(where: { $0.id == selected }) { self.selected = nil }
            if !search.isEmpty && filtered.isEmpty { store.requestLogPage() }
        }
        .onChange(of: level) { _, _ in selected = nil; store.resetLogs(level: level == "all" ? nil : level) }
        .onChange(of: selected) { _, value in if value != nil { logFocused = true } }
        .onChange(of: store.logPaging.page?.entries.count) { _, _ in
            if !search.isEmpty && filtered.isEmpty { store.requestLogPage() }
        }
        .fileExporter(isPresented: $exporting, document: MetadataLogDocument(data: exportData), contentType: .plainText, defaultFilename: "runtime-metadata.jsonl") { result in
            if case .failure = result { exportError = true }; exportData = Data()
        }
        .alert("导出失败", isPresented: $exportError) { Button("确定", role: .cancel) {} } message: { Text("请缩小筛选范围，或检查保存位置后重试。") }
    }
    private func detail(_ title: String, _ value: String) -> some View { VStack(alignment: .leading, spacing: 4) { Text(title).font(.caption).foregroundStyle(.secondary); Text(value).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) } }
    private var emptyTitle: String {
        if feature.value == nil { return store.logReadError == nil ? "读取中" : "读取失败" }
        return search.isEmpty && level == "all" ? "暂无记录" : "无匹配结果"
    }
    private var emptyDescription: String {
        if feature.value == nil { return store.logReadError == nil ? "请稍候" : "请重试读取" }
        return store.logReadError == nil ? "" : "显示上次成功读取的结果"
    }
    private func selectAdjacent(_ offset: Int) {
        guard !filtered.isEmpty else { return }
        let index = selected.flatMap { id in filtered.firstIndex { $0.id == id } } ?? -1
        selected = filtered[max(0, min(filtered.count - 1, index + offset))].id
    }
    private func levelTitle(_ level: String) -> String { level == "error" ? "错误" : level == "warning" ? "警告" : "信息" }
    private func levelColor(_ level: String) -> Color { level == "error" ? .red : level == "warning" ? .orange : EditorialStyle.graphite }
    private func exportRecent() {
        preparing = true
        Task {
            do { let export = try await store.service.exportLogs(); exportData = export.content; exportNotice = ("最近 15 分钟 · \(export.count) 条\(export.more || export.truncated ? " · 部分记录" : "")"); exporting = true }
            catch { exportError = true }
            preparing = false
        }
    }
}
