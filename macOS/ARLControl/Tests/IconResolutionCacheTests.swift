import Foundation

// Synthetic-only, standalone unit executable. Compile it with the production
// IconResolutionCache.swift, not a copied/reimplemented cache. No AppKit, app
// launch, disk fixture, NSWorkspace, network, environment access, or test sleeps.
@main @MainActor struct IconResolutionCacheTests {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }
    @MainActor final class Fixture {
        var now: TimeInterval = 100
        var responses: [IconLookupKey: IconResolution<String>] = [:]
        var calls: [IconLookupKey: Int] = [:]
        func resolve(_ key: IconLookupKey) -> IconResolution<String>? {
            calls[key, default: 0] += 1
            return responses[key]
        }
        func makeCache(maximumEntries: Int = 64) -> IconResolutionCache<String> {
            IconResolutionCache(maximumEntries: maximumEntries, clock: { self.now }, resolver: resolve)
        }
    }

    static func key(_ owner: String = "synthetic-resource-owner-A",
                    bundle: String? = "synthetic.app-A") -> IconLookupKey {
        IconLookupKey(appID: "synthetic-app", bundleIdentifier: bundle,
                      resourceBundleURL: URL(fileURLWithPath: "/synthetic-not-read/" + owner))
    }
    static func icon(_ label: String, version: String = "1",
                     location: String = "app-A", kind: IconSource.Kind = .applicationBundle,
                     bundleIdentifier: String = "synthetic.app-A") -> IconResolution<String> {
        IconResolution(value: label, source: IconSource(kind: kind, bundleIdentifier: bundleIdentifier,
            bundleURL: URL(fileURLWithPath: "/synthetic-not-read/" + location),
            bundleVersion: version, resourceName: kind == .bundledAsset ? "synthetic-app.png" : nil))
    }
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(description: message) }
    }

    static func missThenInstallation() throws {
        let fixture = Fixture(), request = key()
        let cache = fixture.makeCache()
        try expect(cache.resolution(for: request) == nil, "Initially absent app must have no image")
        fixture.responses[request] = icon("installed")
        fixture.now += 4.999
        try expect(cache.resolution(for: request) == nil, "A miss may be reused only inside its short TTL")
        try expect(fixture.calls[request] == 1, "Miss reuse must avoid repeated resolver work")
        fixture.now = 105
        try expect(cache.resolution(for: request)?.value == "installed", "Installation must appear at the miss TTL boundary")
        try expect(fixture.calls[request] == 2, "Miss expiry must call the injected resolver")
    }

    static func versionUpdateAndRemoval() throws {
        let fixture = Fixture(), request = key()
        let cache = fixture.makeCache()
        fixture.responses[request] = icon("version-one")
        try expect(cache.resolution(for: request)?.source.bundleVersion == "1", "Initial source version must be retained")
        fixture.responses[request] = icon("version-two", version: "2")
        fixture.now += 29.999
        try expect(cache.resolution(for: request)?.value == "version-one", "Positive reuse must remain bounded")
        fixture.now = 130
        let updated = cache.resolution(for: request)
        try expect(updated?.value == "version-two" && updated?.source.bundleVersion == "2", "Expiry must replace both image and source version")
        fixture.responses.removeValue(forKey: request)
        fixture.now = 160
        try expect(cache.resolution(for: request) == nil, "Removed application must not retain its positive image")
        fixture.responses[request] = icon("reinstalled", version: "3")
        fixture.now = 165
        try expect(cache.resolution(for: request)?.value == "reinstalled", "Removal must not create a permanent miss")
    }

    static func sameIDDifferentSources() throws {
        let fixture = Fixture()
        let first = key(), otherResourceOwner = key("synthetic-resource-owner-B")
        let otherBundle = key(bundle: "synthetic.app-B")
        let cache = fixture.makeCache()
        fixture.responses[first] = icon("bundle-A")
        fixture.responses[otherResourceOwner] = icon("asset-B", location: "synthetic-resource-owner-B", kind: .bundledAsset,
                                                    bundleIdentifier: "synthetic.resource-owner-B")
        fixture.responses[otherBundle] = icon("bundle-B", location: "app-B", bundleIdentifier: "synthetic.app-B")
        let a = cache.resolution(for: first), b = cache.resolution(for: otherResourceOwner)
        let c = cache.resolution(for: otherBundle)
        try expect(a?.value == "bundle-A" && b?.value == "asset-B" && c?.value == "bundle-B", "Same app id must isolate real bundle/resource scopes")
        try expect(a?.source != b?.source && a?.source != c?.source, "Different actual sources must retain their own identity")
        cache.invalidate(otherResourceOwner)
        fixture.responses.removeValue(forKey: otherResourceOwner)
        try expect(cache.resolution(for: otherResourceOwner) == nil, "One source can become absent")
        try expect(cache.resolution(for: first)?.value == "bundle-A", "A foreign miss must not poison the original scope")
        try expect(fixture.calls[first] == 1, "Invalidating one scope must preserve another scope's positive cache")
        fixture.responses[first] = icon("bundle-A-at-new-location", version: "2", location: "app-A-moved")
        fixture.now = 130
        try expect(cache.resolution(for: first)?.source.bundleURL.lastPathComponent == "app-A-moved", "Changed actual app location must replace prior source after bounded expiry")
    }

    static func explicitRefreshAndClock() throws {
        let fixture = Fixture(), request = key()
        let cache = fixture.makeCache()
        try expect(cache.resolution(for: request) == nil, "Refresh setup starts with a miss")
        fixture.responses[request] = icon("now-present")
        cache.invalidate(appID: request.appID)
        try expect(cache.resolution(for: request)?.value == "now-present", "Explicit refresh must clear a miss immediately")
        fixture.responses[request] = icon("now-updated", version: "2")
        cache.removeAll()
        try expect(cache.resolution(for: request)?.value == "now-updated", "Explicit refresh must also clear a hit")
        fixture.responses[request] = icon("rewound-clock")
        fixture.now = 99
        try expect(cache.resolution(for: request)?.value == "rewound-clock", "A rewound clock must not extend old cache lifetime")
        fixture.now = .nan
        _ = cache.resolution(for: request)
        let calls = fixture.calls[request]
        _ = cache.resolution(for: request)
        try expect(fixture.calls[request] == calls.map { $0 + 1 }, "An invalid clock must not cache indefinitely")
    }

    static func boundedStorage() throws {
        let fixture = Fixture(), first = key("oldest"), second = key("middle"), third = key("newest")
        let cache = fixture.makeCache(maximumEntries: 2)
        fixture.responses[first] = icon("one"); fixture.responses[second] = icon("two"); fixture.responses[third] = icon("three")
        _ = cache.resolution(for: first)
        fixture.now += 1; _ = cache.resolution(for: second)
        fixture.now += 1; _ = cache.resolution(for: third)
        _ = cache.resolution(for: first)
        try expect(fixture.calls[first] == 2, "A bounded cache must release its oldest entry")
    }

    static func main() throws {
        try missThenInstallation()
        try versionUpdateAndRemoval()
        try sameIDDifferentSources()
        try explicitRefreshAndClock()
        try boundedStorage()
        print("Synthetic icon cache behavior checks passed; no real App or visual verification")
    }
}
