import SwiftUI

struct HouseholdView: View {
    let feature: MetadataFeature<HouseholdStatus>
    var body: some View {
        DetailCard(title: "家庭工具") {
            HStack(spacing: 14) { AppIcon(id: "homeassistant", symbol: "house", size: 36); VStack(alignment: .leading, spacing: 4) { Text("Home Assistant").font(.callout.weight(.semibold)); Text(feature.value?.owner ?? "所属应用未知").font(.caption).foregroundStyle(.secondary) }; Spacer(); StatusBadge(title: feature.value?.connection ?? "状态未提供") }
            if let status = feature.value {
                DisclosureGroup("能力详情") { VStack(spacing: 10) { MetadataRow(title: "读取", value: status.adapter); MetadataRow(title: "执行", value: status.authorization) }.padding(.top, 8) }
            }
        }
    }
}
