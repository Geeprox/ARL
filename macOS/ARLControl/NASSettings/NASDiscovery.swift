import Foundation
import AppKit
import Combine
import Darwin

struct NASDiscoveredDevice: Identifiable, Equatable, Sendable {
    let id: String
    var name: String
    var host: String?
    var port = 445
    var addresses: [String] = []
    var shares: [String] = []
    var mounted = false
    var lastSeenAt: Date?
    var seenInCurrentScan = false
}

enum NASDiscoveryEvent: Sendable {
    case device(NASDiscoveredDevice), removed(String), finished, failed
}

@MainActor protocol NASDiscoveryDriver: AnyObject {
    func start(_ receive: @escaping @MainActor (NASDiscoveryEvent) -> Void)
    func stop()
}

@MainActor final class NASDiscoveryModel: ObservableObject {
    enum Phase: Equatable { case idle, searching, complete, cancelled, failed }
    @Published private(set) var devices: [NASDiscoveredDevice] = []
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var lastAttemptAt: Date?
    @Published private(set) var checkedAt: Date?
    @Published private(set) var lastFailureAt: Date?
    private let driver: any NASDiscoveryDriver
    private let now: @MainActor () -> Date
    private let foreground: @MainActor () -> Bool
    private let uptime: @MainActor () -> TimeInterval
    private var generation = UUID()
    private var identifiers: [String:String] = [:]
    private var failures = 0
    private var nextRefresh = -Double.infinity
    init(driver: any NASDiscoveryDriver = NASBonjourDiscovery(),
         now: @escaping @MainActor () -> Date = { Date() },
         uptime: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         foreground: @escaping @MainActor () -> Bool = { NSApplication.shared.isActive }) {
        self.driver=driver;self.now=now;self.uptime=uptime;self.foreground=foreground
    }
    /// View-owned polling may request a refresh; construction never starts discovery.
    func refreshIfNeeded() {
        guard phase != .searching,uptime() >= nextRefresh else { return }
        refresh()
    }
    func refresh() {
        guard phase != .searching else { return }
        cancel();phase = .searching;lastAttemptAt=now();identifiers=[:]
        devices=devices.map { value in var value=value;value.seenInCurrentScan=false;return value }
        let captured=generation
        driver.start { [weak self] event in
            guard let self,self.generation==captured,self.phase == .searching else { return }
            switch event {
            case .device(let device): self.accept(device)
            case .removed(let id):
                let stable=self.identifiers[id] ?? id
                if let index=self.devices.firstIndex(where:{$0.id==stable}) { self.devices[index].seenInCurrentScan=false }
            case .finished:
                self.driver.stop();self.phase = .complete;self.checkedAt=self.now();self.lastFailureAt=nil;self.failures=0
                self.nextRefresh=self.uptime()+(self.foreground() ? 30:120)
            case .failed:
                self.driver.stop();self.phase = .failed;self.lastFailureAt=self.now();self.failures=min(self.failures+1,5)
                self.nextRefresh=self.uptime()+[5.0,15,30,60,120][self.failures-1]
            }
        }
    }
    private func accept(_ device:NASDiscoveredDevice) {
        func host(_ value:String?) -> String? { value?.lowercased().trimmingCharacters(in:CharacterSet(charactersIn:".")) }
        let known=identifiers[device.id] ?? device.id
        let matches=devices.filter { old in
            old.id==known || old.id==device.id || (device.host != nil && host(old.host)==host(device.host) && old.port==device.port)
        }
        if matches.isEmpty,devices.count>=64 {
            guard let stale=devices.indices.filter({!devices[$0].seenInCurrentScan}).min(by:{
                (devices[$0].lastSeenAt ?? .distantPast)<(devices[$1].lastSeenAt ?? .distantPast)
            }) else { return }
            let removed=devices.remove(at:stale).id
            identifiers=identifiers.filter{$0.value != removed}
        }
        var merged=matches.first(where:{$0.host != nil}) ?? matches.first ?? device
        merged.name=device.name;merged.host=device.host ?? merged.host;merged.port=device.port
        for value in matches + [device] {
            merged.shares=Array(Set(merged.shares+value.shares)).sorted()
            merged.addresses=Array(Set(merged.addresses+value.addresses)).sorted()
            merged.mounted=merged.mounted || value.mounted
        }
        merged.lastSeenAt=now();merged.seenInCurrentScan=true
        let ids=Set(matches.map(\.id))
        identifiers=identifiers.mapValues{ids.contains($0) ? merged.id:$0}
        if identifiers.count<256 { identifiers[device.id]=merged.id }
        devices.removeAll{ids.contains($0.id)};devices.append(merged)
        devices.sort{$0.name.localizedStandardCompare($1.name) == .orderedAscending}
    }
    func cancel() { generation=UUID();driver.stop();if phase == .searching {phase = .cancelled} }
}

/// Bonjour and the kernel mount table only; no SMB session, port scan, file or keychain access.
@MainActor final class NASBonjourDiscovery: NSObject, NASDiscoveryDriver,
    @preconcurrency NetServiceBrowserDelegate, @preconcurrency NetServiceDelegate {
    private var browser: NetServiceBrowser?
    private var services: [String: NetService] = [:]
    private var receive: (@MainActor (NASDiscoveryEvent) -> Void)?
    private var deadline: Task<Void, Never>?

    func start(_ receive: @escaping @MainActor (NASDiscoveryEvent) -> Void) {
        stop(); self.receive = receive
        for device in Self.mountHints() { receive(.device(device)) }
        let browser = NetServiceBrowser(); self.browser = browser
        browser.delegate = self; browser.searchForServices(ofType: "_smb._tcp.", inDomain: "local.")
        deadline = Task { [weak self] in
            try? await Task.sleep(for: .seconds(9))
            guard !Task.isCancelled, let self else { return }
            let callback = self.receive; self.stop(); callback?(.finished)
        }
    }
    func stop() {
        deadline?.cancel(); deadline = nil
        browser?.delegate = nil; browser?.stop(); browser = nil
        for service in services.values { service.delegate = nil; service.stop() }
        services.removeAll(); receive = nil
    }
    private func key(_ service: NetService) -> String {
        "bonjour:" + service.name.lowercased() + "." + service.type.lowercased() + service.domain.lowercased()
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        guard browser === self.browser, services.count < 64 else { return }
        let id = key(service)
        guard services[id] == nil else { return }
        services[id] = service
        receive?(.device(.init(id: id, name: service.name)))
        service.delegate = self; service.resolve(withTimeout: 5)
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        guard browser === self.browser else { return }
        let id = key(service)
        if let old = services.removeValue(forKey: id) { old.delegate = nil; old.stop() }
        receive?(.removed(id))
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        guard browser === self.browser else { return }
        let callback = receive; stop(); callback?(.failed)
    }
    func netServiceDidResolveAddress(_ sender: NetService) {
        let id = key(sender)
        guard services[id] === sender, let host = sender.hostName,
              let parsed = try? NASAddressInput(host, port: sender.port) else { return }
        var addresses: [String] = []
        for bytes in sender.addresses ?? [] {
            // The current SMB runtime accepts DNS names and IPv4 literals.
            let value: String? = bytes.withUnsafeBytes { raw in
                guard raw.count >= MemoryLayout<sockaddr_in>.size,
                      let base = raw.baseAddress else { return nil }
                var address = base.loadUnaligned(as: sockaddr_in.self)
                guard Int32(address.sin_family) == AF_INET else { return nil }
                var output = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                guard inet_ntop(AF_INET, &address.sin_addr, &output, socklen_t(output.count)) != nil else { return nil }
                return String(decoding: output.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            }
            if let value { addresses.append(value) }
        }
        receive?(.device(.init(id: id, name: sender.name, host: parsed.host, port: parsed.port,
                              addresses: Array(Set(addresses)).sorted())))
    }

    static func mountHints() -> [NASDiscoveredDevice] {
        var table: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&table, MNT_NOWAIT)
        guard count > 0, count <= 4096, let table else { return [] }
        var result: [NASDiscoveredDevice] = []
        func string<T>(_ value: inout T) -> String {
            withUnsafeBytes(of: &value) { raw in
                String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
        }
        for index in 0..<Int(count) {
            var row = table[index]
            guard string(&row.f_fstypename) == "smbfs" else { continue }
            let source = string(&row.f_mntfromname)
            guard source.hasPrefix("//"), let url = URLComponents(string: "smb:" + source),
                  let host = url.host, url.query == nil, url.fragment == nil,
                  let share = url.path.split(separator: "/").first.map(String.init),
                  share.utf8.count <= 255, !share.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            else { continue }
            // Userinfo is deliberately discarded; only the non-secret endpoint/share are projected.
            let suffix = "._smb._tcp.local"
            let normalized = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            if normalized.hasSuffix(suffix) {
                let name = String(host.dropLast(suffix.count))
                result.append(.init(id: "bonjour:" + normalized + ".", name: name, shares: [share], mounted: true))
            } else if let parsed = try? NASAddressInput(host, port: url.port ?? 445) {
                result.append(.init(id: "mount:" + parsed.host.lowercased() + ":" + String(parsed.port),
                    name: parsed.host, host: parsed.host, port: parsed.port, shares: [share], mounted: true))
            }
            if result.count == 64 { break }
        }
        return result
    }
}
