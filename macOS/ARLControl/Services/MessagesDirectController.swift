import Foundation
import AppKit
import Observation
import CryptoKit

@MainActor @Observable final class MessagesDirectController {
    let enabled: Bool
    private let home: URL
    private let executor: AppleDirectExecutor
    private var page = MessagesDirectPageState()
    private var cancellation: AppleDirectCancellation?
    let connection: AppleStatusCoordinator<AppleDirectPermission>
    var permission: AppleDirectPermission { connection.state.value ?? .unknown }
    private let preferences: UserDefaults
    private let permissionCheck: @Sendable (Bool) throws -> AppleDirectPermission
    private let prepareTarget: @MainActor (AppleDirectCancellation) async throws -> Void
    private(set) var accounts: [MessagesDirectAccount] = []
    private(set) var accountScan: MessagesDirectAccountScan?
    private(set) var lastAccountScan: MessagesDirectAccountScan?
    private(set) var accountObservedAt: Date?
    var accountScanIsStale: Bool { accountScan == nil && lastAccountScan != nil }
    private(set) var actionAdmissionHeld = false
    private var consumedDraftIDs = Set<UUID>()
    private(set) var lastTerminal: MessagesDirectTerminal?
    private(set) var selectedAccount: MessagesDirectAccount?
    private(set) var recipient: MessagesDirectRecipient?
    private(set) var chats: MessagesDirectChatPage?
    private(set) var businessLogAvailable = true
    private(set) var busy = false
    private(set) var message: String?
    private(set) var detail: String?
    private(set) var lastOperationID: String?
    private(set) var lastAcceptedID: UUID?
    init(home: URL, enabled: Bool, executor: AppleDirectExecutor,
         preferences: UserDefaults = .standard, startAutomatically: Bool = true,
         permissionCheck: @escaping @Sendable (Bool) throws -> AppleDirectPermission = {
             try AppleDirectAuthorization.permission(target: .messages, ask: $0)
         },
         prepareTarget: @escaping @MainActor (AppleDirectCancellation) async throws -> Void = {
             try await AppleDirectAuthorization.prepareForUserAction(.messages, stop: $0)
         }) {
        self.home = home; self.enabled = enabled; self.executor = executor
        self.preferences = preferences; self.permissionCheck = permissionCheck; self.prepareTarget = prepareTarget
        connection = AppleDirectStatus.make(target: .messages, enabled: enabled, executor: executor,
            preferences: preferences, startAutomatically: startAutomatically, check: permissionCheck)
    }
    func appear() { page.appear() }
    func disappear() {
        cancellation?.cancel(); page.disappear()
        clearCurrentAccounts()
    }
    func ticket() -> MessagesDirectTicket? {
        guard enabled, !actionAdmissionHeld, !busy, NSApplication.shared.isActive else { return nil }
        return page.ticket(account: selectedAccount, recipient: recipient)
    }
    private func begin(_ ticket: MessagesDirectTicket) throws -> (AppleDirectCancellation, UUID) {
        try page.validate(ticket, account: selectedAccount, recipient: recipient)
        guard enabled, !actionAdmissionHeld, !busy, NSApplication.shared.isActive else { throw AppleDirectFault("user_action_unavailable") }
        let stop = AppleDirectCancellation(); cancellation = stop; busy = true
        return (stop, page.epoch)
    }
    private func end() { busy = false; cancellation = nil }
    private func clearCurrentAccounts() {
        accounts = []; accountScan = nil; selectedAccount = nil; recipient = nil; chats = nil
    }
    func canSubmitDraft(_ id: UUID) -> Bool {
        !actionAdmissionHeld && !consumedDraftIDs.contains(id) && accountScan != nil && selectedAccount != nil
    }
    func suspendForExit() {
        actionAdmissionHeld = true; cancellation?.cancel(); page.invalidate(); clearCurrentAccounts()
        connection.pause()
    }
    func resumeAfterCancelledExit() { actionAdmissionHeld = false; connection.resume() }
    func finishExit() { actionAdmissionHeld = true; connection.stop() }
    func targetEdited() { cancellation?.cancel(); page.invalidate(); recipient = nil }
    func select(_ value: MessagesDirectAccount) {
        guard let intent = ticket(), accounts.contains(value),
              (try? page.validate(intent, account: selectedAccount, recipient: recipient)) != nil else { return }
        page.invalidate(); selectedAccount = value; recipient = nil; chats = nil
        preferences.set(value.id, forKey: "messagesDirectSelectedAccountV1")
    }
    func cancel() {
        cancellation?.cancel(); page.invalidate(); recipient = nil
        message = "后续已停，已提交的信息无法撤回。"
    }
    private func failure(_ error: Error) {
        if (error as? AppleDirectFault)?.businessLogAvailable==false {businessLogAvailable=false}
        let code = (error as? AppleDirectFault)?.code ?? "operation_unavailable"
        detail = (error as? AppleDirectFault)?.diagnostic ?? code
        switch code {
        case "owner_not_ready": message = "当前连接不可用，请检查安装。"
        case "open_target_application": message = "信息暂未运行，请打开后继续。"
        case "needs_permission":
            Task { await connection.refresh(force: true) }
            message = "自动化权限未获允许，请连接授权或前往系统设置。"
        case "target_required", "account_required": message = "请选择已有的发送账号。"
        case "draft_already_submitted": message = "这份草稿已经提交，请查看发送结果或填写新内容。"
        case "explicit_email_required", "explicit_address_required": message = "请填单个邮箱或国际格式手机号。"
        case "recipient_not_unique", "target_not_found": recipient = nil; message = "邮箱未匹配，请核对地址后再试。"
        case "account_changed", "recipient_changed", "recipient_expired": recipient = nil; message = "账户或邮箱已变化，请重新核对。"
        case "previous_send_unconfirmed", "journal_needs_review", "journal_missing_or_replaced":
            message = "原发送结果待核，新草稿可继续。"
        case "cancelled", "user_action_expired": message = "本次已停，请重新检查连接。"
        default: message = "操作未完成，请检查连接后再试。"
        }
    }
    func refreshStatus() async { await connection.refresh(force: true) }
    func prepareForDisplay() async {
        await connection.refresh()
        guard permission == .authorized,
              accountObservedAt.map({ Date().timeIntervalSince($0) >= 60 }) ?? true,
              !NSRunningApplication.runningApplications(withBundleIdentifier: AppleDirectTarget.messages.identifier).isEmpty,
              let ticket = ticket() else { return }
        await loadAccounts(ticket: ticket, openTarget: false)
    }
    func checkConnection(ticket: MessagesDirectTicket) async {
        await refreshStatus()
        guard permission == .authorized,
              (try? page.validate(ticket, account: selectedAccount, recipient: recipient)) != nil,
              let next = self.ticket() else { return }
        await loadAccounts(ticket: next)
    }
    @discardableResult
    func checkPermission(ticket: MessagesDirectTicket, request: Bool = false) async -> Bool {
        guard request else { await refreshStatus(); return permission == .authorized }
        do {
            guard permission == .notDetermined || (permission == .unknown && connection.state.lastFailure?.issue == .targetNotRunning) else { return false }
            let (stop, epoch) = try begin(ticket); defer { end(); if !actionAdmissionHeld { connection.resume() } }
            connection.pause(); detail = nil
            try await prepareTarget(stop)
            let check = permissionCheck
            let value = try await executor.run { try AppleDirectAuthorization.requestIfNeeded(stop: stop, check: check) }
            guard epoch == page.epoch, !actionAdmissionHeld else { return false }
            guard value != .unknown else { throw AppleDirectFault("permission_unknown") }
            connection.accept(value)
            if value != .authorized { recipient = nil; page.invalidate() }
            message = value == .authorized ? "已授权，可选择发送账户。" : "请在系统设置中核对 ARL 的自动化权限。"
            return true
        } catch { failure(error); return false }
    }
    func loadAccounts(ticket: MessagesDirectTicket, openTarget: Bool = true) async {
        do {
            let (stop, epoch) = try begin(ticket); defer { end() }
            clearCurrentAccounts()
            if openTarget { try await prepareTarget(stop) }
            let journalHome = home
            let reply = try await executor.run {
                let session = try AppleDirectSession(target: .messages, stop: stop, expires: Date().addingTimeInterval(30))
                return try MessagesDirectHandler(home: journalHome, backend: MessagesDirectBackend(session: session)).handle(.accounts)
            }
            guard epoch == page.epoch else { return }
            guard case let .accounts(values) = reply.result else { throw AppleDirectFault("invalid_response") }
            businessLogAvailable = reply.businessLogAvailable
            let preferred = preferences.string(forKey: "messagesDirectSelectedAccountV1")
            accounts = values.accounts; accountScan = values; lastAccountScan = values; accountObservedAt = Date()
            selectedAccount = values.accounts.first { $0.id == preferred }
            recipient = nil; page.invalidate()
            if !values.failures.isEmpty { message = "部分账户读取失败，请查看详情。" }
            else { message = values.accounts.isEmpty ? "没有可用账户，请检查系统信息。" : selectedAccount == nil ? "请选择发送账号，填写邮箱和全文即可发送。" : "发送账号已恢复，可填写邮箱和全文。" }
        } catch {
            clearCurrentAccounts(); page.invalidate()
            failure(error)
        }
    }
    func checkRecipient(email: String, ticket: MessagesDirectTicket) async {
        do {
            try MessagesDirectContract.address(email)
            guard let account = ticket.account else { throw AppleDirectFault("account_required") }
            let (stop, epoch) = try begin(ticket); defer { end() }
            try await prepareTarget(stop)
            let value = try await executor.run {
                let session = try AppleDirectSession(target: .messages, stop: stop, expires: Date().addingTimeInterval(30))
                return try MessagesDirectBackend(session: session).recipient(account: account, email: email)
            }
            guard epoch == page.epoch else { return }
            recipient = value; page.invalidate()
            message = "邮箱已核对，请确认全文。"
        } catch { failure(error) }
    }
    func send(plaintext: String, email: String, draftID: UUID, ticket: MessagesDirectTicket) async {
        var submittedDraft: MessagesDirectDraftIdentity?
        var operationID: UUID?
        do {
            guard !consumedDraftIDs.contains(draftID) else { throw AppleDirectFault("draft_already_submitted") }
            guard accountScan != nil, let account = ticket.account, accounts.contains(account) else { throw AppleDirectFault("account_required") }
            try MessagesDirectContract.address(email)
            try MessagesDirectContract.text(plaintext, maximum: 8192, multiline: true)
            let (stop, epoch) = try begin(ticket); defer { end() }
            try await prepareTarget(stop)
            let id = draftID, journalHome = home
            let draft = MessagesDirectDraftIdentity(id: draftID, account: account, email: email, plaintext: plaintext)
            operationID = id; submittedDraft = draft
            lastOperationID = id.uuidString.lowercased()
            let reply = try await executor.run {
                let session = try AppleDirectSession(target: .messages, stop: stop, expires: Date().addingTimeInterval(120))
                let handler = MessagesDirectHandler(home: journalHome, backend: MessagesDirectBackend(session: session), selectedAccount: account)
                let prepared = try handler.handle(.prepareSend(id: id, account: account, address: email, plaintext: plaintext))
                guard case let .prepared(proposal) = prepared.result else { throw AppleDirectFault("invalid_response") }
                return try handler.handle(.send(proposal: proposal, expectedDigest: proposal.digest))
            }
            // Accepted/consumed is an operation fact, independent of page life.
            businessLogAvailable = reply.businessLogAvailable
            consumedDraftIDs.insert(draftID)
            lastAcceptedID = id
            lastTerminal = .init(operationID: id, draft: draft, outcome: .accepted)
            if epoch == page.epoch { recipient = nil; page.invalidate() }
            message = "系统已接受，送达请在信息查看。"
        } catch let error as MessagesDirectSendFault {
            if error.businessLogAvailable==false {businessLogAvailable=false}
            if error.consumed {
                consumedDraftIDs.insert(draftID)
                if let operationID, let submittedDraft {
                    lastTerminal = .init(operationID: operationID, draft: submittedDraft, outcome: .unknown)
                }
            }
            detail = error.code
            message = error.consumed ? "结果待核，请到系统信息查看。" : "发送未开始，请核对连接和全文。"
        } catch { failure(error) }
    }
    func loadChats(query: String, ticket: MessagesDirectTicket) async {
        do {
            guard let account = selectedAccount, accountScan != nil else { throw AppleDirectFault("account_required") }
            let (stop, epoch) = try begin(ticket); defer { end() }
            try await prepareTarget(stop)
            let journalHome = home
            let reply = try await executor.run {
                let session = try AppleDirectSession(target: .messages, stop: stop, expires: Date().addingTimeInterval(30))
                return try MessagesDirectHandler(home: journalHome, backend: MessagesDirectBackend(session: session), selectedAccount: account)
                    .handle(.chats(account: account, query: query))
            }
            guard epoch == page.epoch else { return }
            guard case let .chats(result) = reply.result else { throw AppleDirectFault("invalid_response") }
            businessLogAvailable = reply.businessLogAvailable; chats = result
            message = "已检查 \(result.scanned) / \(result.total) 个会话。"
        } catch { chats = nil; failure(error) }
    }

}

/// A draft UUID follows the editor's content/target generation. The fingerprint
/// binds all submitted fields without retaining a second plaintext copy.
struct MessagesDirectDraftIdentity: Equatable, Sendable {
    let id: UUID
    let fingerprint: String
    init(id: UUID, account: MessagesDirectAccount, email: String, plaintext: String) {
        self.id = id
        let data = try! JSONEncoder().encode([account.id, account.label, email, plaintext])
        fingerprint = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    func matches(id: UUID, account: MessagesDirectAccount?, email: String, plaintext: String) -> Bool {
        guard let account else { return false }
        return self == Self(id: id, account: account, email: email, plaintext: plaintext)
    }
}
struct MessagesDirectTerminal: Equatable, Sendable {
    enum Outcome: Equatable, Sendable { case accepted, unknown }
    let operationID: UUID
    let draft: MessagesDirectDraftIdentity
    let outcome: Outcome
    func shouldClear(id: UUID, account: MessagesDirectAccount?, email: String, plaintext: String) -> Bool {
        outcome == .accepted && draft.matches(id: id, account: account, email: email, plaintext: plaintext)
    }
}
