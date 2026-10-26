import SwiftUI

struct AppleReadinessView: View {
    let feature: MetadataFeature<[ControlAppleApp]>
    let legacy: RuntimeSnapshot?
    var body: some View {
        DetailCard(title: "苹果应用") {
            if let apps = feature.value {
                VStack(spacing: 0) {
                    ForEach(apps) { app in
                        DisclosureGroup {
                            VStack(spacing: 10) {
                                ForEach(app.actions) { action in
                                    HStack(alignment: .firstTextBaseline) {
                                        Text(action.title).font(.callout)
                                        Spacer()
                                        Text(action.permissionTitle).font(.caption).foregroundStyle(.secondary)
                                        StatusBadge(title: action.state == "ready" && !action.authorized ? "未授权" : action.stateTitle, color: action.state == "ready" && action.authorized ? .green : .secondary)
                                    }.help("\(action.authorized ? "操作已授权" : "操作未授权") · \(action.lock == "locked" ? "已锁定" : action.lock == "unlocked" ? "已解锁" : "锁定状态未核验")")
                                }
                            }.padding(.leading, 52).padding(.vertical, 10)
                        } label: {
                            HStack(spacing: 14) {
                                AppIcon(id: app.id, symbol: app.symbol, size: 36)
                                VStack(alignment: .leading, spacing: 4) { Text(app.title).font(.callout.weight(.semibold)); Text("\(app.actions.count) 项操作").font(.caption).foregroundStyle(.secondary) }
                                Spacer()
                                StatusBadge(title: summary(app), color: app.actions.contains { $0.state == "ready" && $0.authorized } ? .green : .secondary)
                            }.padding(.vertical, 6)
                        }
                        if app.id != apps.last?.id { Divider() }
                    }
                }
            } else {
                Text(feature.explanation).foregroundStyle(.secondary)
                if let legacy { ForEach(legacy.capabilities.filter(\.isApple)) { capability in MetadataRow(title: capability.name, value: "待检查") } }
            }
        }
    }
    private func summary(_ app: ControlAppleApp) -> String {
        if app.actions.contains(where: { $0.state == "ready" && $0.authorized }) { return "部分可用" }
        if app.actions.allSatisfy({ $0.state == "not_implemented" }) { return "未接入" }
        if app.actions.contains(where: { $0.state == "needs_permission" }) { return "需要权限" }
        return app.actions.contains(where: { $0.state == "unavailable" }) ? "不可用" : "待检查"
    }
}
