import Foundation

/// A login URL is ephemeral UI data. Do not persist, log, or display its token.
enum MusicLoginURL {
    static func validated(_ url: URL) -> URL? {
        let raw = url.absoluteString
        guard !raw.isEmpty, raw.utf8.count <= 4096,
              raw.utf8.allSatisfy({ (33...126).contains($0) }),
              !raw.contains("\\"),
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "https", let host = parts.host?.lowercased(),
              // Exact official QR short-link host; this is locally encoded, never fetched.
              host == "163cn.tv" || host == "music.163.com" || host.hasSuffix(".music.163.com"),
              parts.user == nil, parts.password == nil,
              parts.port == nil || parts.port == 443,
              let result = parts.url else { return nil }
        return result
    }
}
