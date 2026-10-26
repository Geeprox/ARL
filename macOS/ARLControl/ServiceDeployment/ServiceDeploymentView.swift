import SwiftUI

/// Independent rendering surface. Input decoding/injection is owned by the host.
/// No deployment, registry, credential or network action is attached to this view.
struct ServiceDeploymentView: View {
    let plan: MetadataFeature<ServiceDeploymentPlan>
    let statuses: MetadataFeature<[ServiceDeploymentStatus]>
    let registry: MetadataFeature<[AppRegistration]>

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            EditorialHeading(title: "服务目录", subtitle: "查看部署计划、服务连接与健康状态")
            if let value = plan.value {
                planSummary(value)
                TimelineView(.periodic(from: .now, by: 5)) { timeline in
                    ForEach(value.services) { entry in
                        ServiceDeploymentCard(entry: entry, issues: value.issues.filter { $0.service_id == entry.service_id },
                            steps: value.steps.filter { $0.service_id == entry.service_id },
                            status: statuses.value?.first { $0.service_id == entry.service_id },
                            registry: registry.value ?? [], now: timeline.date)
                    }
                }
                if value.issues.contains(where: { issue in !value.services.contains(where: { $0.service_id == issue.service_id }) }) {
                    DetailCard(title: "补全配置") {
                        ForEach(value.issues.filter { issue in !value.services.contains(where: { $0.service_id == issue.service_id }) }) { issue in
                            Label(issue.title, systemImage: "exclamationmark.circle").font(.callout)
                        }
                    }
                }
            } else {
                DetailCard(title: "部署计划") { Text(plan.explanation).font(.callout).foregroundStyle(.secondary) }
            }
        }
        .textSelection(.enabled)
    }

    private func planSummary(_ value: ServiceDeploymentPlan) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "list.bullet.clipboard").foregroundStyle(EditorialStyle.accent)
            VStack(alignment: .leading, spacing: 5) {
                Text("部署计划 · 未执行").font(.callout.weight(.semibold))
                Text(value.state == .blocked ? "补全下方配置后重新生成计划。" : "固定版本与目标配置已整理，可逐项审阅。")
                    .font(.callout).foregroundStyle(.secondary)
                Text("顺序" + value.dependency_order.joined(separator: " → ")).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if value.inventory_source == "synthetic" { StatusBadge(title: "合成演示") }
            StatusBadge(title: value.state == .blocked ? "需补全" : "可审阅", color: value.state == .blocked ? .orange : .secondary)
        }
        .padding(16).modifier(EditorialSurface())
    }
}

private struct ServiceDeploymentCard: View {
    let entry: ServiceDeploymentEntry
    let issues: [ServiceDeploymentIssue]
    let steps: [ServiceDeploymentStep]
    let status: ServiceDeploymentStatus?
    let registry: [AppRegistration]
    let now: Date

    private var readiness: ServiceReadiness {
        status?.displayedReadiness(at: now, entry: entry, registry: registry) ?? .notChecked
    }
    var body: some View {
        DetailCard(title: entry.name) {
            HStack(alignment: .firstTextBaseline) {
                Text(entry.backend.title + " · " + entry.target_id).font(.callout).foregroundStyle(.secondary)
                Spacer(minLength: 12)
                StatusBadge(title: readiness.title, color: readiness == .ready ? .green : .secondary)
            }
            MetadataRow(title: "注册", value: registrationTitle)
            MetadataRow(title: "打开位置", value: entry.portal)
            if let stamp = status?.health_checked_at_ms {
                MetadataRow(title: "最近检查", value: Date(timeIntervalSince1970: Double(stamp) / 1000).formatted(date: .abbreviated, time: .standard))
            }
            if !issues.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(issues) { issue in
                        HStack(alignment: .top, spacing: 7) {
                            Image(systemName: issue.severity == "blocking" ? "exclamationmark.circle" : "info.circle")
                            VStack(alignment: .leading, spacing: 2) {
                                Text(issue.title).font(.callout)
                                Text(issue.field).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                        }.foregroundStyle(issue.severity == "blocking" ? .orange : .secondary)
                    }
                }.padding(.vertical, 6)
            }
            DisclosureGroup("连接目录") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(entry.ports, id: \.self) { Text($0).font(.callout.monospaced()) }
                    ForEach(entry.mounts, id: \.self) { Text($0).font(.callout.monospaced()) }
                    if entry.mounts.isEmpty { Text("无需挂载").font(.callout).foregroundStyle(.secondary) }
                }.padding(.vertical, 8)
            }.help("查看端口与外接目录")
            DisclosureGroup("高级设置") {
                VStack(alignment: .leading, spacing: 8) {
                    MetadataRow(title: "服务名称", value: entry.deployment_id)
                    MetadataRow(title: "配置项", value: entry.configuration_keys.isEmpty ? "无需额外配置" : entry.configuration_keys.joined(separator: "、"))
                    ForEach(entry.credential_requirements, id: \.self) { Text($0).font(.callout).foregroundStyle(.secondary) }
                    MetadataRow(title: "固定版本", value: entry.asset)
                    MetadataRow(title: "服务检查", value: entry.health)
                    MetadataRow(title: "Manifest SHA", value: entry.manifest_sha256)
                    MetadataRow(title: "配置校验", value: entry.configuration_sha256).help("当前配置的校验码")
                }.padding(.vertical, 8)
            }.help("查看额外配置与服务检查")
            DisclosureGroup("计划步骤") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(String(index + 1)).font(.caption.monospaced()).foregroundStyle(.secondary).frame(width: 18, alignment: .trailing)
                            Text(step.title).font(.callout)
                            Spacer(minLength: 12)
                            Text("未执行").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.padding(.vertical, 8)
            }
        }
    }

    private var registrationTitle: String {
        guard let status else { return "尚未读取" }
        if status.source == "synthetic" { return "合成演示" }
        switch status.registration {
        case "registered": return "已注册"
        case "revoked": return "已撤销"
        default: return "尚未注册"
        }
    }
}
