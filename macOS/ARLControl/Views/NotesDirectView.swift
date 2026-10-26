import SwiftUI
import AppKit

struct NotesDirectView: View {
    let controller: NotesDirectController
    @State private var query = ""
    @State private var title = ""
    @State private var plaintext = ""
    @State private var editSource: NotesDirectEditorSource?
    @State private var editTitle = ""
    @State private var editText = ""
    @State private var draftID = UUID()
    var body: some View {
        DetailCard(title: "备忘录") {
            Text("在选定文件夹内查看和编辑。").font(.callout).foregroundStyle(.secondary)
            AppleConnectionActionsView(target: .notes, permission: controller.permission,
                enabled: controller.enabled, busy: controller.busy, observation: controller.connection.state,
                check: { Task { await controller.prepareForDisplay() } },
                request: { if let ticket = controller.ticket() { Task { await controller.checkPermission(ticket: ticket, request: true); await controller.prepareForDisplay() } } })
            Divider()
            if controller.permission == .authorized && controller.scope == nil {
                Text("请选择备忘录文件夹。").font(.callout).foregroundStyle(.secondary)
            }
            Button(controller.scope == nil ? "选文件夹" : "换文件夹") { if let ticket = controller.ticket() { Task { await controller.loadFolders(ticket: ticket) } } }
                .disabled(!controller.enabled || controller.busy || controller.permission != .authorized)
                .help("读取账户名称和顶层非共享文件夹，不读取笔记正文")
            ForEach(controller.folders) { folder in
                HStack {
                    Text(folder.label).font(.callout)
                    Spacer()
                    Button("选用目录") { if let ticket = controller.ticket() { Task { await controller.select(folder, ticket: ticket) } } }.disabled(controller.busy)
                }
            }
            if let scope = controller.scope {
                Text("当前范围：\(scope.folder.label)").font(.callout.bold())
                Text("每次操作前核对当前文件夹。").font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField("搜索标题", text: $query)
                    Button(query.isEmpty ? "列出笔记" : "查找笔记") { let exactQuery = query; if let ticket = controller.ticket() { Task { await controller.search(query: exactQuery, ticket: ticket) } } }
                }.disabled(controller.busy || !controller.scopeCurrent)
                if let result = controller.searchResult {
                    Text("检查 \(result.scanned) / \(result.total) 条 · 最多显示 50 条").font(.caption).foregroundStyle(.secondary)
                    if let next = result.next_offset {
                        Button("下一页") { let exactQuery = controller.searchQuery; if let ticket = controller.ticket() { Task { await controller.search(query: exactQuery, offset: next, ticket: ticket) } } }.disabled(controller.busy)
                    }
                    ForEach(result.notes) { row in
                        HStack {
                            Text(row.title).lineLimit(2)
                            Spacer()
                            Button("读取笔记") { if let ticket = controller.ticket() { Task { await controller.read(row, ticket: ticket) } } }.disabled(controller.busy)
                        }
                    }
                }
                if let result = controller.readResult {
                    Text(result.row.title).font(.headline)
                    if let next = result.next_offset {
                        Button("继续读取正文") { if let ticket=controller.ticket() {Task {await controller.read(result.row, offset: next, ticket: ticket)}} }.disabled(controller.busy)
                    }
                    if result.editableText != nil {
                        TextField("笔记标题", text: $editTitle).disabled(controller.busy)
                        TextEditor(text: $editText).frame(minHeight: 120).disabled(controller.busy)
                            .accessibilityLabel("编辑当前笔记正文")
                        Button("保存修改") {
                            guard let exactSource = editSource else { return }
                            let exactTitle = editTitle, exactText = editText
                            if let ticket = controller.ticket() { Task { await controller.update(source: exactSource, title: exactTitle, plaintext: exactText, ticket: ticket) } }
                        }.disabled(controller.busy || !controller.scopeCurrent || editTitle.isEmpty || editSource == nil || editSource != controller.editorSource)
                    } else {
                        ScrollView { Text(result.plaintext).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 260)
                        Text("格式或附件受保护，请到备忘录编辑。").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Divider()
                Text("新建笔记").font(.headline)
                TextField("标题", text: $title).disabled(controller.busy)
                TextEditor(text: $plaintext).frame(minHeight: 100).disabled(controller.busy)
                    .accessibilityLabel("新笔记全文")
                Button("新建笔记") {
                    let exactTitle = title, exactText = plaintext, exactDraftID = draftID
                    if let ticket = controller.ticket() {
                        Task { await controller.create(title: exactTitle, plaintext: exactText, draftID: exactDraftID, ticket: ticket) }
                    }
                }
                    .disabled(controller.busy || !controller.scopeCurrent || title.isEmpty || plaintext.isEmpty)
            }
            if controller.busy { HStack { ProgressView().controlSize(.small); Button("停止操作") { controller.cancel() } } }

            if !controller.businessLogAvailable { Text("业务日志写入失败，操作仍可继续。").font(.caption).foregroundStyle(.secondary) }
            if let message = controller.message { Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
            DisclosureGroup("连接详情") {
                Text("只访问当前选定的文件夹。")
                Text("共享、加密笔记不读取。")
                Text("富文本和附件正文保持只读。")
                Text("创建待核时不会自动重试。")
                if let detail = controller.detail { Text(detail).textSelection(.enabled) }
                if let id = controller.lastOperationID { Text("操作记录：" + id).textSelection(.enabled) }
            }.font(.caption).foregroundStyle(.secondary)
        }
        .task {
            controller.appear(); await controller.prepareForDisplay()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { break }
                await controller.prepareForDisplay()
            }
        }
        .onChange(of: controller.editorSource) {
            editSource = controller.editorSource
            editTitle = controller.readResult?.row.title ?? ""
            editText = controller.readResult?.editableText ?? ""
        }
        .onChange(of: controller.scope?.folder) { draftID = UUID() }
        .onChange(of: title) { draftID = UUID() }
        .onChange(of: plaintext) { draftID = UUID() }
        .onChange(of: controller.completedDraftID) {
            if controller.completedDraftID == draftID { title = ""; plaintext = ""; draftID = UUID() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await controller.prepareForDisplay() }
        }
        .onDisappear { controller.disappear() }
    }
}
