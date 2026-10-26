import SwiftUI

/// An explicit product action, never a launch-time migration or owner RPC.
@MainActor
struct LegacyTravelMigrationPanel: View {
    let purpose: CredentialPurpose
    let onboarding: CredentialOnboarding
    let onSaved: @MainActor (CredentialSubmissionResult) -> Void
    @State private var status: LegacyTravelStatus = .unavailable
    @State private var running = false
    @State private var message: String?
    @State private var configured = false
    @State private var work: Task<Void, Never>?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if status == .available && !configured {
                Text("发现旧版设置").font(.callout)
                Text("点击后只读旧配置，以相同用途验证；通过后保存到 ARL，供 Mio 使用。失败不切换，旧文件始终保留。此操作可能消耗服务调用额度。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                if status == .available && !configured {
                    Button("迁移设置") { migrate() }.disabled(running)
                        .help("验证旧版服务密钥，通过后保存到 ARL；保留旧文件")
                }
                Button("核对保存") { recover() }.disabled(running)
                    .help("只核对上次保存，不重新提交密钥")
                if running {
                    ProgressView().controlSize(.small)
                    Button("取消") { work?.cancel() }
                }
            }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
        }
        .task {
            status = await onboarding.legacyTravelStatus(purpose: purpose)
            configured = await onboarding.snapshot(purpose: purpose).reference != nil
        }
        .onDisappear { work?.cancel() }
    }
    private func migrate() {
        guard !running else { return }; running = true; message = nil
        work = Task { @MainActor in
            defer { running = false; work = nil }
            do {
                let result = try await onboarding.migrateLegacyTravel(purpose: purpose)
                guard !Task.isCancelled else { return }
                configured = result.snapshot.reference != nil
                onSaved(result); message = result.message
            } catch { if !Task.isCancelled { message = failure(error) } }
        }
    }
    private func recover() {
        guard !running else { return }; running = true; message = nil
        work = Task { @MainActor in
            defer { running = false; work = nil }
            do {
                let snapshot = try await onboarding.recoverTravelSave(purpose: purpose)
                guard !Task.isCancelled else { return }
                configured = snapshot.reference != nil
                onSaved(.init(snapshot: snapshot, recoveredExisting: snapshot.reference != nil, verificationFailure: nil, saved: snapshot.reference != nil))
                message = "已核对本机状态；旧文件保留，未重新提交。"
                status = await onboarding.legacyTravelStatus(purpose: purpose)
            } catch { if !Task.isCancelled { message = failure(error) } }
        }
    }
    private func failure(_ error: Error) -> String {
        if error as? CredentialError == .alreadyConfigured { return "ARL 已有此服务密钥，未覆盖；请刷新状态。旧文件保留。" }
        if error as? CredentialError == .busy { return "此服务已有操作，请等待完成。" }
        if error is CancellationError { return "操作已取消，旧配置保留；未自动重试。" }
        if error as? CredentialError == .deploymentNotApproved || error as? CredentialError == .identityMismatch {
            return "应用身份或安全存储接入未通过；未调整权限。"
        }
        return "迁移或保存未确认，旧文件保留。请先点击核对保存；未自动重试，未调整访问权限。"
    }
}
