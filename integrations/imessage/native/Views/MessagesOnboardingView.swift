import SwiftUI

/// Embeddable macOS 14+ panel; does not replace or modify the shared Control UI.
public struct MessagesOnboardingView: View {
    @Bindable var store: OnboardingPanelStore
    private let embedded: Bool
    @State private var showingGroups = false
    @State private var showingTestReview = false
    @State private var showingMioReview = false
    private let appleGuide = URL(string: "https://support.apple.com/guide/messages/set-up-messages-on-mac-ichte16154fb/mac")!

    public init(store: OnboardingPanelStore, embedded: Bool = false) { self.store = store; self.embedded = embedded }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(store.panel.title).font(.largeTitle)
                Text(store.panel.notice).foregroundStyle(.secondary)
                ForEach(store.panel.rows) { row in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(row.title).font(.headline)
                            Spacer()
                            Text(row.value).foregroundStyle(.secondary)
                        }
                        Text(row.detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Divider()
                }
                if let error = store.errorCode {
                    Text(message(for: error)).foregroundStyle(.red).accessibilityLabel("Setup status: " + message(for: error))
                }
                FlowActions(store: store, activate: activate)
                Link("Apple’s Messages sign-in guide", destination: appleGuide)
            }.padding(28)
        }
        .frame(minWidth: embedded ? 0 : 650, minHeight: embedded ? 0 : 600)
        .sheet(isPresented: $showingGroups) { GroupPickerView(store: store) }
        .sheet(isPresented: $showingTestReview) { testReview }
        .confirmationDialog("Share test text with the existing organization Mio connection?",
                            isPresented: $showingMioReview, titleVisibility: .visible) {
            Button("Verify this organization-scoped event") { Task { await store.perform(.verifyMio) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This sends the agreed test text to the existing organization/OpenAI/Mio audience. It does not prove a personal-exclusive workflow or conversation.")
        }
    }

    private var testReview: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Review the bounded message test").font(.title2)
            if let review = store.review {
                Text("One test send to the selected group. Ask a reviewed participant to send these two new messages; history is skipped.")
                Text("First incoming message:").font(.headline)
                Text(review.receiveText).textSelection(.enabled)
                Text("ARL will send:").font(.headline)
                Text(review.sendText).textSelection(.enabled)
                Text("Participant confirmation:").font(.headline)
                Text(review.confirmationText).textSelection(.enabled)
                Text("Run normal receive/send while the Mac is locked for locked-state acceptance. A failed or uncertain send will not be automatically repeated.")
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Cancel") { showingTestReview = false }
                    Spacer()
                    Button("Run this exact test") {
                        showingTestReview = false
                        Task { await store.perform(.startTest, arguments: ["plan_id": review.planID]) }
                    }.buttonStyle(.borderedProminent)
                }
            }
        }.padding(24).frame(width: 570)
    }

    private func activate(_ id: String) {
        Task {
            switch id {
            case "discover_groups":
                await store.perform(.discoverGroups)
                showingGroups = store.errorCode == nil
            case "prepare_test", "start_test":
                await store.perform(.prepareTest)
                showingTestReview = store.review != nil && store.errorCode == nil
            case "confirm_account": await store.perform(.confirmAccount, arguments: ["report": "signed_in_in_messages"])
            case "receive_settings": await store.perform(.permissionAction, arguments: ["capability_id": "messages.receive.v1", "action": "open_settings"])
            case "receive_retest": await store.perform(.permissionAction, arguments: ["capability_id": "messages.receive.v1", "action": "retest"])
            case "send_permission": await store.perform(.permissionAction, arguments: ["capability_id": "messages.send.v1", "action": "request"])
            case "verify_mio": showingMioReview = true
            default:
                guard let command = OnboardingCommand(rawValue: id) else { return }
                await store.perform(command)
            }
        }
    }

    private func message(for code: String) -> String {
        switch code {
        case "send_unknown": "The test send may have happened. Check the original operation before another attempt."
        case "cleanup_unknown": "Stopping is not yet verified. Reconnect stays unavailable."
        case "group_changed": "The group or participants changed. Review the selection again."
        case "permission_required": "The responsible Messages bridge still needs permission evidence."
        case "event_unproven": "Local messages worked, but this Mio event has not been verified."
        case "verification_timeout", "receive_timeout": "The bounded test timed out. Check its original state before retrying."
        case "cancelled": "Setup was canceled. Any send already dispatched cannot be recalled."
        case "unsupported", "host_unavailable": "The responsible Messages host is not available."
        default: "Setup needs attention before continuing."
        }
    }
}

private struct FlowActions: View {
    @Bindable var store: OnboardingPanelStore
    let activate: (String) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(store.panel.actions) { action in
                if action.enabled || !action.reason.isEmpty {
                    HStack {
                        Button(action.label) { activate(action.id) }
                            .disabled(!action.enabled || (store.busy && action.id != "cancel" && action.id != "disable"))
                        if !action.reason.isEmpty { Text(action.reason).foregroundStyle(.secondary) }
                    }
                }
            }
        }
    }
}
