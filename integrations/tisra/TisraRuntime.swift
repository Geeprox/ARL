import Foundation

/// Standalone module for Tisra's explicit action path. Does not replace
/// ResearchService's reviewed evidence/ledger/OpenAI response contract.
public enum TisraRuntimeStatus: Sendable, Equatable {
    case disabled, offline, starting, ready(version: String), userStopped, unverified, failed(code: String)
}
public struct ReviewedARLAction: Sendable {
    public let id: UUID
    public let tool: String
    public let args: [String: ARLJSON]
    public static func ping(id: UUID) -> Self { .init(id: id, tool: "runtime.ping", args: [:]) }
    public static func digest(id: UUID, text: String) -> Self {
        .init(id: id, tool: "text.sha256", args: ["text": .string(text)])
    }
}

public actor TisraRuntime {
    private let client: ARLClient
    private let home: URL
    private let enabled: Bool
    public private(set) var status: TisraRuntimeStatus = .disabled
    public init(home: URL, enabled: Bool = false, trustedLauncher: (@Sendable () throws -> Void)? = nil) {
        self.enabled = enabled
        self.home = home
        self.client = ARLClient(home: home, app: "tisra", launcher: trustedLauncher)
    }
    /// Passive health/capability discovery. No launch or model calls.
    public func refresh() async -> TisraRuntimeStatus {
        guard enabled else { status = .disabled; return status }
        if FileManager.default.fileExists(atPath: home.appendingPathComponent("disabled").path) {
            status = .userStopped; return status
        }
        do {
            let health = try await client.rpc("health")
            guard health["ready"] == .bool(true) else { status = .starting; return status }
            let capabilities = try await client.rpc("capabilities")
            guard capabilities["protocol"] == .string("arl/1"), capabilities["version"] == .number(1) else {
                throw ARLError(code: "unsupported_capability_version")
            }
            status = .ready(version: health["version"]?.text ?? "unknown")
        } catch let error as ARLError {
            status = switch error.code {
            case "disconnected": .offline
            case "not_ready": .starting
            case "user_disabled": .userStopped
            case "app_identity_unverified": .unverified
            default: .failed(code: error.code)
            }
        } catch { status = .failed(code: "runtime_error") }
        return status
    }
    /// Only call from an explicit user action or an already-scoped authorization.
    /// Constructor, typing, autosave, context selection and refresh never execute.
    public func submit(_ reviewed: ReviewedARLAction) async throws -> ARLJSON {
        guard enabled else { throw ARLError(code: "integration_disabled") }
        return try await client.submit(tool: reviewed.tool, args: reviewed.args,
                                       key: "tisra-action:" + reviewed.id.uuidString.lowercased())
    }
    public func receipt(id: String) async throws -> ARLJSON {
        guard enabled else { throw ARLError(code: "integration_disabled") }
        return try await client.rpc("get", params: ["id": .string(id)])
    }
    public func cancel(id: String) async throws -> ARLJSON {
        guard enabled else { throw ARLError(code: "integration_disabled") }
        return try await client.rpc("cancel", params: ["id": .string(id)])
    }
    public func wakeEvents() async throws -> ARLJSON {
        guard enabled else { throw ARLError(code: "integration_disabled") }
        return try await client.rpc("poll_wakes")
    }
}
