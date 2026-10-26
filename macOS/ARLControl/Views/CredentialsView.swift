import SwiftUI

struct CredentialsView: View {
    let feature: MetadataFeature<[ControlCredential]>
    let demo: Bool
    @State private var presenting = false
    @State private var dummyValue = ""
    @State private var reference: CredentialReference?
    @State private var inputRejected = false
    @State private var saving = false
    @State private var vault = InMemoryCredentialVault()
    var body: some View {
        DetailCard(title: "登录用途") {
            if let entries = feature.value {
                if entries.isEmpty { Text("后台服务尚未登记登录用途").foregroundStyle(.secondary) }
                ForEach(entries) { credential in
                    VStack(alignment: .leading, spacing: 4) {
                        MetadataRow(title: credential.service, value: credential.stateTitle)
                        Text(credential.purpose).font(.caption).foregroundStyle(.secondary)
                        Text("本地引用：\(credential.reference_status == "fixture" ? "测试引用" : "尚未解析") · 未执行供应方撤销")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else { Text(feature.explanation).foregroundStyle(.secondary) }
            
            if demo {
                HStack {
                    Button("演示输入") { dummyValue = ""; presenting = true }.disabled(saving)
                    if reference != nil {
                        Button("移除演示", role: .destructive) {
                            guard let reference else { return }
                            Task { try? await vault.removeLocally(reference); self.reference = nil }
                        }
                    }
                }
                if reference != nil { Text("仅保存在内存；不会持久化，也未撤销供应方权限。").font(.caption).foregroundStyle(.secondary) }
            } else {
                StatusBadge(title: "未接入")
            }
        }
        .sheet(isPresented: $presenting, onDismiss: { dummyValue = "" }) {
            VStack(alignment: .leading, spacing: 16) {
                Text("演示输入").font(.headline)
                Text("服务：demo.provider\n用途：仅用于演示凭据流程").font(.callout)
                SecureField("只输入 demo- 开头的虚拟值", text: $dummyValue).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("演示密钥")
                Text("勿输入真实 Key。此流程只使用内存测试替身，不保存到 Keychain。").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("取消", role: .cancel) { dummyValue = ""; presenting = false }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("保存演示") {
                        saving = true
                        let value = dummyValue; dummyValue = ""
                        Task {
                            do { reference = try await vault.save(dummyValue:value,for:.demo); presenting = false }
                            catch { inputRejected = true }
                            saving = false
                        }
                    }.keyboardShortcut(.defaultAction).disabled(saving || dummyValue.isEmpty)
                }
            }.padding(24).frame(width: 410)
        }
        .alert("演示限定", isPresented: $inputRejected) { Button("好", role: .cancel) {} }
            message: { Text("请输入 demo- 开头的短虚拟值；真实凭据不会进入此流程。") }
    }
}
