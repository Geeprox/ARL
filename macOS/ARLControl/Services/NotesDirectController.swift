import Foundation
import AppKit
import Observation

@MainActor @Observable final class NotesDirectController {
    let enabled: Bool
    private let home: URL
    private let executor: AppleDirectExecutor
    let connection: AppleStatusCoordinator<AppleDirectPermission>
    var permission: AppleDirectPermission { connection.state.value ?? .unknown }
    private let preferences: UserDefaults
    private let permissionCheck: @Sendable (Bool) throws -> AppleDirectPermission
    private let prepareTarget: @MainActor (AppleDirectCancellation) async throws -> Void
    private(set) var folders: [NotesDirectFolder] = []
    private(set) var scope: NotesDirectScope?
    private(set) var searchQuery = ""
    private(set) var searchResult: NotesDirectSearch?
    private(set) var readResult: NotesDirectRead?
    private(set) var lastOperationID: String?
    private(set) var busy = false
    private(set) var actionAdmissionHeld = false
    private(set) var message: String?
    private(set) var detail: String?
    private(set) var businessLogAvailable = true
    private var consumedDraftIDs = Set<UUID>()
    private(set) var completedDraftID: UUID?
    private var cancellation: AppleDirectCancellation?
    private var page = NotesDirectPageState()
    private var generation: UUID { page.epoch }
    init(home: URL, enabled: Bool, executor: AppleDirectExecutor,
         preferences: UserDefaults = .standard, startAutomatically: Bool = true,
         permissionCheck: @escaping @Sendable (Bool) throws -> AppleDirectPermission = {
             try AppleDirectAuthorization.permission(target: .notes, ask: $0)
         },
         prepareTarget: @escaping @MainActor (AppleDirectCancellation) async throws -> Void = {
             try await AppleDirectAuthorization.prepareForUserAction(.notes, stop: $0)
         }) {
        self.home = home; self.enabled = enabled; self.executor = executor
        self.preferences = preferences; self.permissionCheck = permissionCheck; self.prepareTarget = prepareTarget
        connection = AppleDirectStatus.make(target: .notes, enabled: enabled, executor: executor,
            preferences: preferences, startAutomatically: startAutomatically, check: permissionCheck)
        // Display preference only; every effect revalidates the exact folder.
        if enabled, let data = preferences.data(forKey: "notesDirectSelectedFolderV1"), data.count <= 8192,
           let folder = try? JSONDecoder().decode(NotesDirectFolder.self, from: data), (try? folder.validate()) != nil {
            scope = .init(folder: folder, expires: Date().addingTimeInterval(600))
        }
    }
    var scopeCurrent: Bool { scope != nil && permission == .authorized }
    var editorSource: NotesDirectEditorSource? {
        guard let scope, let readResult else { return nil }
        return readResult.editorSource(folder: scope.folder)
    }
    private func actionScope(_ ticket: NotesDirectActionTicket) throws -> NotesDirectScope {
        try page.validate(ticket, currentFolder: scope?.folder)
        guard let selected = ticket.folder else { throw AppleDirectFault("scope_expired") }
        // Renew only the operation deadline, never the chosen folder. The user
        // is looking at this target and clicking the actual read/create action.
        let value = NotesDirectScope(folder: selected, expires: Date().addingTimeInterval(600))
        try value.validate(); scope = value; return value
    }
    func ticket() -> NotesDirectActionTicket? {
        guard enabled, !actionAdmissionHeld, !busy, NSApplication.shared.isActive else { return nil }
        return page.ticket(folder: scope?.folder)
    }
    private func begin(_ ticket: NotesDirectActionTicket) throws -> (AppleDirectCancellation, UUID) {
        try page.validate(ticket, currentFolder: scope?.folder)
        guard enabled, !actionAdmissionHeld, !busy, NSApplication.shared.isActive else { throw AppleDirectFault("user_action_unavailable") }
        let stop = AppleDirectCancellation(); cancellation = stop; busy = true
        return (stop, generation)
    }
    private func end() { busy = false; cancellation = nil }
    func suspendForExit() { actionAdmissionHeld = true; invalidate(); connection.pause() }
    func resumeAfterCancelledExit() { actionAdmissionHeld = false; connection.resume() }
    func finishExit() { actionAdmissionHeld = true; connection.stop() }
    private func failure(_ error: Error) {
        if (error as? AppleDirectFault)?.businessLogAvailable==false {businessLogAvailable=false}
        let code = (error as? AppleDirectFault)?.code ?? "operation_unavailable"
        detail = (error as? AppleDirectFault)?.diagnostic ?? code
        switch code {
        case "invalid_text":
            let step = (error as? AppleDirectFault)?.step
            message = step == .notesAccountName || step == .notesFolderName ? "目录名称不可用，请查看详情。" : "请核对填写内容。"
        case "owner_not_ready": message = "当前连接不可用，请检查安装。"
        case "open_target_application": message = "备忘录暂未运行，请打开后继续。"
        case "needs_permission":
            Task { await connection.refresh(force: true) }
            message = "自动化权限未获允许，请连接授权或前往系统设置。"
        case "scope_expired", "request_expired", "proposal_expired": message = "操作已过期，请在原目录重试。"
        case "target_required": message = "请选择备忘录文件夹。"
        case "editor_source_changed": message = "编辑来源已变，请重新读取。"
        case "draft_already_submitted": message = "已提交，请修改内容后再操作。"
        case "attachments_read_only", "rich_text_read_only": message = "含格式或附件，请到备忘录编辑。"
        case "revision_changed", "target_changed", "note_moved_locked_or_shared": searchResult = nil; readResult = nil; message = "笔记已变化，请重新列出并读取。"
        case "previous_create_unconfirmed", "journal_needs_review", "journal_missing_or_replaced":
            message = "上次创建待核，请到备忘录查看。"
        case "cancelled": message = "本次操作已停止。"
        default: message = "操作未完成，请检查权限后再试。"
        }
    }
    func invalidate() {
        cancellation?.cancel(); page.cancel()
        searchResult = nil; readResult = nil; folders = []
    }
    func appear() { page.appear() }
    func disappear() { invalidate(); page.disappear() }
    func cancel() {
        invalidate()
        message = "后续已停，已提交的创建无法撤回。"
    }
    func refreshStatus() async { await connection.refresh(force: true) }
    func prepareForDisplay() async {
        await connection.refresh()
        guard permission == .authorized, scope == nil, folders.isEmpty,
              !NSRunningApplication.runningApplications(withBundleIdentifier: AppleDirectTarget.notes.identifier).isEmpty,
              let ticket = ticket() else { return }
        // Visible-page metadata only. A race with app termination must not launch it.
        await loadFolders(ticket: ticket, openTarget: false)
    }
    func checkPermission(ticket: NotesDirectActionTicket, request: Bool = false) async {
        guard request else { await refreshStatus(); return }
        do {
            guard permission == .notDetermined || (permission == .unknown && connection.state.lastFailure?.issue == .targetNotRunning) else { return }
            detail = nil
            let (stop, epoch) = try begin(ticket); defer { end(); if !actionAdmissionHeld { connection.resume() } }
            connection.pause()
            try await prepareTarget(stop)
            let check = permissionCheck
            let value = try await executor.run { try AppleDirectAuthorization.requestIfNeeded(stop: stop, check: check) }
            guard epoch == generation, !actionAdmissionHeld else { return }
            guard value != .unknown else { throw AppleDirectFault("permission_unknown") }
            connection.accept(value)
            message = value == .authorized ? "已授权，可查看目录。" : "请在系统设置中核对 ARL 的自动化权限。"
        } catch { failure(error) }
    }
    func loadFolders(ticket: NotesDirectActionTicket, openTarget: Bool = true) async {
        do {
            let (stop, epoch) = try begin(ticket); defer { end() }
            if openTarget { try await prepareTarget(stop) }
            searchResult = nil; readResult = nil; folders = []
            let journalHome = home
            let reply = try await executor.run {
                let session = try AppleDirectSession(target: .notes, stop: stop, expires: Date().addingTimeInterval(30))
                return try NotesDirectHandler(home: journalHome, backend: NotesDirectBackend(session: session)).handle(.folders)
            }
            guard epoch == generation else { return }
            guard case let .folders(values) = reply.result else { throw AppleDirectFault("invalid_response") }
            businessLogAvailable = reply.businessLogAvailable
            folders = values
            message = values.isEmpty ? "没有可用目录，请到备忘录查看。" : "请选择目录，尚未读取笔记。"
        } catch { failure(error) }
    }
    func select(_ folder: NotesDirectFolder, ticket: NotesDirectActionTicket) async {
        do {
            guard folders.contains(folder) else { throw AppleDirectFault("target_changed") }
            let (stop, epoch) = try begin(ticket); defer { end() }
            try await prepareTarget(stop)
            let candidate = NotesDirectScope(folder: folder, expires: Date().addingTimeInterval(600))
            try await executor.run {
                let session = try AppleDirectSession(target: .notes, stop: stop, expires: candidate.expires)
                try NotesDirectBackend(session: session).verify(candidate)
            }
            guard epoch == generation else { return }
            scope = candidate; searchResult = nil; readResult = nil
            preferences.set(try JSONEncoder().encode(folder), forKey: "notesDirectSelectedFolderV1")
            message = "目录已选定，可查找或新建笔记。"
        } catch { failure(error) }
    }
    func search(query: String, offset: Int = 0, ticket: NotesDirectActionTicket) async {
        do {
            let value = try actionScope(ticket)
            try value.validate(); if !query.isEmpty { try NotesDirectContract.text(query, maximum: 1024) }
            let (stop, epoch) = try begin(ticket); defer { end() }
            try await prepareTarget(stop)
            searchResult = nil; readResult = nil
            let journalHome = home
            let reply = try await executor.run {
                let session = try AppleDirectSession(target: .notes, stop: stop, expires: value.expires)
                return try NotesDirectHandler(home: journalHome, backend: NotesDirectBackend(session: session), selectedFolder: value.folder)
                    .handle(.page(scope: value, query: query, offset: offset, limit: 50))
            }
            guard epoch == generation else { return }
            guard case let .search(result) = reply.result else { throw AppleDirectFault("invalid_response") }
            businessLogAvailable = reply.businessLogAvailable
            searchQuery = query
            searchResult = result
            message = "已检查 \(result.scanned) / \(result.total) 条，找到 \(result.notes.count) 条；只搜索标题，跳过共享或加密笔记。" +
                (result.next_offset != nil ? "可继续下一页。" : "")
        } catch { failure(error) }
    }
    func read(_ row: NotesDirectRow, offset: Int = 0, ticket: NotesDirectActionTicket) async {
        do {
            guard searchResult?.notes.contains(row) == true else { throw AppleDirectFault("target_changed") }
            let value = try actionScope(ticket)
            let (stop, epoch) = try begin(ticket); defer { end() }
            try await prepareTarget(stop)
            readResult = nil
            let journalHome = home
            let reply = try await executor.run {
                let session = try AppleDirectSession(target: .notes, stop: stop, expires: value.expires)
                return try NotesDirectHandler(home: journalHome, backend: NotesDirectBackend(session: session), selectedFolder: value.folder).handle(.readPage(scope: value, row: row, offset: offset, maxBytes: 65536))
            }
            guard epoch == generation else { return }
            guard case let .read(result) = reply.result else { throw AppleDirectFault("invalid_response") }
            businessLogAvailable = reply.businessLogAvailable
            readResult = result; message = "正文已读取，未读取附件。"
        } catch { failure(error) }
    }
    // The visible editor is the review surface. One New Note button freezes
    // its displayed target/title/full text and submits exactly this intent.
    func create(title: String, plaintext: String, draftID: UUID = UUID(), ticket: NotesDirectActionTicket) async {
        do {
            guard !consumedDraftIDs.contains(draftID) else { throw AppleDirectFault("draft_already_submitted") }
            let value = try actionScope(ticket)
            let approved = NotesDirectProposal(id: draftID, scope: value, title: title, plaintext: plaintext,
                expires: Date().addingTimeInterval(120))
            try approved.validate()
            let (stop, epoch) = try begin(ticket); defer { end() }
            try await prepareTarget(stop)
            lastOperationID = approved.id.uuidString.lowercased()
            let journalHome = home
            let reply = try await executor.run {
                let session = try AppleDirectSession(target: .notes, stop: stop, expires: approved.expires)
                return try NotesDirectHandler(home: journalHome, backend: NotesDirectBackend(session: session), selectedFolder: approved.scope.folder)
                    .handle(.create(proposal: approved, expectedDigest: approved.digest))
            }
            consumedDraftIDs.insert(draftID); completedDraftID = draftID
            businessLogAvailable = reply.businessLogAvailable
            guard epoch == generation else { return }
            searchResult = nil; readResult = nil
            message = "新建已核对，云端同步待检查。"
        } catch let error as NotesDirectCreateFault {
            if error.businessLogAvailable==false {businessLogAvailable=false}
            if error.consumed { consumedDraftIDs.insert(draftID) }
            detail = error.code
            message = error.consumed ? "结果待核，请到备忘录查看。" : "创建未开始，请核对目录和全文。"
        } catch { failure(error) }
    }
    func update(source: NotesDirectEditorSource, title: String, plaintext: String, ticket: NotesDirectActionTicket) async {
        do {
            let value = try actionScope(ticket)
            let approved = try NotesDirectEditProposal.fromEditor(scope: value, source: source, currentSource: editorSource,
                title: title, plaintext: plaintext, expires: Date().addingTimeInterval(120))
            let (stop, epoch) = try begin(ticket); defer { end() }
            try await prepareTarget(stop)
            lastOperationID = approved.id.uuidString.lowercased()
            let journalHome = home
            let reply = try await executor.run {
                let session = try AppleDirectSession(target: .notes, stop: stop, expires: approved.expires)
                return try NotesDirectHandler(home: journalHome, backend: NotesDirectBackend(session: session), selectedFolder: approved.scope.folder)
                    .handle(.update(proposal: approved, expectedDigest: approved.digest))
            }
            businessLogAvailable = reply.businessLogAvailable
            guard epoch == generation else { return }
            readResult = nil; searchResult = nil
            message = "修改已核对，云端同步待检查。"
        } catch let error as NotesDirectCreateFault {
            if error.businessLogAvailable==false {businessLogAvailable=false}
            // A consumed edit snapshot cannot be used for another submission.
            if error.consumed { readResult = nil; searchResult = nil }
            detail = error.code
            message = error.consumed ? "结果待核，请到备忘录查看。" : "修改未开始，请重新读取。"
        } catch { failure(error) }
    }

}
