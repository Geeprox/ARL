import Foundation
import Observation

enum NASApplication: String, CaseIterable, Identifiable, Sendable {
    case bilinote, pdf2zh, robin

    var id: String { rawValue }

    var name: String {
        switch self {
        case .bilinote: "BiliNote"
        case .pdf2zh: "PDFMathTranslate"
        case .robin: "Robin"
        }
    }

    var symbol: String {
        switch self {
        case .bilinote: "text.bubble"
        case .pdf2zh: "doc.richtext"
        case .robin: "magnifyingglass"
        }
    }
}

enum NASModelRoute: String, Codable, CaseIterable, Sendable {
    case codex, openai
    case codexPreferred = "codex_preferred"
    case openaiPreferred = "openai_preferred"

    var title: String {
        switch self {
        case .codex: "仅 Codex"
        case .openai: "仅 OpenAI API"
        case .codexPreferred: "Codex 优先，API 备用"
        case .openaiPreferred: "API 优先，Codex 备用"
        }
    }
}

struct NASModelPolicy: Codable, Equatable, Sendable {
    struct Application: Codable, Equatable, Sendable {
        var mode: NASModelRoute
        var apiModel: String
        var dailyApiRequests: Int?
    }
    var schema: Int
    var revision: String
    var globalDailyApiRequests: Int?
    var apps: [String: Application]

    var valid: Bool {
        schema == 1 && UUID(uuidString: revision) != nil && !apps.isEmpty
        && apps.keys.allSatisfy { NASApplication(rawValue: $0) != nil }
        && Self.validLimit(globalDailyApiRequests)
        && apps.values.allSatisfy {
            Self.validLimit($0.dailyApiRequests)
            && $0.apiModel.range(of: "^gpt-[A-Za-z0-9._-]{1,95}$", options: .regularExpression) != nil
        }
    }

    private static func validLimit(_ limit: Int?) -> Bool {
        limit.map { (0...100_000).contains($0) } ?? true
    }
}

struct NASModelStatus: Decodable, Sendable {
    struct Application: Decodable, Sendable {
        let mode: NASModelRoute
        let dailyApiRequests: Int?
        let apiRequests: Int
        let reportedTokens: Int
        let codexReady: Bool
        let lastProvider: String?
        let lastReason: String?
        let lastStatus: Int?

        var lastProviderTitle: String? {
            switch lastProvider {
            case "codex": "Codex"
            case "openai": "OpenAI API"
            default: nil
            }
        }
    }
    let schema: Int
    let appliedRevision: String
    let updatedAt: TimeInterval
    let policyInvalid: Bool
    let apiConfigured: Bool
    let apiRequests: Int
    let globalDailyApiRequests: Int?
    let apps: [String: Application]

    var fresh: Bool { isFresh(at: .now) }

    func isFresh(at date: Date) -> Bool {
        let age = date.timeIntervalSince1970 - updatedAt
        return schema == 1 && (-5...15).contains(age)
    }
}

struct NASModelConnection: Equatable {
    enum State: Equatable {
        case connected, unverified, pending, invalid, unavailable

        var title: String {
            switch self {
            case .connected: "NAS 已接入"
            case .unverified: "NAS 已配置，待首次请求"
            case .pending: "等待 NAS 应用"
            case .invalid: "NAS 配置异常"
            case .unavailable: "NAS 状态暂不可用"
            }
        }
    }
    let state: State
    var route: NASModelRoute?
    var lastProvider: String?
}

struct NASModelRoutingSnapshot: Sendable {
    var policy: NASModelPolicy?
    var status: NASModelStatus?

    func connection(for app: NASApplication, at date: Date) -> NASModelConnection {
        guard let status, status.isFresh(at: date) else {
            return NASModelConnection(state: .unavailable)
        }
        let activity = status.apps[app.id]
        let state: NASModelConnection.State
        if status.policyInvalid {
            state = .invalid
        } else if activity == nil || policy.map({ $0.revision != status.appliedRevision }) == true {
            state = .pending
        } else if activity?.lastProviderTitle != nil {
            state = .connected
        } else {
            state = .unverified
        }
        return NASModelConnection(state: state, route: activity?.mode, lastProvider: activity?.lastProviderTitle)
    }
}

enum NASModelSettingsFile {
    enum Failure: Error { case invalid, changed }

    private static let writeLock = NSLock()

    static func read<T: Decodable>(_ type: T.Type, _ url: URL) throws -> T {
        let attributes = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard attributes.isRegularFile == true, attributes.isSymbolicLink == false,
              (1...32_768).contains(attributes.fileSize ?? 0) else { throw Failure.invalid }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: Data(contentsOf: url))
    }

    static func discover() -> String? {
        let mounts = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ARL/Moments/mounts", isDirectory: true)
        let folders = (try? FileManager.default.contentsOfDirectory(at: mounts, includingPropertiesForKeys: nil)) ?? []
        let controls = folders.map { $0.appendingPathComponent("Friday/services/llm-bridge/router/control", isDirectory: true) }
            .filter { (try? read(NASModelPolicy.self, $0.appendingPathComponent("policy.json")))?.valid == true }
        return controls.count == 1 ? controls.first?.path : nil
    }

    static func snapshot(in directory: URL) -> NASModelRoutingSnapshot {
        let policy = try? read(NASModelPolicy.self, directory.appendingPathComponent("policy.json"))
        let status = try? read(NASModelStatus.self, directory.appendingPathComponent("status.json"))
        return NASModelRoutingSnapshot(policy: policy?.valid == true ? policy : nil, status: status)
    }

    static func save(_ draft: NASModelPolicy, directory: URL) throws -> NASModelPolicy {
        try writeLock.withLock {
            let file = directory.appendingPathComponent("policy.json")
            let current = try read(NASModelPolicy.self, file)
            guard current.revision == draft.revision, current.valid else { throw Failure.changed }
            guard draft.valid, Set(draft.apps.keys) == Set(current.apps.keys) else { throw Failure.invalid }
            var updated = draft
            updated.revision = UUID().uuidString.lowercased()
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(updated).write(to: file, options: .atomic)
            return updated
        }
    }
}

@MainActor @Observable
final class NASModelRoutingMonitor {
    private(set) var snapshot = NASModelRoutingSnapshot()
    private(set) var applications: [NASApplication] = []
    private(set) var path = ""
    private(set) var checked = false
    @ObservationIgnored private var writeGeneration = 0
    private let cacheKey = "nasModelApplicationCache"

    func monitor(_ path: String, onDiscovery: (String) -> Void) async {
        if self.path != path {
            self.path = path
            snapshot = NASModelRoutingSnapshot()
            let cache = UserDefaults.standard.dictionary(forKey: cacheKey)
            let stored = cache?["path"] as? String == path ? cache?["apps"] as? [String] : nil
            applications = NASApplication.allCases.filter { stored?.contains($0.id) == true }
            checked = false
        }
        while path.isEmpty && !Task.isCancelled {
            let found = await Task.detached { NASModelSettingsFile.discover() }.value
            guard !Task.isCancelled else { return }
            if let found {
                onDiscovery(found)
                return
            }
            try? await Task.sleep(for: .seconds(15))
        }
        guard !Task.isCancelled, !path.isEmpty else {
            return
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        while !Task.isCancelled {
            let generation = writeGeneration
            let latest = await Task.detached { NASModelSettingsFile.snapshot(in: directory) }.value
            guard !Task.isCancelled, self.path == path else { return }
            if writeGeneration == generation {
                snapshot = latest
                if let policy = latest.policy { updateApplications(Set(policy.apps.keys), at: path) }
                else if let status = latest.status, status.fresh { updateApplications(Set(status.apps.keys), at: path) }
                checked = true
            }
            try? await Task.sleep(for: .seconds(3))
        }
    }

    func save(_ draft: NASModelPolicy, in path: String) async throws -> NASModelPolicy {
        guard self.path == path, !path.isEmpty else { throw NASModelSettingsFile.Failure.changed }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        let updated = try await Task.detached { try NASModelSettingsFile.save(draft, directory: directory) }.value
        if self.path == path {
            writeGeneration += 1
            snapshot.policy = updated
        }
        return updated
    }

    private func updateApplications(_ ids: Set<String>, at path: String) {
        let known = NASApplication.allCases.filter { ids.contains($0.id) }
        guard known != applications else { return }
        applications = known
        UserDefaults.standard.set(["path": path, "apps": known.map(\.id)], forKey: cacheKey)
    }
}
