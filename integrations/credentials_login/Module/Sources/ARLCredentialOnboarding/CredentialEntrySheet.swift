import SwiftUI

/// Secret text stays in this sheet only until submission or dismissal.
@MainActor
public struct CredentialEntrySheet: View {
    private let purpose: CredentialPurpose
    private let onboarding: CredentialOnboarding
    private let replacing: CredentialReference?
    private let onSaved: @MainActor (CredentialSubmissionResult) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    @State private var appID = ""
    @State private var saving = false
    @State private var errorMessage: String?

    public init(purpose: CredentialPurpose, onboarding: CredentialOnboarding, replacing: CredentialReference? = nil, onSaved: @escaping @MainActor (CredentialSubmissionResult) -> Void) {
        self.purpose = purpose
        self.onboarding = onboarding
        self.replacing = replacing
        self.onSaved = onSaved
    }

    private var canSave: Bool {
        !input.isEmpty && (purpose != .neteaseMusic || !appID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(replacing == nil ? "连接\(purpose.title)" : "更新\(purpose.title)服务密钥").font(.title2)
            Text(purpose.setupExplanation).foregroundStyle(.secondary)
            if onboarding.usesSeparateTeamEntry && purpose == .neteaseMusic && replacing == nil {
                Text(("首次使用此版本请重新输入应用密钥。保存后会立即检查连接；旧版本保存的服务密钥保持不变。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Link("设置说明", destination: purpose.setupURL)
                Link("打开后台", destination: purpose.consoleURL).help("打开服务的官方管理页面")
            }
            if purpose == .neteaseMusic {
                TextField("应用编号", text: $appID).textFieldStyle(.roundedBorder).disabled(saving)
                    .accessibilityLabel("应用编号").help("填写官方应用的App ID" + "\n" + "网易云官方应用的App ID")
                if replacing != nil {
                    Text(("更新应用密钥会替换此应用保存的登录状态，之后需重新扫码登录。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            SecureField(purpose.credentialTitle, text: $input).help(purpose.credentialExplanation).textFieldStyle(.roundedBorder).disabled(saving)
                .accessibilityLabel("\(purpose.title)的\(purpose.credentialTitle)")
            Text(purpose == .neteaseMusic
                 ? ("保存后立即检查网易云连接；需要登录时会提示您扫码，不会自动发起登录。")
                 : ("操作可能收费，请先核对完整说明" + "\n" + "先验证连接，通过后保存到 ARL；失败保留原配置。验证仅发送只读请求，可能消耗调用额度。"))
                .font(.caption).foregroundStyle(.secondary)
            if saving { ProgressView("处理中").controlSize(.small) }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red).accessibilityLabel(errorMessage) }
            HStack {
                Button("取消", role: .cancel) { clearEntry(); dismiss() }
                    .keyboardShortcut(.cancelAction).disabled(saving)
                Spacer()
                Button("保存检查", action: save).help("保存密钥并检查连接")
                    .keyboardShortcut(.defaultAction).disabled(saving || !canSave)
            }
        }
        .padding(24).frame(width: 460)
        .interactiveDismissDisabled(saving)
        .onDisappear { clearEntry() }
    }

    private func clearEntry() { input = ""; appID = "" }

    private func save() {
        guard !saving, canSave else { return }
        let submitted: CredentialInput
        do {
            if purpose == .neteaseMusic {
                submitted = try CredentialInput(neteaseAppID: appID, privateKey: input)
            } else {
                submitted = try CredentialInput(purpose: purpose, value: input)
            }
        } catch {
            clearEntry()
            errorMessage = purpose == .neteaseMusic
                ? ("请检查应用编号与密钥" + "\n" + "App ID 或 Private Key 格式不符合要求，请重新输入官方应用密钥。")
                : ("请填写对应类型的密钥" + "\n" + "输入格式不符合此服务用途，请重新输入官方 Key。")
            return
        }
        clearEntry()
        errorMessage = nil
        saving = true
        Task { @MainActor in
            defer { submitted.clear(); saving = false }
            do {
                let result = try await onboarding.saveAndVerify(submitted, purpose: purpose, replacing: replacing)
                onSaved(result)
                dismiss()
            } catch let error as CredentialError {
                switch error {
                case .deploymentNotApproved, .identityMismatch: errorMessage = ("安全保存尚未接入" + "\n" + "应用的安全存储接入尚未完成，请先完成应用设置。")
                case .alreadyConfigured: errorMessage = ("已有登录信息，请选择更新" + "\n" + "此用途已有本机密钥；请关闭此窗口，刷新状态后使用更新操作。")
                case .staleReference, .missing: errorMessage = ("登录信息已变，请刷新" + "\n" + "本地引用已变化；请关闭此窗口，刷新状态后重试。")
                case .busy: errorMessage = ("已有操作正在进行" + "\n" + "此服务已有操作正在进行，请先等待或取消该操作。")
                case .uncertainLocalState: errorMessage = ("保存结果未知" + "\n" + "保存或更新结果未确认；未自动重试，未调整访问权限。")
                default: errorMessage = ("无法保存，请检查输入" + "\n" + "无法保存服务密钥。请检查输入及本地安全存储状态。")
                }
            } catch let error as CredentialStorageFailure { errorMessage = error.message }
              catch is LoginACLFailure { errorMessage = ("保存结果未确认，请先核对状态" + "\n" + "本地安全存储访问校验未通过；保存或更新结果未确认，未自动重试，未调整访问权限。") }
              catch { errorMessage = ("保存结果未确认，请先核对状态" + "\n" + "无法确认服务密钥已保存；未开始连接验证。请稍后重试。") }
        }
    }
}
