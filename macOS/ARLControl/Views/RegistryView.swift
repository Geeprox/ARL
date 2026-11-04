import SwiftUI

struct RegistryView: View {
    let feature: MetadataFeature<[AppRegistration]>
    var body: some View {
        DetailCard(title: "已连接应用") {
            if let entries = feature.value {
                TimelineView(.periodic(from: .now, by: 5)) { timeline in
                    let connected = AppRegistration.connected(entries, at: timeline.date)
                    if connected.isEmpty {
                        VStack(alignment:.leading,spacing:10) {
                            Image(systemName:"app.connected.to.app.below.fill").font(.system(size:24,weight:.light)).foregroundStyle(.secondary).padding(.bottom,4)
                            Text("等待应用连接").font(.headline)
                            Text("打开支持 ARL 的应用后，它会自动出现在这里。").font(.callout).foregroundStyle(.secondary)
                            Text("ARL 会接收应用的任务，按优先级排队并使用你配置的模型套餐。").font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical,14).frame(maxWidth:.infinity,alignment:.leading)
                    }
                    ForEach(connected) { entry in
                        DisclosureGroup {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(entry.scenarios) { scenario in
                                    HStack { Text(scenario.name);Spacer();Text(scenario.priorityTitle+" · "+scenario.packageTitle+"套餐").foregroundStyle(.secondary) }
                                }
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
                                ConnectionIndicator(ready:true,title:entry.name)
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
