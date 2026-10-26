import SwiftUI

/// Add this owned feature to the existing Control sidebar/tab after integration
/// review. The supplied deployment path belongs to sealed Control configuration,
/// never a widget, MCP argument, URL, or user-entered field.
@MainActor public final class MessagesControlFeature {
    public let store:OnboardingPanelStore
    public init(deploymentPath:String) {
        let panel = OnboardingPanel(schemaVersion:1,title:"Messages",phase:"disabled",sourceOnly:true,
            rows:[],actions:[.init(id:"begin",label:"Set up Messages",enabled:true,reason:"")],
            notice:"Messages access starts only after you review setup and the selected group.",lastError:nil,cleanup:"not_required")
        store = OnboardingPanelStore(panel:panel,client:NativeMessagesClient(deploymentPath:deploymentPath))
    }
    public var view:some View {
        MessagesOnboardingView(store:store).task { await self.store.perform(.snapshot) }
    }
}
