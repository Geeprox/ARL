import CoreImage
import Foundation

private struct FixtureGate: DeploymentGate { func verify() throws {} }
private enum Failure: Error { case check(String) }
private struct URLCase: Decodable { let name: String; let url: String; let reason: String? }
private final class Events: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    private var diagnostics: [MusicDiagnostic] = []
    func receive(_ url: URL) { lock.withLock { urls.append(url) } }
    func receive(_ value: MusicDiagnostic) { lock.withLock { diagnostics.append(value) } }
    var received: [URL] { lock.withLock { urls } }
    var trace: [MusicDiagnostic] { lock.withLock { diagnostics } }
}

@main @MainActor enum NetEaseQRHostTests {
    static var checks: [String] = []
    static func check(_ value: Bool, _ name: String) throws {
        guard value else { throw Failure.check(name) }
        checks.append(name)
    }
    static func input() throws -> CredentialInput {
        let device = try JSONSerialization.data(withJSONObject: ["deviceId":"00000000-0000-4000-8000-000000000001"])
        let encrypted = try JSONSerialization.data(withJSONObject: ["iv":String(repeating:"0",count:32),"data":String(repeating:"0",count:32)])
        return try CredentialInput(purpose: .neteaseMusic, data: JSONSerialization.data(withJSONObject: ["schema":1,"storage":"official","files":[".netease_mcp_device.json":device.base64EncodedString(),".config/ncm-cli/credentials.enc.json":encrypted.base64EncodedString()]]))
    }
    static func main() async throws {
        guard CommandLine.arguments.count == 3 else { throw Failure.check("arguments") }
        let cases = try JSONDecoder().decode([URLCase].self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        let fixtures = URL(fileURLWithPath: CommandLine.arguments[2])
        let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy:CIDetectorAccuracyHigh])
        for item in cases {
            let parsed = URL(string: item.url)
            let accepted = parsed.flatMap(MusicLoginURL.validated)
            try check((accepted != nil) == (item.reason == nil), "url_" + item.name)
            if let accepted {
                guard let image = MusicLoginPresentation.render(accepted) else { throw Failure.check("render_" + item.name) }
                let decoded = detector?.features(in: CIImage(cgImage: image)).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
                try check(decoded == [accepted.absoluteString], "local_QR_roundtrip_" + item.name)
            } else if let parsed {
                try check(MusicLoginPresentation.render(parsed) == nil, "render_refuses_" + item.name)
            }
        }
        let runtimeNames = Set(["official_short","official_query","existing_music","short_subdomain","suffix_attack","image_cdn","insecure","userinfo","other_port"])
        for item in cases where runtimeNames.contains(item.name) {
            let events = Events(), owner = MusicReadProcessOwner()
            let trace = MusicDiagnosticTrace(sink: { events.receive($0) })
            let runtime = MusicRuntimeClient(gate: FixtureGate(), bundleURL: fixtures.appendingPathComponent(item.name + ".app"), processOwner: owner)
            let credential = try input()
            defer { credential.clear() }
            do {
                let result = try await MusicDiagnostics.$current.withValue(trace) {
                    try await runtime.send(credential, operation: .login, onLoginURL: { events.receive($0) })
                }
                defer { result.credential.clear() }
                try check(item.reason == nil && result.state == .credentialUnconfirmed, "runtime_unconfirmed_" + item.name)
            } catch let failure as MusicDiagnosticFailure {
                try check(item.reason != nil && failure.diagnostic.reasonCode == .qr_frame_invalid, "runtime_refuses_" + item.name)
            }
            try check(owner.status().provedIdle, "child_cleanup_" + item.name)
            try check(events.received.count == (item.reason == nil ? 1 : 0), "callback_count_" + item.name)
            if item.reason == nil {
                try check(events.received.first?.absoluteString == item.url, "payload_unchanged_" + item.name)
            }
            let encoded = String(decoding: try JSONEncoder().encode(events.trace), as: UTF8.self)
            try check(!encoded.contains("163cn.tv") && !encoded.contains("https:") && !encoded.contains("ARL-SYNTHETIC"), "diagnostic_redaction_" + item.name)
        }
        print(String(decoding: try JSONSerialization.data(withJSONObject: ["status":"PASS","checks":checks.count,"passed":checks,"real_provider_calls":0,"real_keychain_calls":0,"app_launches":0]), as: UTF8.self))
    }
}
