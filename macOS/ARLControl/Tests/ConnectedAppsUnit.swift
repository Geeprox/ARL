import Foundation

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
        let passed = cases.allSatisfy { $0["passed"] as? Bool == true }
        print(String(decoding:try JSONSerialization.data(withJSONObject:["passed":passed,"count":cases.count,"cases":cases],options:[.prettyPrinted,.sortedKeys]),as:UTF8.self))
        if !passed { exit(1) }
    }
}
