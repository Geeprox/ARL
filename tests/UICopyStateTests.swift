import Foundation
import ARLCredentialOnboarding

// Production display states only. No credentials, network, Keychain, or effect owner.
@main enum UICopyStateTests {
    static func main() throws {
        let labels: [(ConnectionState, String)] = [
            (.notConfigured, "未配置"), (.savedUnverified, "待验证"),
            (.loginRequired, "等待登录"), (.sessionPresentUnverified, "登录待验"),
            (.verified, "测试通过"), (.protocolFailure, "结果未知"),
            (.networkUnavailable, "网络故障"), (.localStorageUnavailable, "无法保存")
        ]
        for (state, label) in labels {
            precondition(state.title == label)
            precondition((2...4).contains(state.title.count))
            let encoded = try JSONEncoder().encode(state)
            let decoded = try JSONDecoder().decode(ConnectionState.self, from: encoded)
            precondition(decoded == state && decoded.rawValue == state.rawValue)
        }
        let pending = labels.filter { $0.0 != .verified }.map(\.1)
        precondition(!pending.contains(ConnectionState.verified.title))
        precondition(ConnectionState.savedUnverified.title != ConnectionState.loginRequired.title)
        print("PASS: production connection labels preserve separate saved, login, verified, and failed states; wire roundtrips unchanged")
    }
}
