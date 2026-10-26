import SwiftUI

/// Private local metadata only, fetched after deliberate bounded group review.
public struct GroupPickerView: View {
    @Bindable var store: OnboardingPanelStore
    @Environment(\.dismiss) private var dismiss
    @State private var selection: String?

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choose the allowed group").font(.title2)
            Text("Review every participant. Choosing this group does not send a message.")
                .foregroundStyle(.secondary)
            List(store.candidates, selection: $selection) { candidate in
                VStack(alignment: .leading, spacing: 4) {
                    Text(candidate.name).font(.headline)
                    ForEach(candidate.participants, id: \.self) { participant in
                        Text(participant).foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 4).tag(candidate.id)
            }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Use this group and these participants") {
                    guard let selection else { return }
                    Task {
                        await store.perform(.selectGroup, arguments: ["candidate_id": selection])
                        if store.errorCode == nil { dismiss() }
                    }
                }.disabled(selection == nil || store.busy).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(minWidth: 520, minHeight: 380)
    }
}
