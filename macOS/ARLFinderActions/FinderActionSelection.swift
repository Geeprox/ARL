import Foundation

// Finder URLs remain data. No shell quoting, scripts, remote URLs, contents,
// recursive scans or fallback targets are part of these two actions.
struct FinderActionSelection: Equatable, Sendable {
    enum Context: Equatable, Sendable { case items, container }
    let context: Context
    let urls: [URL]

    init?(context: Context, selected: [URL]?, targeted: URL?, roots: Set<URL>) {
        let candidates: [URL]
        switch context {
        case .items:
            guard let selected, !selected.isEmpty else { return nil }
            candidates = selected
        case .container:
            guard let targeted else { return nil }
            candidates = [targeted] // Ignore stale item selection on blank space.
        }
        let directories = roots.map { $0.standardizedFileURL.path }
        guard !directories.isEmpty, candidates.allSatisfy({ url in
            guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost",
                  url.query == nil, url.fragment == nil, url.path.hasPrefix("/") else { return false }
            let path = url.standardizedFileURL.path
            return directories.contains { root in root != "/" && (path == root || path.hasPrefix(root + "/")) }
        }) else { return nil }
        self.context = context
        self.urls = candidates.map(\.standardizedFileURL)
    }
    var copiedPaths: String { urls.map(\.path).joined(separator: "\n") }
    func terminalDirectory(isDirectory: (URL) -> Bool) -> URL? {
        guard urls.count == 1, let directory = urls.first, isDirectory(directory) else { return nil }
        return directory
    }
}
