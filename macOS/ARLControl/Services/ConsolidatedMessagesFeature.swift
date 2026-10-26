import Foundation
import Observation

/// The owner feature and native client execute inside this signed Control.
/// Configuration is a fixed private host path. No public enrolment or targets.
@MainActor @Observable final class ConsolidatedMessagesFeature {
    let feature: MessagesControlFeature
    let demo: Bool
    private let deploymentPath: String
    private(set) var activationAllowed = false
    private(set) var sourceState = "not_deployed"
    private(set) var synthetic = false
    init(home: URL, demo: Bool) {
        self.demo = demo
        deploymentPath = home.appendingPathComponent("messages/control.json").path
        feature = MessagesControlFeature(deploymentPath: deploymentPath)
        reviewDeployment()
    }
    func reviewDeployment() {
        activationAllowed = false; synthetic = false
        guard !demo else { sourceState = "preview_disabled"; return }
        guard FileManager.default.fileExists(atPath: deploymentPath) else { sourceState = "not_deployed"; return }
        do {
            let value = try MessagesNativeDeployment.load(deploymentPath)
            try value.verify()
            let policy = try MessagesJSON.decode(MessagesNativeIO.privateFile(value.helper_bundle_path+"/Contents/Resources/activation.json")).value
            guard let mode = policy["mode"] as? String, ["live","synthetic"].contains(mode),
                  let enabled = MessagesNativeIO.integer(policy["enabled"]), [0,1].contains(enabled) else { throw MessagesTransportFault("invalid_deployment") }
            synthetic = mode == "synthetic"
            activationAllowed = enabled == 1
            sourceState = enabled == 0 ? "verified_disabled" : synthetic ? "synthetic_only" : "admitted_host"
        } catch { sourceState = "identity_unverified" }
    }
    func refresh() async {
        reviewDeployment()
        // This bounded snapshot cannot launch the helper or inspect Messages.
        if activationAllowed { await feature.store.perform(.snapshot) }
    }
    var description: String {
        switch sourceState {
        case "verified_disabled": "内部信息服务身份已核验，但服务已停用。刷新不会启动它，系统权限仍未知。"
        case "synthetic_only": "隔离合成测试配置。状态与测试数据不能作为真实账户、TCC 或消息就绪证据。"
        case "admitted_host": "原生宿主接入已配置。系统权限、账户报告、群成员、发送结果与接收证据分别核验。"
        case "identity_unverified": "内部信息服务身份无法核验，设置与执行入口不可用。"
        case "preview_disabled": "演示中的设置与执行入口已禁用。"
        default: "内部信息服务尚未安装配置。系统权限未知，设置与执行入口不可用。"
        }
    }
}
