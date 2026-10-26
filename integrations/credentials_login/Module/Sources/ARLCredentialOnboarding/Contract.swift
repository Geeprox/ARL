import Foundation

public enum CredentialPurpose: String, Codable, CaseIterable, Sendable {
    case amapMapsWeather = "amap.maps-weather"
    case fliggyTravelReadOnly = "fliggy.travel-readonly"
    case neteaseMusic = "netease.music-account"
    case nasSMB = "nas.smb-private"
    var isTravel: Bool { self == .amapMapsWeather || self == .fliggyTravelReadOnly }
    public var title: String { self == .nasSMB ? "网络硬盘" : self == .neteaseMusic ? "网易云音乐" : self == .amapMapsWeather ? "高德地图" : "飞猪旅行" }
    var maximumCredentialBytes: Int { self == .neteaseMusic ? 131072 : self == .nasSMB ? 65536 : 2048 }
    public var credentialTitle: String { self == .neteaseMusic ? "应用密钥" : self == .amapMapsWeather ? "服务密钥" : "服务密钥" }
    var credentialExplanation: String { self == .neteaseMusic ? "填写官方应用Private Key" : self == .amapMapsWeather ? "填写Web服务Key，其他类型无效" : "填写FlyAI官方API Key" }
    public var setupURL: URL { URL(string: self == .neteaseMusic ? "https://github.com/NetEase/skills#ncm-cli-setup" : self == .amapMapsWeather ? "https://lbs.amap.com/api/webservice/guide/create-project/get-key" : "https://open.fly.ai/docs/quickstart")! }
    public var consoleURL: URL { URL(string: self == .neteaseMusic ? "https://github.com/NetEase/skills#ncm-cli-setup" : self == .amapMapsWeather ? "https://console.amap.com/dev/key/app" : "https://open.fly.ai/console")! }
    public var setupExplanation: String { self == .neteaseMusic ? ("填写官方应用的 App ID 和 Private Key。密钥和登录状态由 ARL 保存在本机安全存储中；保存后需单独扫码登录。") : self == .amapMapsWeather ? ("只验证天气，需填写指定服务密钥" + "\n" + "在官方控制台创建应用，选择 Web 服务 Key；SDK 或 JS Key 不能替代。测试仅验证天气接口，不证明全部地图能力。") : ("在 FlyAI 官方控制台获取 API Key。商家 TOP AppKey/AppSecret、淘宝密码和会话 Cookie 不属于此用途。本机接入配置未完成时不能验证连接。") }
    // Persisted identity is independent of editable interface copy.
    var storageLabel: String { "ARL · " + rawValue }
    func acceptsStoredLabel(_ label: String) -> Bool {
        switch self {
        case .amapMapsWeather: [storageLabel, "ARL · 高德地图与天气", "ARL · 高德地图"].contains(label)
        case .fliggyTravelReadOnly: [storageLabel, "ARL · 飞猪旅行查询（FlyAI）", "ARL · 飞猪旅行"].contains(label)
        case .neteaseMusic: [storageLabel, "ARL · 网易云音乐"].contains(label)
        case .nasSMB: [storageLabel, "ARL · NAS 私有连接", "ARL · 网络硬盘"].contains(label)
        }
    }
    var service: String { "local.arl.credential-onboarding.v1." + rawValue }
    var account: String { "purpose-bound-local-entry" }
}
/// UI receives only a random identifier and an enumerated purpose; never a native Keychain reference.
public struct CredentialReference: Codable, Hashable, Sendable, CustomStringConvertible {
    public let id: UUID
    public let purpose: CredentialPurpose
    public var description: String { "CredentialReference(\(purpose.rawValue), opaque)" }
    init(id: UUID = UUID(), purpose: CredentialPurpose) { self.id = id; self.purpose = purpose }
}
public enum ConnectionState: String, Codable, Sendable {
    case notConfigured, savedUnverified, verified, revalidationRequired, invalidOrExpired, serviceExpired, permissionDenied
    case quotaExceeded, rateLimited, networkUnavailable, timedOut, vendorUnavailable, setupRequired
    case protocolFailure, credentialUnconfirmed, localStorageUnavailable, cancelled
    case loginRequired, sessionPresentUnverified, loginExpired
    public var title: String {
        switch self {
        case .loginRequired: "等待登录"
        case .sessionPresentUnverified: "登录待验"
        case .loginExpired: "已过期"
        case .notConfigured: "未配置"
        case .savedUnverified: "待验证"
        case .verified: "测试通过"
        case .revalidationRequired: "需要重验"
        case .invalidOrExpired: "登录失效"
        case .serviceExpired: "权限到期"
        case .permissionDenied: "权限不符"
        case .quotaExceeded: "额度不足"
        case .rateLimited: "请求频繁"
        case .networkUnavailable: "网络故障"
        case .timedOut: "连接超时"
        case .vendorUnavailable: "暂不可用"
        case .setupRequired: "待配置"
        case .protocolFailure: "结果未知"
        case .credentialUnconfirmed: "认证待验"
        case .localStorageUnavailable: "无法保存"
        case .cancelled: "已取消"
        }
    }
}
/// Bounded categories only; never a supplier message, arbitrary code or key fragment.
public enum TravelProviderDiagnostic: String, Codable, Sendable {
    case unrecognizedProviderCode, malformedMCPResponse, requestIDMismatch, ambiguousMCPResult, negativeControlNotRejected
    case unsupportedProtocolVersion, unsupportedReadToolContract, unsupportedSignVersion
    public var title: String {
        switch self {
        case .negativeControlNotRejected: "服务未拒绝无效密钥，认证结果未知"
        case .unrecognizedProviderCode: "服务返回状态未知，未判为成功"
        case .malformedMCPResponse: "服务返回格式不符"
        case .requestIDMismatch: "返回结果与本次请求不符"
        case .ambiguousMCPResult: "服务返回结果重复或冲突"
        case .unsupportedProtocolVersion: "服务连接版本不兼容"
        case .unsupportedReadToolContract: "服务读取功能不兼容"
        case .unsupportedSignVersion: "服务不接受当前签名版本"
        }
    }
}
public enum ExpiryKnowledge: String, Codable, Sendable { case unknown, rejectedInvalidOrExpired, vendorReportedServiceExpired }
public enum ValidationEvidence: String, Codable, Sendable { case none, amapWeatherResponse, flyaiReadOnlyResponse, flyaiDifferentialReadOnlyResponse, neteasePlaylistReadResponse }
/// Finite diagnostic values only. No vendor message, body, request URL, headers or credential fragment.
public struct ConnectionTestResult: Codable, Equatable, Sendable {
    public let state: ConnectionState
    public let checkedAt: Date
    public let evidence: ValidationEvidence
    public let expiryKnowledge: ExpiryKnowledge
    public let httpStatus: Int?
    public let diagnostic: TravelProviderDiagnostic?
    init(_ state: ConnectionState, at: Date = Date(), evidence: ValidationEvidence = .none, expiry: ExpiryKnowledge = .unknown, httpStatus: Int? = nil, diagnostic: TravelProviderDiagnostic? = nil) {
        self.state = state; checkedAt = at; self.evidence = evidence; expiryKnowledge = expiry
        self.httpStatus = httpStatus.flatMap { (100...599).contains($0) ? $0 : nil }; self.diagnostic = diagnostic
    }
}
public struct CredentialSnapshot: Codable, Sendable {
    public let purpose: CredentialPurpose
    public let reference: CredentialReference?
    public let state: ConnectionState
    public let lastTest: ConnectionTestResult?
    public var verifiedAt: Date? { lastTest?.state == .verified ? lastTest?.checkedAt : nil }
    public var explanation: String { purpose == .neteaseMusic ? ("登录已存不等于服务可用，写入另核对" + "\n" + "应用密钥和登录状态统一保存在 ARL。保存或存在登录状态不代表服务调用已验证；明确指定歌单和曲目的写入请求会先核对目标，再执行并读取核对确认。") : state == .verified ? ("仅代表所选只读接口在测试时通过；不能推断到期日期或其他用途权限。") : ("仅本机移除，服务方权限不变" + "\n" + "保存不等于连接已验证；本地移除不会撤销服务方 Key。") }
}
public struct LocalDisconnectReceipt: Encodable, Sendable {
    public let localRemoved: Bool
    public let providerRevoked: Bool = false
}
public enum CredentialError: String, Error, Sendable { case invalidInput, wrongPurpose, staleReference, alreadyConfigured, missing, storageUnavailable, deploymentNotApproved, identityMismatch, uncertainLocalState, busy }

/// Finite diagnostics only. No NSError userInfo, descriptions, paths or input.
public enum CredentialStorageOperation: String, Sendable {
    case environment, accessMetadata, metadataRead, creationRecovery, itemCreate, itemUpdate, credentialRead, itemRemove
}
public struct CredentialStorageFailure: Error, Sendable {
    public let operation: CredentialStorageOperation
    public let status: Int32
    public var message: String { ("保存结果未确认，请先核对状态" + "\n" + "本地安全存储操作结果未确认（\(operation.rawValue)，OSStatus \(status)）；保存或更新结果未确认，未自动重试，未调整访问权限。") }
}
public struct CredentialSubmissionResult: Sendable {
    public let snapshot: CredentialSnapshot
    public let recoveredExisting: Bool
    public let verificationFailure: String?
    public let saved: Bool
    public let candidateTest: ConnectionTestResult?
    public init(snapshot: CredentialSnapshot, recoveredExisting: Bool, verificationFailure: String?, saved: Bool = true, candidateTest: ConnectionTestResult? = nil) {
        self.snapshot = snapshot; self.recoveredExisting = recoveredExisting; self.verificationFailure = verificationFailure
        self.saved = saved; self.candidateTest = candidateTest
    }
    public var message: String {
        if !self.saved {
            return "本次未切换密钥，原配置保留。" + (verificationFailure.map { "\n" + $0 } ?? "")
        }
        let saved = recoveredExisting ? "已恢复上次保存的服务密钥，本次输入未替换原服务密钥。" : "服务密钥已保存。"
        if let verificationFailure {
            let summary = recoveredExisting ? "原密钥已恢复，本次验证未完成" : "密钥已保存，验证未完成"
            return summary + "\n" + saved + "验证未完成：" + verificationFailure
        }
        if snapshot.state == .verified {
            let summary = snapshot.purpose == .neteaseMusic ? "密钥已保存，歌单读取验证通过" : "密钥已保存，本次连接验证通过"
            let detail = saved + (snapshot.purpose == .neteaseMusic ? "网易云歌单读取验证通过。" : "连接验证通过。")
            return recoveredExisting ? detail : summary + "\n" + detail
        }
        if snapshot.state == .loginRequired {
            let detail = saved + "需要您扫码登录后才能使用网易云账号服务。"
            return recoveredExisting ? detail : "密钥已保存，网易云还需扫码登录" + "\n" + detail
        }
        return recoveredExisting ? saved + snapshot.state.title + "。" : "密钥已保存；" + snapshot.state.title + "\n" + saved + snapshot.state.title + "。"
    }
}
