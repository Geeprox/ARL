import Foundation

// App id alone is not an icon source: resource owners and application bundle
// identities must not share a cached image or a cached miss.
struct IconLookupKey: Hashable {
    let appID: String
    let bundleIdentifier: String?
    let resourceBundleURL: URL
}

struct IconSource: Hashable {
    enum Kind: String { case applicationBundle, bundledAsset }
    let kind: Kind
    let bundleIdentifier: String?
    let bundleURL: URL
    let bundleVersion: String?
    let resourceName: String?
}

struct IconResolution<Value> {
    let value: Value
    let source: IconSource
}

// Local, main-actor cache. The resolver and clock are injected so tests need
// neither NSWorkspace nor any real installed application or resource file.
@MainActor final class IconResolutionCache<Value> {
    private struct Entry {
        let resolution: IconResolution<Value>?
        let recordedAt: TimeInterval
    }
    private var entries: [IconLookupKey: Entry] = [:]
    private let positiveTTL: TimeInterval
    private let negativeTTL: TimeInterval
    private let maximumEntries: Int
    private let clock: @MainActor () -> TimeInterval
    private let resolver: @MainActor (IconLookupKey) -> IconResolution<Value>?

    init(positiveTTL: TimeInterval = 30, negativeTTL: TimeInterval = 5,
         maximumEntries: Int = 64,
         clock: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         resolver: @escaping @MainActor (IconLookupKey) -> IconResolution<Value>?) {
        precondition(positiveTTL.isFinite && positiveTTL > 0)
        precondition(negativeTTL.isFinite && negativeTTL > 0)
        precondition(maximumEntries > 0)
        self.positiveTTL = positiveTTL; self.negativeTTL = negativeTTL
        self.maximumEntries = maximumEntries; self.clock = clock; self.resolver = resolver
    }

    func resolution(for key: IconLookupKey) -> IconResolution<Value>? {
        let now = clock()
        if let entry = entries[key] {
            let age = now - entry.recordedAt
            let ttl = entry.resolution == nil ? negativeTTL : positiveTTL
            if now.isFinite, age >= 0, age < ttl { return entry.resolution }
        }
        let resolved = resolver(key)
        // An invalid/rewound clock must not turn either result into a permanent
        // hit. Production uses monotonic uptime; injected clocks can exercise it.
        guard now.isFinite else { entries.removeValue(forKey: key); return resolved }
        if entries[key] == nil, entries.count >= maximumEntries,
           let oldest = entries.min(by: { $0.value.recordedAt < $1.value.recordedAt })?.key {
            entries.removeValue(forKey: oldest)
        }
        entries[key] = Entry(resolution: resolved, recordedAt: now)
        return resolved
    }

    func invalidate(_ key: IconLookupKey) { entries.removeValue(forKey: key) }
    func invalidate(appID: String) { entries = entries.filter { $0.key.appID != appID } }
    func removeAll() { entries.removeAll() }
}
