import SwiftUI

struct RegistryView: View {
    let feature: MetadataFeature<[AppRegistration]>
    var body: some View {
        DetailCard(title: "连接应用") {
            if let entries = feature.value {
                TimelineView(.periodic(from: .now, by: 5)) { timeline in
                    let connected = AppRegistration.connected(entries, at: timeline.date)
                    if connected.isEmpty {
                        EditorialNotice(title: "暂无已连接的应用", detail: "", symbol: "app.connected.to.app.below.fill")
                    }
                    ForEach(connected) { entry in
                        DisclosureGroup {
                            VStack(alignment: .leading, spacing: 8) {
                                MetadataRow(title: "授权", value: entry.authorization)
                                if let version = entry.version { MetadataRow(title: "版本", value: version) }
                                if !entry.advertised.isEmpty { MetadataRow(title: "所需能力", value: entry.advertised.joined(separator: "、")) }
                                if !entry.authorizedTools.isEmpty { MetadataRow(title: "工具", value: entry.authorizedTools.joined(separator: "、")) }
                                if let seen = entry.observedAt { MetadataRow(title: "最近活动", value: seen.formatted(date: .omitted, time: .standard)) }
                            }.padding(.leading, 48).padding(.top, 12).padding(.bottom, 4)
                        } label: {
                            HStack(spacing: 12) {
                                AppIcon(id: entry.id, symbol: entry.symbol, registeredIcon: entry.applicationIcon, iconHome: entry.applicationIconHome, protocolIcon: true)
                                Text(entry.name).font(.callout.weight(.medium)).lineLimit(2)
                                Spacer(minLength: 12)
                                StatusBadge(title: "已连接", color: .green)
                            }.padding(.vertical, 4)
                        }
                        if entry.id != connected.last?.id { Divider() }
                    }
                }
            } else {
                EditorialNotice(title: "应用状态暂不可读", detail: "", symbol: "network")
            }
        }
    }
}
