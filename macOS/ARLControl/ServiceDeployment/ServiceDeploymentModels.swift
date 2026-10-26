import Foundation

enum ServicePlanState: String, Decodable, Sendable { case reviewable, blocked }
enum ServiceBackend: String, Decodable, Sendable {
    case macNative = "mac_native", docker, nasDocker = "nas_docker"
    var title: String {
        switch self { case .macNative: "Mac 原生"; case .docker: "Docker"; case .nasDocker: "NAS · Docker" }
    }
}
enum ServiceReadiness: String, Decodable, Sendable {
    case notChecked = "not_checked", ready, stale, revoked, unverified
    case syntheticOnly = "synthetic_only", notDeployed = "not_deployed", notRegistered = "not_registered"
    case evidenceMismatch = "evidence_mismatch", registrationBindingMissing = "registration_binding_missing"
    case registryDescriptorMismatch = "registry_descriptor_mismatch", configurationIncomplete = "configuration_incomplete"
    case invalidEvidenceTime = "invalid_evidence_time", healthEndpointMismatch = "health_endpoint_mismatch"
    case healthFailed = "health_failed", credentialNotChecked = "credential_not_checked"
    case credentialUnavailable = "credential_unavailable", dependencyNotReady = "dependency_not_ready"
    var title: String {
        switch self {
        case .ready: "健康检查通过"
        case .notChecked: "尚未核验"
        case .stale: "状态已过期"
        case .revoked: "注册已撤销"
        case .unverified: "连接待核验"
        case .syntheticOnly: "合成演示"
        case .notDeployed: "尚未部署"
        case .notRegistered: "尚未注册"
        case .evidenceMismatch, .registryDescriptorMismatch: "配置已变化"
        case .registrationBindingMissing: "注册待绑定"
        case .configurationIncomplete: "补全配置"
        case .invalidEvidenceTime: "状态时间待核对"
        case .healthEndpointMismatch: "检查目标不一致"
        case .healthFailed: "健康检查未通过"
        case .credentialNotChecked: "服务凭据待核验"
        case .credentialUnavailable: "服务凭据不可用"
        case .dependencyNotReady: "依赖服务未就绪"
        }
    }
}

struct ServiceDeploymentPlan: Decodable, Sendable {
    let schema_version: Int
    let kind: String
    let state: ServicePlanState
    let execution: String
    let registration: String
    let readiness: String
    let apply_available: Bool
    let effects_performed: [String]
    let root_service_id: String
    let services: [ServiceDeploymentEntry]
    let dependency_order: [String]
    let issues: [ServiceDeploymentIssue]
    let steps: [ServiceDeploymentStep]
    let inventory_source: String
}

struct ServiceDeploymentEntry: Decodable, Identifiable, Sendable {
    let service_id: String
    let name: String
    let backend: ServiceBackend
    let target_id: String
    let deployment_id: String
    let manifest_sha256: String
    let configuration_sha256: String
    let asset: String
    let proposed_registration: ServiceProposedRegistration
    let ports: [String]
    let mounts: [String]
    let configuration_keys: [String]
    let credential_requirements: [String]
    let portal: String
    let health: String
    var id: String { service_id }
}

struct ServiceProposedRegistration: Decodable, Sendable {
    let id: String
    let name: String
    let icon_ref: String
    let version: String
    let capabilities: [String]
}
struct ServiceDeploymentIssue: Decodable, Identifiable, Sendable {
    let code: String
    let severity: String
    let service_id: String
    let field: String
    var id: String { service_id + ":" + field + ":" + code }
    var title: String {
        switch code {
        case "dependency_missing": "缺少依赖服务"
        case "dependency_version_mismatch": "依赖版本不一致"
        case "dependency_cycle": "依赖形成循环"
        case "configuration_missing": "需要服务配置"
        case "deployment_id_conflict": "部署名称重复"
        case "port_conflict", "port_occupied_in_snapshot": "端口存在冲突"
        case "required_port_missing", "endpoint_port_missing": "需要端口绑定"
        case "required_mount_missing": "需要挂载位置"
        case "required_parameter_missing": "需要配置项"
        case "required_credential_reference_missing": "需要服务凭据引用"
        case "target_backend_unsupported": "目标未提供所选运行方式"
        case "target_inventory_unavailable": "目标资源尚未核验"
        case "credential_resolution_not_performed": "凭据引用尚未核验"
        case "mount_write_review_required": "核对挂载的写入范围"
        case "nas_transport_not_configured": "NAS 连接待配置"
        case "native_mount_application_not_defined": "原生应用的挂载方式待明确"
        case "optional_dependency_absent", "optional_dependency_not_selected": "可选依赖未加入"
        default: "核对服务配置"
        }
    }
}
struct ServiceDeploymentStep: Decodable, Identifiable, Sendable {
    let service_id: String
    let kind: String
    let detail: String
    let state: String
    var id: String { service_id + ":" + kind }
    var title: String {
        switch kind {
        case "review_source": "核对固定来源与许可"
        case "verify_target": "核对目标环境"
        case "verify_dependencies": "核对依赖服务"
        case "review_ports": "核对端口"
        case "review_mounts": "核对挂载"
        case "review_configuration": "核对配置与服务凭据"
        case "stage_asset": "准备固定版本"
        case "start_service": "启动所选服务"
        case "observe_health": "检查目标服务健康"
        default: "注册门户"
        }
    }
}

struct ServiceDeploymentStatus: Decodable, Identifiable, Sendable {
    let schema_version: Int
    let kind: String
    let service_id: String
    let version: String
    let target_id: String
    let deployment_id: String
    let manifest_sha256: String
    let configuration_sha256: String
    let generation: Int?
    let registration: String
    let connection: String
    let authentication: String
    let authorization: String
    let deployment: String
    let readiness: ServiceReadiness
    let source: String
    let checked_at_ms: Int
    let health_checked_at_ms: Int?
    let ready_until_ms: Int?
    var id: String { service_id }

    func displayedReadiness(at date: Date, entry: ServiceDeploymentEntry, registry: [AppRegistration]) -> ServiceReadiness {
        guard readiness == .ready else { return readiness }
        let now = date.timeIntervalSince1970 * 1000
        guard now >= Double(checked_at_ms), let until = ready_until_ms, now <= Double(until) else { return .stale }
        guard target_id == entry.target_id, deployment_id == entry.deployment_id,
              manifest_sha256 == entry.manifest_sha256, configuration_sha256 == entry.configuration_sha256,
              version == entry.proposed_registration.version else { return .evidenceMismatch }
        guard let app = registry.first(where: { $0.id == service_id }), app.isConnected(at: date) else { return .unverified }
        return .ready
    }
}
