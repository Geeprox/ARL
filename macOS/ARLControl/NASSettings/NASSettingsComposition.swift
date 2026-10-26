import SwiftUI
import ARLCredentialOnboarding

// Production owns one concrete controller shared by the panel and native owner.
// The optional port factory below remains the isolated/manual compatibility path;
// it does not replace production credentials, scope checks or runtime ownership.
@MainActor
public enum ARLNASSettingsComposition {
    static func makeProductionModel(owner: NASCredentialService, home: URL, enabled: Bool) -> ARLNASSetupModel {
        let controller = NASProductionController(owner: owner, home: home, enabled: enabled)
        return ARLNASSetupModel(backend: controller, credentialConsumer: controller)
    }

    public static func makeModel(port: (any ARLNASManualControllerPort)? = nil) -> ARLNASSetupModel {
        ARLNASSetupModel(backend: ARLNASControllerBackend(port: port), credentialConsumer: nil)
    }
}

@available(macOS 14.0, *)
@MainActor
struct ARLNASSettingsSection: View {
    @ObservedObject var model: ARLNASSetupModel
    @State private var expanded: Bool

    init(model: ARLNASSetupModel) {
        self.model = model
        _expanded = State(initialValue: model.snapshot.configurationSaved != .verified)
    }

    var body: some View {
        DisclosureGroup(model.snapshot.configurationSaved == .verified ? "硬盘设置" : "硬盘设置 · 尚未配置", isExpanded: $expanded) {
            ARLNASSetupPanel(model: model)
                .padding(.top, 8)
        }
    }
}
