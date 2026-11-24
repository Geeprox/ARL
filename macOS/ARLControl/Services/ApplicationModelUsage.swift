import Foundation
import SQLite3

extension NASModelStatus.Application {
    var recentRequest: String? {
        guard let provider = lastProviderTitle else { return nil }
        guard let status = lastStatus else { return provider + " · 进行中" }
        return provider + (200..<300 ~= status ? " · 成功" : " · 失败")
    }

    var fallbackReason: String? {
        switch lastReason {
        case "daily_api_limit": "达到 API 日上限"
        case "api_rate_or_quota": "OpenAI 限流或额度不足"
        case "api_unreachable", "api_unavailable": "OpenAI API 暂不可用"
        case "codex_unavailable": "Codex 暂不可用"
        case "api_result_unknown": "OpenAI API 未返回结果"
        default: nil
        }
    }
}

enum ApplicationModelUsageError: Error { case unavailable }

enum ApplicationModelHTTP {
    static func request(_ url: URL, method: String = "GET", origin: String? = nil,
                        body: Data? = nil) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 3)
        request.httpMethod = method
        if let origin { request.setValue(origin, forHTTPHeaderField: "Origin") }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (bytes, response) = try await session.bytes(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ApplicationModelUsageError.unavailable }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 16_384 else { throw ApplicationModelUsageError.unavailable }
            data.append(byte)
        }
        return data
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}

struct FridayModelUsage: Decodable, Sendable {
    enum Mode: String, CaseIterable, Identifiable, Sendable {
        case auto, openai, arl, local

        var id: String { rawValue }
        var title: String {
            switch self {
            case .auto: "API 优先，Codex 备用"
            case .openai: "仅 OpenAI API"
            case .arl: "ARL · Codex"
            case .local: "仅本地功能"
            }
        }

        var changes: [String: Any] {
            switch self {
            case .auto: ["provider": rawValue, "cloud_text": true, "allow_arl_fallback": true]
            case .openai: ["provider": rawValue, "cloud_text": true, "allow_arl_fallback": false]
            case .arl, .local: ["provider": rawValue]
            }
        }
    }

    struct Configuration: Decodable, Equatable, Sendable {
        let provider: String
        let allowArlFallback: Bool
        let cloudText: Bool
        let responsesModel: String
    }
    struct Usage: Decodable, Sendable {
        struct Counts: Decodable, Sendable {
            let requests: Int
            let textTokens: Int
            let images: Int
            let voiceSeconds: Int
        }
        let used: Counts
        let limits: Counts
        let uncertainRequests: Int
    }
    struct LastRoute: Decodable, Sendable {
        let provider: String
        let reason: String?
    }

    let config: Configuration
    let usage: Usage
    let apiKeyConfigured: Bool
    let lastRoute: LastRoute?
    static let appID = "com.friday.home.desktop"
    private static let origin = "http://127.0.0.1:8740"
    private static let endpoint = URL(string: "http://127.0.0.1:8740/api/settings/intelligence")!

    var mode: Mode? {
        switch config.provider {
        case "auto": .auto
        case "openai": config.allowArlFallback ? .auto : .openai
        case "arl": .arl
        case "local": .local
        default: nil
        }
    }

    var routeTitle: String {
        guard let mode else { return "通道未确认" }
        if mode == .auto || mode == .openai {
            if !apiKeyConfigured || !config.cloudText {
                return config.allowArlFallback ? "ARL · Codex 备用" : "OpenAI API 暂不可用"
            }
            if config.provider == "auto" && !config.allowArlFallback { return Mode.openai.title }
        }
        return mode.title
    }

    var recentRequest: String? {
        switch lastRoute?.provider {
        case "openai": "OpenAI API"
        case "arl": "ARL · Codex"
        case "local": "本地功能"
        default: nil
        }
    }

    func matches(_ requested: Mode) -> Bool {
        guard mode == requested else { return false }
        switch requested {
        case .auto: return config.cloudText && config.allowArlFallback
        case .openai: return config.cloudText && !config.allowArlFallback
        case .arl, .local: return true
        }
    }

    static func read() async throws -> Self {
        try decode(await ApplicationModelHTTP.request(endpoint))
    }

    static func save(_ mode: Mode, expected: Self) async throws -> Self {
        let current = try await read()
        guard current.config.provider == expected.config.provider,
              current.config.cloudText == expected.config.cloudText,
              current.config.allowArlFallback == expected.config.allowArlFallback
        else { throw ApplicationModelUsageError.unavailable }
        if mode == .auto || mode == .openai {
            guard current.apiKeyConfigured else { throw ApplicationModelUsageError.unavailable }
        }
        // 只提交现有文字通道设置，图片、语音和用量上限由 Friday 自己管理。
        let body = try JSONSerialization.data(withJSONObject: mode.changes)
        let result = try decode(await ApplicationModelHTTP.request(endpoint, method: "PUT", origin: origin, body: body))
        guard result.matches(mode) else {
            throw ApplicationModelUsageError.unavailable
        }
        return result
    }

    private static func decode(_ data: Data) throws -> Self {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Self.self, from: data)
    }
}

struct NamingModelUsage: Sendable {
    let requests: Int
    let tokens: Int
    let successfulRequests: Int
    let lastModel: String?
    let lastTier: String?

    static let title = "宝宝起名工作台"
    static let portal = URL(string: "http://friday.local/apps/baby-naming/")!

    static func database(for control: String, mounts: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/ARL/Moments/mounts", isDirectory: true)) -> URL? {
        let route = ["Friday", "services", "llm-bridge", "router", "control"]
        let directory = URL(fileURLWithPath: control, isDirectory: true).standardizedFileURL
        let components = directory.pathComponents
        let prefix = mounts.pathComponents
        guard components.starts(with: prefix), components.count == prefix.count + 1 + route.count,
              UUID(uuidString: components[prefix.count]) != nil,
              components.suffix(route.count).elementsEqual(route)
        else { return nil }
        let services = directory.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return services.appendingPathComponent("baby-naming/state/notebook.sqlite3")
    }

    static func online() async -> Bool {
        guard let bytes = try? await ApplicationModelHTTP.request(portal.appendingPathComponent("health")),
              let value = try? JSONDecoder().decode([String: String].self, from: bytes) else { return false }
        return value["status"] == "ready"
    }

    static func read(database: URL, now: Date = .now) throws -> Self {
        let values = try database.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink == false,
              let size = values.fileSize, (1...64_000_000).contains(size) else { throw ApplicationModelUsageError.unavailable }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd"
        let day = formatter.string(from: now)
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_NOFOLLOW
        guard sqlite3_open_v2(database.path, &db, flags, nil) == SQLITE_OK,
              sqlite3_db_readonly(db, "main") == 1 else { throw ApplicationModelUsageError.unavailable }
        sqlite3_busy_timeout(db, 250)
        guard sqlite3_exec(db, "PRAGMA query_only=ON; PRAGMA trusted_schema=OFF;", nil, nil, nil) == SQLITE_OK else {
            throw ApplicationModelUsageError.unavailable
        }
        let sql = """
            WITH today AS (
                SELECT tokens, status FROM receipts WHERE date=?1
                UNION ALL
                SELECT tokens, status FROM preference_runs WHERE day=?1
            )
            SELECT count(*), COALESCE(sum(tokens), 0), COALESCE(sum(status='complete'), 0)
            FROM today
            """
        var totals: OpaquePointer?
        defer { sqlite3_finalize(totals) }
        guard sqlite3_prepare_v2(db, sql, -1, &totals, nil) == SQLITE_OK else { throw ApplicationModelUsageError.unavailable }
        let bound = day.withCString { sqlite3_bind_text(totals, 1, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        guard bound == SQLITE_OK, sqlite3_step(totals) == SQLITE_ROW else { throw ApplicationModelUsageError.unavailable }
        let last = latestModel(in: db)
        return Self(requests: Int(sqlite3_column_int64(totals, 0)), tokens: Int(sqlite3_column_int64(totals, 1)),
                    successfulRequests: Int(sqlite3_column_int64(totals, 2)), lastModel: last.0, lastTier: last.1)
    }

    private static func latestModel(in db: OpaquePointer?) -> (String?, String?) {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = """
            SELECT model, json_extract(usage_details, '$.service_tier') FROM receipts
            WHERE status='complete' AND model IS NOT NULL ORDER BY id DESC LIMIT 1
            """
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW,
              let modelValue = sqlite3_column_text(statement, 0) else { return (nil, nil) }
        let model = String(cString: modelValue)
        guard model.range(of: "^gpt-[a-zA-Z0-9._-]{1,80}$", options: .regularExpression) != nil else {
            return (nil, nil)
        }
        let tier = sqlite3_column_text(statement, 1).map { String(cString: $0) }
        return (model, tier == "fast" ? "Fast" : tier == "default" ? "标准" : nil)
    }
}
