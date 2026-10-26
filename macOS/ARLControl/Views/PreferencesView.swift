import SwiftUI
import Darwin
import CryptoKit

struct PreferencesView: View {
    @AppStorage("refreshAutomatically") private var refresh = true
    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: EditorialStyle.sectionSpacing) {
            EditorialHeading(title: "偏好设置", subtitle: "")
            CodexPackagesPreferences()
            DetailCard(title: "状态更新") {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("自动刷新").font(.callout.weight(.medium))
                        Text("每 5 秒").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    Toggle("自动刷新", isOn: $refresh).labelsHidden().toggleStyle(.switch)
                        .accessibilityLabel("自动刷新")
                }
                Divider()
                HStack {
                    Text("手动刷新").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Text("⌘ R").font(.system(.caption, design: .monospaced).weight(.medium))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(EditorialStyle.canvas, in: RoundedRectangle(cornerRadius: 4))
                        .accessibilityLabel("Command R")
                }
            }
        }.padding(24)
        }.frame(width: 740, height: min(800, (NSScreen.main?.visibleFrame.height ?? 900) - 80))
            .background(EditorialStyle.canvas).tint(EditorialStyle.accent)
    }
}
struct StatusMenu: View {
    let store: RuntimeStore
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text(store.demo ? "ARL · 演示" : "ARL · \(store.title)")
        if let snapshot = store.snapshot { Text("待处理 \(snapshot.outstanding)") }
        Divider()
        Button("打开 ARL") { openWindow(id: "control"); NSApp.activate(ignoringOtherApps: true) }
        Button("刷新状态") { Task { await store.refresh() } }.keyboardShortcut("r")
        SettingsLink { Text("偏好设置") }
        Divider()
        Button("退出界面") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
    }
}

// NAS consumers share only owner-controlled, bounded model metadata and package
// configuration. No account credentials or execution grants are stored here.
private struct CodexPackageRow: Codable, Equatable {
    var display_name: String
    var model: String
    var reasoning_effort: String
}
private struct CodexPackagesFile: Codable {
    var schema_version: Int
    var revision: Int
    var catalog_version: String
    var packages: [String: CodexPackageRow]
}
private struct CodexPackagesCatalog: Codable {
    var schema_version: Int
    var catalog_version: String
    var models: [CodexExecutionModel]
    var current: CodexExecutionSelection
    var execution: CodexExecutionCatalog {
        .init(schema_version: 1, source: "app_server_model_list", models: models.map { .init(model: $0.model, display_name: $0.display_name, description: $0.description, default_effort: $0.default_effort, efforts: $0.efforts, fast_available: false, fast_description: "") }, selection_enabled: true, current: current)
    }
}
@MainActor private struct CodexPackagesPreferences: View {
    private let ids = ["low", "medium", "high", "very_high", "highest"]
    @State private var catalog: CodexPackagesCatalog?
    @State private var saved: CodexPackagesFile?
    @State private var draft: [String: CodexPackageRow] = [:]
    @State private var explicit: CodexExecutionSelection?
    @State private var message: String?
    private var home: URL { SettingsService.defaultHome.appendingPathComponent("CodexPackages") }
    private var valid: Bool {
        guard let catalog, Set(draft.keys) == Set(ids) else { return false }
        return draft.values.allSatisfy { !$0.display_name.isEmpty && $0.display_name.count <= 40 && catalog.execution.permits(.init(model: $0.model, reasoning_effort: $0.reasoning_effort, service_tier: "default")) }
    }
    private var changed: Bool { saved?.packages != draft }
    var body: some View {
        DetailCard(title: "Codex 应用套餐") {
            if let catalog, let saved {
                Text("每档可独立选择模型和思考强度。修改用于之后的新任务。")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(ids, id: \.self) { id in
                    if let row = draft[id] {
                        HStack(spacing: 12) {
                            TextField("套餐名称", text: Binding(get: { draft[id]?.display_name ?? "" }, set: { draft[id]?.display_name = $0 }))
                                .frame(width: 58).accessibilityLabel("\(id) 套餐名称")
                            Picker("模型", selection: Binding(get: { draft[id]?.model ?? "" }, set: { draft[id]?.model = $0 })) {
                                ForEach(catalog.models) { Text($0.display_name).tag($0.model) }
                            }.labelsHidden().accessibilityLabel("\(id) 套餐模型").frame(maxWidth: .infinity)
                            Picker("思考强度", selection: Binding(get: { draft[id]?.reasoning_effort ?? "" }, set: { draft[id]?.reasoning_effort = $0 })) {
                                let efforts = catalog.models.first { $0.model == row.model }?.efforts ?? []
                                if !efforts.contains(where: { $0.id == row.reasoning_effort }) {
                                    Text("请选择强度").tag(row.reasoning_effort)
                                }
                                ForEach(efforts) { Text($0.title).tag($0.id) }
                            }.labelsHidden().accessibilityLabel("\(id) 套餐思考强度").frame(width: 100)
                        }
                    }
                }
                HStack {
                    Button("保存五档套餐", action: save).disabled(!valid || !changed)
                    Button("重新读取", action: reload)
                    Spacer()
                    Text("版本 \(saved.revision)").font(.caption).foregroundStyle(.secondary)
                }
                if !valid { Text("请为每档选择当前模型支持的思考强度。").font(.caption).foregroundStyle(.orange) }
                Divider()
                Text("应用显式选型").font(.callout.weight(.medium))
                CodexExecutionSelector(catalog: catalog.execution, selection: explicit, disabled: false, choose: { value in
                    explicit = .init(model: value.model, reasoning_effort: value.reasoning_effort, service_tier: "default")
                })
                HStack {
                    Button("复制模型与强度选项", action: copyOption).disabled(explicit == nil)
                    Text("用于 PDF 翻译或 BiliNote 的模型栏").font(.caption).foregroundStyle(.secondary)
                }
                Text("只指定套餐：arl/package/medium；也可将 medium 换成 low、high、very_high 或 highest。")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Text("调用使用现有 Codex 账户额度，不设累计调用次数上限。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("等待 Codex 应用服务提供模型目录。").foregroundStyle(.secondary)
                Button("重新读取", action: reload)
            }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
        }.onAppear(perform: reload)
    }
    private func read<T: Decodable>(_ type: T.Type, name: String) throws -> T {
        try JSONDecoder().decode(type, from: RemindersNativeIO.privateFile(home.appendingPathComponent(name).path, limit: 131072))
    }
    private func reload() {
        do {
            let c = try read(CodexPackagesCatalog.self, name: "catalog-v2.json")
            let p = try read(CodexPackagesFile.self, name: "packages-v2.json")
            guard c.schema_version == 2, c.execution.isValid, p.schema_version == 2, p.revision > 0, Set(p.packages.keys) == Set(ids) else { throw ARLError(code: "package_configuration_invalid") }
            catalog = c; saved = p; draft = p.packages
            if explicit == nil { explicit = c.current }
            message = nil
        } catch { message = "暂时无法读取套餐配置，请检查 Codex 应用服务。" }
    }
    private func save() {
        guard valid, let saved, let catalog else { return }
        let path = home.appendingPathComponent("packages.lock").path
        let fd = Darwin.open(path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { message = "无法锁定套餐配置。"; return }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == geteuid(), info.st_mode & 0o077 == 0, flock(fd, LOCK_EX | LOCK_NB) == 0 else { message = "配置正在更新，请稍后保存。"; return }
        defer { flock(fd, LOCK_UN) }
        do {
            let current = try read(CodexPackagesFile.self, name: "packages-v2.json")
            let c = try read(CodexPackagesCatalog.self, name: "catalog-v2.json")
            guard current.revision == saved.revision, current.packages == saved.packages else { message = "套餐已被更新，请重新读取后修改。"; return }
            guard c.catalog_version == catalog.catalog_version else { message = "模型目录已更新，请重新读取。"; return }
            let next = CodexPackagesFile(schema_version: 2, revision: current.revision + 1, catalog_version: c.catalog_version, packages: draft)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(next)
            let target = home.appendingPathComponent("packages-v2.json")
            try data.write(to: target, options: .atomic)
            guard chmod(target.path, 0o600) == 0 else { throw ARLError(code: "package_permissions_invalid") }
            self.saved = next; message = "已保存，新任务将使用版本 \(next.revision)。"
        } catch { message = "保存失败，请重新读取后重试。" }
    }
    private func copyOption() {
        guard let explicit else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString("arl/option/" + explicit.model + "/" + explicit.reasoning_effort, forType: .string)
        message = "已复制 \(explicit.model) · \(CodexEffortOption.title(explicit.reasoning_effort))。"
    }
}
