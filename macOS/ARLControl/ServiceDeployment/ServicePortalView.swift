import SwiftUI

struct ServicePortalView: View {
    let service: SettingsService
    let connectionAvailable: Bool
    @State private var presentation = ServicePortalPresentation()
    @State private var selectedServiceID = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let catalog = presentation.catalog.value {
                if catalog.entries.isEmpty {
                    DetailCard(title: "服务目录") { Text("暂无已审阅的服务项目").font(.callout).foregroundStyle(.secondary) }
                } else {
                    HStack {
                        Picker("服务项目", selection: Binding(get: { selectedServiceID }, set: select)) {
                            ForEach(catalog.entries) { entry in Text(entry.name).tag(entry.id) }
                        }.frame(maxWidth: 360)
                        Spacer()
                        Button("刷新计划") { Task { await refresh() } }.disabled(presentation.reading)
                    }
                    if let review = presentation.review.value {
                        ServiceDeploymentView(plan: .available(review.plan), statuses: .available(review.statuses), registry: .available(review.registry))
                    } else {
                        DetailCard(title: "部署计划") { Text(presentation.review.explanation).font(.callout).foregroundStyle(.secondary) }
                    }
                }
            } else {
                DetailCard(title: "服务目录") { Text(presentation.catalog.explanation).font(.callout).foregroundStyle(.secondary) }
            }
        }
        .task(id: connectionAvailable) {
            presentation.setConnection(connectionAvailable)
            guard connectionAvailable else { presentation.invalidate(); return }
            await refresh()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { break }
                await refresh()
            }
        }
        .onDisappear { presentation.setConnection(false) }
    }

    private func select(_ identity: String) {
        selectedServiceID = identity
        presentation.invalidate("selection_changed")
        Task { await refresh() }
    }
    @MainActor private func refresh() async {
        guard connectionAvailable else { presentation.invalidate(); return }
        guard let token = presentation.beginRead() else { return }
        let nextCatalog = await service.readServicePortalCatalog()
        guard !Task.isCancelled, presentation.receiveCatalog(nextCatalog, token: token), let catalog = nextCatalog.value else { return }
        guard !catalog.entries.isEmpty else {
            selectedServiceID = ""
            presentation.receiveReview(.unavailable("empty_catalog"), token: token)
            return
        }
        if !catalog.entries.contains(where: { $0.id == selectedServiceID }) { selectedServiceID = catalog.entries[0].id }
        let nextReview = await service.readServicePortalReview(serviceID: selectedServiceID, catalogSHA256: catalog.catalog_sha256)
        guard !Task.isCancelled else { return }
        presentation.receiveReview(nextReview, token: token)
    }
}
