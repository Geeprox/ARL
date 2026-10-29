import Foundation

@MainActor @main enum FinderActionSelectionTests {
    enum Failure: Error { case assertion(String) }
    static var checks = 0
    static func expect(_ value: Bool, _ label: String) throws {
        guard value else { throw Failure.assertion(label) }; checks += 1
    }
    static func main() throws {
        let home = URL(fileURLWithPath: "/fixture-home", isDirectory: true)
        let volumes = URL(fileURLWithPath: "/Volumes", isDirectory: true)
        let roots: Set<URL> = [home, volumes]
        let unusual = home.appendingPathComponent("项目 空格 ' \" $(touch should-never-run); `uname` #.txt")
        let directory = home.appendingPathComponent("Repository/项目", isDirectory: true)
        let selection = FinderActionSelection(context: .items, selected: [unusual, directory], targeted: directory, roots: roots)!
        try expect(selection.copiedPaths == unusual.path + "\n" + directory.path, "complete newline-separated literal paths")
        try expect(selection.terminalDirectory(isDirectory: { _ in true }) == nil, "multi-selection has no terminal target")
        let blank = FinderActionSelection(context: .container, selected: [unusual, directory], targeted: directory, roots: roots)!
        try expect(blank.urls == [directory], "blank space ignores existing multi-selection")
        try expect(blank.terminalDirectory(isDirectory: { $0 == directory }) == directory, "one exact directory URL")
        try expect(blank.terminalDirectory(isDirectory: { _ in false }) == nil, "file or missing directory rejected")
        try expect(FinderActionSelection(context: .items, selected: [], targeted: directory, roots: roots) == nil, "items do not fallback to parent")
        try expect(FinderActionSelection(context: .container, selected: [directory], targeted: nil, roots: roots) == nil, "blank space needs exact target")
        for path in ["/fixture-home-other/project", "/etc", "/fixture-home/../../etc"] {
            try expect(FinderActionSelection(context: .items, selected: [URL(fileURLWithPath: path)], targeted: nil, roots: roots) == nil, "scope component boundary")
        }
        for raw in ["smb://fixture/share", "file://remote/Volumes/share", "https://example.test", "file:///fixture-home/file?query=1", "file:///fixture-home/file#fragment"] {
            try expect(FinderActionSelection(context: .items, selected: [URL(string: raw)!], targeted: nil, roots: roots) == nil, "non-local or decorated URL rejected")
        }
        let nas = URL(fileURLWithPath: "/Volumes/fixture/share/中文目录", isDirectory: true)
        let mounted = FinderActionSelection(context: .items, selected: [nas], targeted: nil, roots: roots)!
        try expect(mounted.copiedPaths == nas.path, "mounted NAS uses local complete path")
        try expect(FinderActionSelection(context: .items, selected: [directory, URL(fileURLWithPath: "/etc")], targeted: nil, roots: roots) == nil, "mixed selection never silently filtered")
        try expect(FinderActionSelection(context: .items, selected: [directory], targeted: nil, roots: [URL(fileURLWithPath: "/")]) == nil, "global root not admitted")
        print("{\"status\":\"PASS\",\"checks\":\(checks),\"actual_finder_or_terminal_calls\":false}")
    }
}
