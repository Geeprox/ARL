import Foundation
import SQLite3

@main struct ConnectedAppsUnit {
    static func main() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let uptime = ProcessInfo.processInfo.systemUptime
        let ms = Int(now.timeIntervalSince1970 * 1000)
        var cases: [[String: Any]] = []
        func check(_ name: String, _ passed: Bool) { cases.append(["name":name,"passed":passed]) }
        func app(_ connection: String = "connected", registration: String = "registered",
                 authentication: String = "verified", seen: Int? = nil, verified: Int? = nil) -> AppRegistration {
            ControlApp(id:"papercrane_42",name:"晚风 · 家庭照片",icon_ref:"sf:photo.on.rectangle",version:"2.1.0",
                registration:registration,connection:connection,authentication:authentication,authorization:"none",
                last_verified_at_ms:verified ?? ms,last_seen_at_ms:seen ?? ms,stale_after_ms:30000,
                advertised_capabilities:["media.catalog.read"],authorized_tools:[],handshake_session:String(repeating:"a",count:64),session_remaining_ms:max(0,min(30000,30000-max(ms-(seen ?? ms),ms-(verified ?? ms))))).presented(atUptime:uptime)
        }
        var legacy = app(); legacy.handshakeSession = nil
        check("verified-legacy-rpc-is-not-handshake", AppRegistration.connected([legacy],at:now).isEmpty)
        check("zero-connections-empty",AppRegistration.connected([],at:now).isEmpty)
        let current = AppRegistration.connected([app()],at:now)
        check("arbitrary-name-icon-version-from-metadata",current.count==1 && current[0].id=="papercrane_42" && current[0].name=="晚风 · 家庭照片" && current[0].symbol=="photo.on.rectangle" && current[0].version=="2.1.0")
        check("configuration-never-seen-is-not-connected",AppRegistration.connected([app("never_seen",registration:"unregistered",authentication:"unverified")],at:now).isEmpty)
        check("registered-without-connection-empty",AppRegistration.connected([app("never_seen")],at:now).isEmpty)
        check("disconnect-removes-primary-row",AppRegistration.connected([app("disconnected")],at:now).isEmpty)
        check("revocation-removes-primary-row",AppRegistration.connected([app(registration:"revoked")],at:now).isEmpty)
        check("unverified-removes-primary-row",AppRegistration.connected([app(authentication:"unverified")],at:now).isEmpty)
        check("explicit-stale-removes-primary-row",AppRegistration.connected([app("stale",authentication:"stale")],at:now).isEmpty)
        check("cached-connection-expires-without-refresh",AppRegistration.connected([app()],at:now.addingTimeInterval(30.001),uptime:uptime+31).isEmpty)
        check("seen-fresh-identity-expired-is-not-connected",AppRegistration.connected([app(verified:ms-30001)],at:now).isEmpty)
        check("identity-fresh-seen-expired-is-not-connected",AppRegistration.connected([app(seen:ms-30001)],at:now).isEmpty)
        check("wall-time-is-display-only-with-live-lease",AppRegistration.connected([app(seen:ms+1000)],at:now).count == 1)
        let cached = app()
        check("monotonic-expiry-retires-cache",!cached.isConnected(at:now,uptime:uptime+31))
        check("wall-rollback-cannot-revive-cache",!cached.isConnected(at:now.addingTimeInterval(-5000),uptime:uptime+31))
        check("retired-copy-cannot-revive",!cached.isConnected(at:now,uptime:uptime))
        let unsupported = ControlPlaneState().registry
        check("legacy-unsupported-does-not-create-app-rows",unsupported.value == nil)
        let entries = [app(),app("disconnected"),app("never_seen",registration:"unregistered",authentication:"unverified")]
        check("only-live-entry-remains",AppRegistration.connected(entries,at:now).count==1)
        for (name, passed) in try nasChecks(at: now) { check(name, passed) }
        for (name, passed) in try namingUsageChecks() { check(name, passed) }
        func friday(provider: String, cloud: Bool, fallback: Bool) -> FridayModelUsage {
            let counts = FridayModelUsage.Usage.Counts(requests:0,textTokens:0,images:0,voiceSeconds:0)
            return FridayModelUsage(config:.init(provider:provider,allowArlFallback:fallback,cloudText:cloud,responsesModel:"fixture"),
                usage:.init(used:counts,limits:counts,uncertainRequests:0),apiKeyConfigured:true,lastRoute:nil)
        }
        check("friday-auto-readback-requires-cloud-and-fallback",
            friday(provider:"auto",cloud:true,fallback:true).matches(.auto)
            && !friday(provider:"auto",cloud:true,fallback:false).matches(.auto)
            && !friday(provider:"auto",cloud:false,fallback:true).matches(.auto))
        check("friday-api-readback-does-not-match-fallback",
            friday(provider:"openai",cloud:true,fallback:false).matches(.openai)
            && !friday(provider:"openai",cloud:true,fallback:true).matches(.openai))
        check("friday-local-readback-ignores-old-cloud-settings",
            friday(provider:"local",cloud:true,fallback:true).matches(.local))
        let passed = cases.allSatisfy { $0["passed"] as? Bool == true }
        print(String(decoding:try JSONSerialization.data(withJSONObject:["passed":passed,"count":cases.count,"cases":cases],options:[.prettyPrinted,.sortedKeys]),as:UTF8.self))
        if !passed { exit(1) }
    }

    private static func namingUsageChecks() throws -> [(String, Bool)] {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let mount = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let control = mount.appendingPathComponent("Friday/services/llm-bridge/router/control")
        let expected = mount.appendingPathComponent("Friday/services/baby-naming/state/notebook.sqlite3")
        let discovered = NamingModelUsage.database(for: control.path, mounts: root)
        let outsideMount = NamingModelUsage.database(for: "/tmp/Friday/services/llm-bridge/router/control", mounts: root)
        let database = root.appendingPathComponent("naming-fixture.sqlite3")
        var connection: OpaquePointer?
        guard sqlite3_open(database.path, &connection) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        let setup = """
            CREATE TABLE receipts(id INTEGER PRIMARY KEY, date TEXT, status TEXT, tokens INT, model TEXT, usage_details TEXT);
            CREATE TABLE preference_runs(day TEXT, status TEXT, tokens INT);
            INSERT INTO receipts VALUES
                (1, '2026-01-01', 'complete', 11, 'gpt-6-luna', '{"service_tier":"default"}'),
                (2, '2026-01-02', 'complete', 24, 'gpt-6.1-sol', '{"service_tier":"fast"}'),
                (3, '2026-01-02', 'provider_timeout', NULL, 'gpt-6-luna', NULL);
            INSERT INTO preference_runs VALUES ('2026-01-02', 'complete', 17);
            """
        let result = sqlite3_exec(connection, setup, nil, nil, nil)
        sqlite3_close(connection)
        guard result == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        let before = try Data(contentsOf: database)
        let utc = ISO8601DateFormatter()
        let earlier = try NamingModelUsage.read(database: database, now: utc.date(from: "2026-01-01T15:59:59Z")!)
        let later = try NamingModelUsage.read(database: database, now: utc.date(from: "2026-01-01T16:00:00Z")!)
        let after = try Data(contentsOf: database)
        return [
            ("naming-uses-only-sibling-private-mount", discovered == expected && outsideMount == nil),
            ("naming-aggregates-both-ledgers-across-beijing-midnight", earlier.requests == 1 && earlier.tokens == 11
                && later.requests == 3 && later.successfulRequests == 2 && later.tokens == 41),
            ("naming-reads-model-tier-without-mutating-ledger", later.lastModel == "gpt-6.1-sol"
                && later.lastTier == "Fast" && before == after),
        ]
    }

    private static func nasChecks(at date: Date) throws -> [(String, Bool)] {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let revision = UUID().uuidString.lowercased()
        let apps = Dictionary(uniqueKeysWithValues: NASApplication.allCases.map {
            ($0.id, NASModelPolicy.Application(mode: .openaiPreferred, apiModel: "gpt-5-mini", dailyApiRequests: nil))
        })
        let policy = NASModelPolicy(schema: 1, revision: revision, globalDailyApiRequests: nil, apps: apps)
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        try encoder.encode(policy).write(to: directory.appendingPathComponent("policy.json"))
        let activity: [String: Any] = [
            "mode": "openai_preferred", "api_requests": 0, "reported_tokens": 0,
            "codex_ready": true, "last_provider": "codex", "last_status": 200,
        ]
        var status: [String: Any] = [
            "schema": 1, "applied_revision": revision, "updated_at": date.timeIntervalSince1970,
            "policy_invalid": false, "api_configured": true, "api_requests": 0,
            "apps": [
                "bilinote": activity,
                "pdf2zh": activity.filter { !["last_provider", "last_status"].contains($0.key) },
            ],
        ]
        let statusPath = directory.appendingPathComponent("status.json")
        try JSONSerialization.data(withJSONObject: status).write(to: statusPath)

        let snapshot = NASModelSettingsFile.snapshot(in: directory)
        let connected = snapshot.connection(for: .bilinote, at: date)
        let unverified = snapshot.connection(for: .pdf2zh, at: date)
        let missing = snapshot.connection(for: .robin, at: date)
        let stale = snapshot.connection(for: .bilinote, at: date.addingTimeInterval(16))

        var draft = policy
        draft.apps[NASApplication.pdf2zh.id]?.mode = .codex
        let saved = try NASModelSettingsFile.save(draft, directory: directory)
        let pendingSnapshot = NASModelSettingsFile.snapshot(in: directory)
        let pending = pendingSnapshot.connection(for: .pdf2zh, at: date)
        var rejectedOldRevision = false
        do {
            _ = try NASModelSettingsFile.save(policy, directory: directory)
        } catch NASModelSettingsFile.Failure.changed {
            rejectedOldRevision = true
        }
        status["policy_invalid"] = true
        try JSONSerialization.data(withJSONObject: status).write(to: statusPath)
        let invalid = NASModelSettingsFile.snapshot(in: directory).connection(for: .bilinote, at: date)
        return [
            ("nas-applied-mode-and-last-request-provider", connected.state == .connected
                && connected.route == .openaiPreferred && connected.lastProvider == "Codex"),
            ("nas-ready-catalog-is-not-app-request-evidence", unverified.state == .unverified),
            ("nas-missing-app-is-not-connected", missing.state == .pending && missing.route == nil),
            ("nas-stale-status-hides-route", stale.state == .unavailable && stale.route == nil),
            ("nas-switch-retains-model-limits-and-other-apps", saved.revision != revision && saved.apps == draft.apps
                && saved.globalDailyApiRequests == nil && pendingSnapshot.policy == saved),
            ("nas-pending-shows-applied-mode", pending.state == .pending && pending.route == .openaiPreferred),
            ("nas-stale-writer-is-rejected", rejectedOldRevision),
            ("nas-invalid-policy-shows-last-confirmed-mode", invalid.state == .invalid && invalid.route == .openaiPreferred),
        ]
    }
}
