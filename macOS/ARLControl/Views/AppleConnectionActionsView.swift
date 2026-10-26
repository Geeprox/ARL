import SwiftUI
import AppKit

// Fixed system destinations only. Opening the target app does not check its
// account, request automation permission, or send a business Apple event.
struct AppleConnectionActionsView: View {
    let target: AppleDirectTarget
    let permission: AppleDirectPermission
    let enabled: Bool
    let busy: Bool
    var observation: AppleConnectionState<AppleDirectPermission> = .init()
    let check: () -> Void
    let request: () -> Void
    @State private var openMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(permissionTitle).font(.system(size: 16, weight: .semibold))
            if !enabled {
                Text("连接未启用").font(.callout).foregroundStyle(.secondary)
            } else if permission == .denied {
                Text("请在系统设置中允许访问" + targetTitle + "。")
                    .font(.callout).foregroundStyle(.secondary)
            } else if let failure = observation.lastFailure {
                Text(failure.issue == .targetNotRunning && observation.value == nil
                     ? "应用未运行" : failure.issue.title)
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if busy || observation.refreshing {
                ProgressView("正在处理连接").controlSize(.small)
            } else if enabled {
                if permission == .notDetermined || (permission == .unknown && observation.lastFailure?.issue == .targetNotRunning) {
                    Button("允许访问" + targetTitle, action: request)
                        .buttonStyle(EditorialActionButtonStyle(emphasis: .primary))
                } else if permission == .denied {
                    Button("在系统设置中允许", action: openSettings)
                        .buttonStyle(EditorialActionButtonStyle(emphasis: .primary))
                } else if permission == .unknown {
                    Button("检查系统权限", action: check)
                }
            }
            if let openMessage { Text(openMessage).font(.caption).foregroundStyle(.secondary) }
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 10) {
                    if let date = observation.observedAt {
                        Text(observation.showingLastKnown ? "最近权限：" : "更新时间：")
                        Text(date, format: .dateTime.month().day().hour().minute()).monospacedDigit()
                    }
                    HStack {
                        Button("刷新权限", action: check).disabled(!enabled || busy || observation.refreshing)
                        Button("打开" + targetTitle, action: openTarget)
                        if permission != .denied { Button("系统设置", action: openSettings) }
                    }
                    if let code = observation.lastFailure?.nativeStatus {
                        Text("系统状态码：" + String(code)).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }.font(.caption).foregroundStyle(.secondary).padding(.top, 10)
            }.font(.caption)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var targetTitle: String { target == .messages ? "信息" : "备忘录" }
    private func openTarget() {
        openMessage = NSWorkspace.shared.open(URL(fileURLWithPath: target.path))
            ? nil : "打开失败，请从启动台打开。"
    }
    private func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
    }
    private var permissionTitle: String {
        let title: String = switch permission {
        case .authorized: "已授权"
        case .notDetermined: "待授权"
        case .denied: "未允许"
        case .unknown: "状态待更新"
        }
        return observation.showingLastKnown ? "最近：" + title : title
    }
}

/// Preferences only: no reminder business composer or request-target filtering.
struct RemindersDefaultListSettings: View {
    let controller: RemindersProductController
    var disabled = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("默认清单").font(.callout.weight(.medium))
            HStack(spacing: 10) {
                Menu {
                    if let catalog = controller.catalog {
                        ForEach(catalog.sources) { source in
                            if catalog.lists.contains(where: { $0.source_id == source.id }) {
                                Section(accountTitle(source)) {
                                    ForEach(catalog.lists.filter { $0.source_id == source.id }) { list in
                                        Button {
                                            controller.select(sourceID: source.id, listID: list.id)
                                        } label: {
                                            Label(listTitle(list, catalog: catalog), systemImage: controller.defaultTarget?.list?.id == list.id ? "checkmark" : "list.bullet")
                                        }.disabled(!list.writable || list.subscribed == true)
                                    }
                                }
                            }
                        }
                    }
                } label: {
                    Text(controller.defaultTarget?.list?.title ?? (controller.busy ? "正在读取" : "选择清单"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.modifier(EditorialMenuSurface()).frame(maxWidth: 360)
                    .disabled(disabled || controller.busy || controller.catalog?.lists.isEmpty != false)
                    .accessibilityLabel("默认提醒清单")
                    .accessibilityValue(controller.defaultTarget.map { $0.source.title + "，" + ($0.list?.title ?? "未设置") } ?? "未设置")
                Button("刷新清单") { controller.discover() }.disabled(disabled || controller.busy)
            }
            if let target = controller.defaultTarget {
                Text(accountTitle(target.source)).font(.caption).foregroundStyle(.secondary)
            }
            if let catalog = controller.catalog, catalog.lists.isEmpty {
                Text("未找到提醒清单").font(.caption).foregroundStyle(.secondary)
            }
            if let message = feedback {
                Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }.task {
            guard !disabled else { return }
            do {
                _ = try await controller.execute(.init(.selection))
                if controller.catalog == nil { _ = try await controller.execute(.init(.catalog)) }
            } catch { /* The controller retains the local recovery message. */ }
        }
    }
    private func accountTitle(_ source: RemindersProductSource) -> String {
        var parts = [source.title]
        if source.is_system_default_account == true { parts.append("系统默认账户") }
        if source.is_delegate == true { parts.append("委派") }
        if source.type == 4 { parts.append("订阅账户") }
        return parts.joined(separator: " · ")
    }
    private func listTitle(_ list: RemindersProductList, catalog: RemindersProductCatalog) -> String {
        var parts = [list.title]
        if list.is_system_default == true || list.id == catalog.system_default_list_id { parts.append("系统默认") }
        if !list.writable { parts.append("只读") }
        if list.subscribed == true { parts.append("订阅") }
        if list.immutable == true { parts.append("受保护") }
        return parts.joined(separator: " · ")
    }
    private var feedback: String? {
        guard let message = controller.message else { return nil }
        if message == "已读取。" || message.hasPrefix("已设置默认清单") || message.hasPrefix("已恢复默认清单") { return nil }
        return message
    }
}
