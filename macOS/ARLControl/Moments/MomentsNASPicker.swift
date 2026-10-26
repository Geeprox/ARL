import SwiftUI
import ARLCredentialOnboarding

/// Browse real shares through ARL's saved server login. Selecting this location
/// grants only the Friday archive, independent of the general NAS read scope.
struct MomentsNASPicker: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: NASServerSetupModel
    @State private var choosing = false
    @State private var error: String?
    let owner: any NASArchivePickerOwner
    let selected: (NASArchiveDestination) -> Void
    init(owner: any NASArchivePickerOwner, selected: @escaping (NASArchiveDestination) -> Void) {
        self.owner = owner; self.selected = selected
        _model = StateObject(wrappedValue: NASServerSetupModel(owner: owner))
    }
    private func run(_ action: NASServerSetupAction) async {
        guard let intent = model.begin(action) else { error = "NAS 正在忙，请稍后重试。"; return }
        error = nil; await model.run(intent)
        if let fault = model.snapshot.fault {
            let stage: String
            switch action { case .login: stage = "服务器登录"; case .shares: stage = "共享列表"; default: stage = "目录读取" }
            error = stage + "未完成（" + (model.snapshot.diagnostic ?? fault.rawValue) + "）。"
        }
    }
    private func connect() async {
        await run(.login)
        if model.snapshot.state.authenticated { await run(.shares(cursor: nil)) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 7) {
                Text("选择 NAS 保存位置").font(.title2.bold())
                Text("使用 ARL 已保存的登录。归档存入所选位置下的 Friday 文件夹。")
                    .foregroundStyle(.secondary)
            }.padding(24)
            Divider()
            HStack(alignment: .top, spacing: 0) {
                List(selection: Binding(get: { model.snapshot.share }, set: { share in
                    if let share { Task { await run(.directory(share: share, path: "", cursor: nil)) } }
                })) {
                    Section(model.snapshot.address.isEmpty ? "共享" : model.snapshot.address) {
                        ForEach(model.snapshot.state.shares) { share in
                            Label(share.name, systemImage: "externaldrive").tag(share.name)
                        }
                        if let cursor = model.snapshot.state.nextCursor {
                            Button("更多共享") { Task { await run(.shares(cursor: cursor)) } }
                        }
                    }
                }.frame(width: 180).disabled(model.snapshot.busy || choosing)
                Divider()
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 6) {
                        if let share = model.snapshot.share, let page = model.snapshot.directory {
                            Button(share) { Task { await run(.directory(share: share, path: "", cursor: nil)) } }
                            ForEach(Array(page.path.split(separator: "/").enumerated()), id: \.offset) { index, part in
                                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                                Button(String(part)) {
                                    Task { await run(.directory(share: share, path: page.path.split(separator: "/").prefix(index + 1).joined(separator: "/"), cursor: nil)) }
                                }.lineLimit(1)
                            }
                        } else { Text("选择一个共享").foregroundStyle(.secondary) }
                        Spacer()
                    }.buttonStyle(.link).padding(16).disabled(model.snapshot.busy || choosing)
                    Divider()
                    if let page = model.snapshot.directory, let share = model.snapshot.share {
                        List {
                            if !page.path.isEmpty {
                                Button { Task { await run(.directory(share: share, path: page.path.split(separator: "/").dropLast().joined(separator: "/"), cursor: nil)) } }
                                    label: { Label("上一级", systemImage: "arrow.up") }
                            }
                            ForEach(page.directories.filter { path in
                                let name = path.split(separator: "/").last.map(String.init) ?? ""
                                return !name.hasPrefix(".") && name != "#recycle"
                            }, id: \.self) { path in
                                Button { Task { await run(.directory(share: share, path: path, cursor: nil)) } }
                                    label: { HStack { Label(path.split(separator: "/").last.map(String.init) ?? path, systemImage: "folder"); Spacer(); Image(systemName: "chevron.right").foregroundStyle(.tertiary) }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()) }
                            }
                            if page.directories.isEmpty { Text("此文件夹中没有子文件夹").foregroundStyle(.secondary) }
                            if let cursor = page.nextCursor { Button("更多文件夹") { Task { await run(.directory(share: share, path: page.path, cursor: cursor)) } } }
                        }.buttonStyle(.plain).disabled(model.snapshot.busy || choosing)
                    } else {
                        Spacer()
                        if model.snapshot.busy { ProgressView("正在连接 NAS…").frame(maxWidth: .infinity) }
                        else { Text(model.snapshot.saved ? "从左侧选择保存位置" : "请先在 NAS 设置中保存登录").foregroundStyle(.secondary).frame(maxWidth: .infinity) }
                        Spacer()
                    }
                }
            }.frame(height: 300)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                if let error { Text(error).foregroundStyle(.secondary).font(.callout) }
                HStack {
                    if let share = model.snapshot.share, let path = model.snapshot.directory?.path {
                        Text(share + (path.isEmpty ? "" : "/" + path) + "/Friday").font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    if model.snapshot.saved && !model.snapshot.state.authenticated {
                        Button("重新连接") { Task { await connect() } }.disabled(model.snapshot.busy)
                    }
                    Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("存到这里") {
                        choosing = true
                        Task {
                            defer { choosing = false }
                            do { let destination = try await owner.archiveDestination(); selected(destination); dismiss() }
                            catch { self.error = "位置已变化，请重新打开此文件夹。" }
                        }
                    }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                        .disabled(model.snapshot.directory == nil || model.snapshot.busy || choosing)
                }
            }.padding(20)
        }.frame(width: 720).task { if model.snapshot.saved { await connect() } }
    }
}
