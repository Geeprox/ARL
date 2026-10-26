import SwiftUI

/// File actions use RuntimeStore's same owner boundary as Mio. No endpoint or
/// credential inputs, automatic body reads, recursive scans or background retry.
@MainActor struct NASFileBrowserView: View {
    let execute: @MainActor (String, Data, UUID) async throws -> Data
    @State private var keyword = ""
    @State private var rows: [NASFileBrowserEntry] = []
    @State private var scope: NASFileBrowserScope?
    @State private var selected: NASFileBrowserEntry?
    @State private var directory: String?
    @State private var nextCursor: String?
    @State private var pageTool = "mio_nas_list"
    @State private var pageArguments: [String: Any] = [:]
    @State private var offset = "0"
    @State private var length = 65536
    @State private var rawResult = ""
    @State private var detail = "选择已授权目录后，可以列出文件或按文件名查找。"
    @State private var busy = false
    @State private var pageTask = NASFilePageTaskHandle()
    @State private var generation = UUID()

    var body: some View {
        DetailCard(title: "目录与文件") {
            HStack {
                TextField("文件名", text: $keyword)
                Button("查找") { page(search: true) }.disabled(keyword.isEmpty || busy)
                Button("列出文件") { page(search: false) }.disabled(busy)
            }
            if let scope { Text(scope.location).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            if directory != nil { Button("返回选定根目录") { directory = nil; page(search: false) }.disabled(busy) }
            Text(detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            ForEach(rows) { row in
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: row.kind == "directory" ? "folder" : "doc")
                    VStack(alignment: .leading, spacing: 3) {
                        Text(row.path).textSelection(.enabled)
                        Text(row.kind == "directory" ? "目录" : "\(row.size) 字节").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if row.kind == "directory" {
                        Button("打开目录") { directory = row.id; page(search: false) }.disabled(busy)
                    } else {
                        Button(selected?.id == row.id ? "已选择" : "选择文件") { selected = row; offset = "0" }.disabled(busy)
                    }
                }
            }
            if let nextCursor {
                Button("继续列出") {
                    var args = pageArguments; args["cursor"] = nextCursor
                    launch(tool: pageTool, arguments: args, isPage: true)
                }.disabled(busy)
            }
            if let selected {
                Divider()
                Text(selected.path).font(.callout).textSelection(.enabled)
                HStack {
                    TextField("起始字节", text: $offset).frame(maxWidth: 140)
                    Picker("读取长度", selection: $length) {
                        Text("16 KiB").tag(16384); Text("64 KiB").tag(65536); Text("128 KiB").tag(131072)
                    }.frame(maxWidth: 220)
                    Button("读取这一段") { read(selected) }.disabled(busy || Int(offset) == nil || (Int(offset) ?? -1) < 0)
                }
            }
            if busy { Button("停止本次操作") { pageTask.stop() } }
            if !rawResult.isEmpty {
                DisclosureGroup("原始结果") {
                    ScrollView([.horizontal, .vertical]) { Text(rawResult).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }.frame(maxHeight: 260)
                }
            }
        }.onDisappear {
            generation = UUID(); pageTask.leave(); busy = false
            // Navigation invalidates display only. The same owner retains the
            // accepted finite operation; explicit Stop still closes/drains it.
        }
    }
    private func page(search: Bool) {
        var args: [String: Any] = ["limit": 16]
        if let directory { args["directory_ref"] = directory }
        if search { args["keyword"] = keyword }
        pageTool = search ? "mio_nas_search" : "mio_nas_list"; pageArguments = args
        selected = nil; nextCursor = nil
        launch(tool: pageTool, arguments: args, isPage: true)
    }
    private func read(_ entry: NASFileBrowserEntry) {
        guard let scope, let start = Int(offset), start >= 0 else { return }
        launch(tool: "mio_nas_read", arguments: ["source_ref": scope.source, "config_generation": scope.generation,
            "connection_epoch": scope.epoch, "object_ref": entry.id, "revision": entry.revision,
            "offset": start, "length": length], isPage: false)
    }
    private func launch(tool: String, arguments: [String: Any], isPage: Bool) {
        guard !busy else { return }
        let token = UUID(); generation = token; busy = true
        pageTask.track(Task { @MainActor in
            defer { if generation == token { busy = false; pageTask.finish() } }
            do {
                let input = try OwnerReadWire.encode(arguments, limit: OwnerReadWire.requestLimit)
                let bytes = try await execute(tool, input, UUID())
                try Task.checkCancellation()
                guard generation == token else { return }
                rawResult = String(decoding: bytes, as: UTF8.self)
                let value = try OwnerReadJSON.object(bytes, limit: 196608, maximumDepth: 32)
                if let error = value["error"] as? [String: Any] {
                    detail = error["code"] as? String ?? "nas_unavailable"
                    if isPage { rows = []; nextCursor = nil; selected = nil }
                    return
                }
                if isPage {
                    scope = try NASFileBrowserScope(value)
                    rows = try (value["entries"] as? [[String: Any]] ?? []).map(NASFileBrowserEntry.init)
                    nextCursor = value["next_cursor"] as? String
                    let partial = value["partial"] as? Bool == true
                    detail = "本页 \(rows.count) 项" + (partial ? " · 尚未扫描完整目录" : "")
                        + ((value["stopped_reason"] as? String).map { " · " + $0 } ?? "")
                } else {
                    let count = NASCapability.integer(value["bytes_read"]) ?? 0
                    detail = "已返回 \(count) 个原始字节" + (value["eof"] as? Bool == true ? " · 已到文件末尾" : "")
                }
            } catch {
                guard generation == token else { return }
                detail = error is CancellationError ? "本次操作已停止。" : NASFileExecutor.code(error)
            }
        })
    }
}
private struct NASFileBrowserScope {
    let source: String, epoch: String, location: String
    let generation: Int
    init(_ value: [String: Any]) throws {
        guard let source = value["source_ref"] as? String, let epoch = value["connection_epoch"] as? String,
              let generation = NASCapability.integer(value["config_generation"]), let at = value["location"] as? [String: Any],
              let host = at["host"] as? String, let port = NASCapability.integer(at["port"]),
              let share = at["share"] as? String, let root = at["root"] as? String else { throw OwnerReadFault.invalid }
        self.source = source; self.epoch = epoch; self.generation = generation
        location = "\(host):\(port) / \(share)" + (root.isEmpty ? "" : " / " + root)
    }
}
private struct NASFileBrowserEntry: Identifiable {
    let id: String, kind: String, path: String, revision: String
    let size: Int
    init(_ value: [String: Any]) throws {
        guard let id = value["object_ref"] as? String, let kind = value["kind"] as? String,
              let path = value["path"] as? String, let revision = value["revision"] as? String,
              let size = NASCapability.integer(value["size"]) else { throw OwnerReadFault.invalid }
        self.id = id; self.kind = kind; self.path = path; self.revision = revision; self.size = size
    }
}
