import SwiftUI
import ARLCredentialOnboarding

/// Minimal shared-app hook: one app-owned bootstrap, this view, and no secret-bearing host/RPC schema.
public struct NativeCredentialsView: View {
    private let bootstrap: CredentialHostBootstrap
    public init(bootstrap: CredentialHostBootstrap) { self.bootstrap = bootstrap }
    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("服务连接").font(.title)
                if !bootstrap.configured {
                    Text("此应用的安全存储接入尚未完成。可先查看官方设置说明。")
                        .foregroundStyle(.secondary)
                }
                CredentialConnectionPanel(purpose: .amapMapsWeather, onboarding: bootstrap.service)
                CredentialConnectionPanel(purpose: .fliggyTravelReadOnly, onboarding: bootstrap.service)
                CredentialConnectionPanel(purpose: .neteaseMusic, onboarding: bootstrap.service)
            }.padding(24).frame(maxWidth: 760, alignment: .leading)
        }
    }
}
