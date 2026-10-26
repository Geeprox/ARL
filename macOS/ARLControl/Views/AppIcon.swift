import SwiftUI
import AppKit
import ImageIO

@MainActor enum IconCache {
    static let refreshInterval: TimeInterval = 5
    private static let bundles = ["notes": "com.apple.Notes", "reminders": "com.apple.reminders", "calendar": "com.apple.iCal", "messages": "com.apple.MobileSMS", "imessage": "com.apple.MobileSMS", "codex_app_server": "com.openai.codex"]
    private static let cache = IconResolutionCache<NSImage>(resolver: resolve)

    // The tick is a SwiftUI dependency, not an app connection timestamp.
    // Cache expiry uses monotonic uptime, independently of the wall-clock tick.
    static func image(_ id: String, refreshAt _: Date = .now) -> NSImage? {
        let key = IconLookupKey(appID: id, bundleIdentifier: bundles[id],
                                resourceBundleURL: Bundle.main.bundleURL.standardizedFileURL)
        return cache.resolution(for: key)?.value
    }

    // Explicit refresh releases both hits and misses. The next visible tick or
    // lookup resolves again; this API does not launch or discover arbitrary apps.
    static func invalidate(_ id: String? = nil) {
        if let id { cache.invalidate(appID: id) } else { cache.removeAll() }
    }

    private static func resolve(_ key: IconLookupKey) -> IconResolution<NSImage>? {
        guard key.resourceBundleURL == Bundle.main.bundleURL.standardizedFileURL,
              key.bundleIdentifier == bundles[key.appID] else { return nil }
        if let identifier = key.bundleIdentifier,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier),
           let values = try? url.resourceValues(forKeys: [.isDirectoryKey]), values.isDirectory == true,
           let bundle = Bundle(url: url), bundle.bundleIdentifier == identifier {
            let source = IconSource(kind: .applicationBundle, bundleIdentifier: identifier,
                                    bundleURL: url.standardizedFileURL,
                                    bundleVersion: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
                                    resourceName: nil)
            return IconResolution(value: NSWorkspace.shared.icon(forFile: url.path), source: source)
        }
        // Only a resource name in this application's fixed BrandAssets folder.
        // No URL/path supplied by registry metadata or a remote icon endpoint.
        guard isResourceName(key.appID),
              let url = Bundle.main.url(forResource: key.appID, withExtension: "png", subdirectory: "BrandAssets"),
              let image = NSImage(contentsOf: url) else { return nil }
        let source = IconSource(kind: .bundledAsset, bundleIdentifier: Bundle.main.bundleIdentifier,
                                bundleURL: Bundle.main.bundleURL.standardizedFileURL,
                                bundleVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
                                resourceName: key.appID + ".png")
        return IconResolution(value: image, source: source)
    }

    private static func isResourceName(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value != "." && value != ".." &&
        value.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) ||
            (97...122).contains($0) || $0 == 45 || $0 == 46 || $0 == 95 }
    }
}

@MainActor struct AppIcon: View {
    let id: String
    var symbol: String = "app"
    var size: CGFloat = 36
    var registeredIcon: RegisteredApplicationIcon? = nil
    var iconHome: URL? = nil
    var protocolIcon = false
    var body: some View {
        TimelineView(.periodic(from: .now, by: IconCache.refreshInterval)) { context in
            Group {
                if let registeredIcon, registeredIcon.app_id == id, let iconHome {
                    RegisteredApplicationIconView(icon:registeredIcon, home:iconHome, symbol:symbol, size:size, refreshAt:context.date)
                } else if !protocolIcon, let image = IconCache.image(id, refreshAt: context.date) { Image(nsImage: image).resizable().interpolation(.high).scaledToFit() }
                else { Image(systemName: symbol).font(.system(size: size * 0.55, weight: .regular)).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity).background(.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: size * 0.22)) }
            }
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}

@MainActor private struct RegisteredApplicationIconView: View {
    let icon: RegisteredApplicationIcon
    let home: URL
    let symbol: String
    let size: CGFloat
    let refreshAt: Date
    @State private var image: NSImage?
    private var lookupID: String { home.path + ":" + icon.app_id + ":" + icon.sha256 + ":" + String(refreshAt.timeIntervalSince1970) }
    var body: some View {
        Group {
            if let image { Image(nsImage:image).resizable().interpolation(.high).scaledToFit() }
            else { Image(systemName:symbol).font(.system(size:size * 0.55)).foregroundStyle(.secondary) }
        }.task(id:lookupID) {
            do {
                let data = try await SettingsService(home:home).readApplicationIcon(icon)
                try Task.checkCancellation()
                guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) == 1,
                      let properties = CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
                      properties[kCGImagePropertyPixelWidth] as? Int == 64,
                      properties[kCGImagePropertyPixelHeight] as? Int == 64,
                      let decoded = NSImage(data:data) else { image = nil; return }
                image = decoded
            } catch { if !Task.isCancelled { image = nil } }
        }
    }
}
