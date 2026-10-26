import Foundation

public struct OnboardingPanel: Codable, Sendable {
    public let schemaVersion: Int
    public let title: String
    public let phase: String
    public let sourceOnly: Bool
    public let rows: [StatusRow]
    public let actions: [PanelAction]
    public let notice: String
    public let lastError: String?
    public let cleanup: String

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", sourceOnly = "source_only", lastError = "last_error"
        case title, phase, rows, actions, notice, cleanup
    }

    public struct StatusRow: Codable, Identifiable, Sendable {
        public let id: String
        public let title: String
        public let value: String
        public let detail: String
    }

    public struct PanelAction: Codable, Identifiable, Sendable {
        public let id: String
        public let label: String
        public let enabled: Bool
        public let reason: String
    }
}

public struct GroupChoice: Codable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let participants: [String]
}

public struct TestReview: Codable, Sendable {
    public let planID: String
    public let sendText: String
    public let receiveText: String
    public let confirmationText: String
    public let sendLimit: Int
    public let receiveLimit: Int
    public let audience: String

    enum CodingKeys: String, CodingKey {
        case planID = "plan_id", sendText = "send_text", receiveText = "receive_text"
        case confirmationText = "confirmation_text", sendLimit = "send_limit", receiveLimit = "receive_limit"
        case audience
    }
}

public enum OnboardingCommand: String, Sendable {
    case snapshot, begin, refresh, openMessages = "open_messages"
    case confirmAccount = "confirm_account", permissionAction = "permission_action"
    case discoverGroups = "discover_groups", selectGroup = "select_group"
    case prepareTest = "prepare_test", startTest = "start_test", verifyMio = "verify_mio"
    case disable, cancel, reconnect
}

public struct OnboardingRequest: Encodable, Sendable {
    public let schemaVersion = 1
    public let requestID: UUID
    public let command: String
    public let arguments: [String: String]
    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", requestID = "request_id", command, arguments
    }
    public init(_ command: OnboardingCommand, arguments: [String: String] = [:], requestID: UUID = UUID()) {
        self.requestID = requestID
        self.command = command.rawValue
        self.arguments = arguments
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(requestID.uuidString.lowercased(), forKey: .requestID)
        try container.encode(command, forKey: .command)
        try container.encode(arguments, forKey: .arguments)
    }
}

public struct OnboardingReply: Decodable, Sendable {
    public let schemaVersion: Int
    public let ok: Bool
    public let presentation: OnboardingPanel?
    public let candidates: [GroupChoice]?
    public let plan: TestReview?
    public let error: ErrorCode?
    public struct ErrorCode: Decodable, Sendable { public let code: String }
    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", ok, presentation, candidates, plan, error
    }
}
