import Foundation

@main struct AppSessionClient {
    static func main() async throws {
        guard CommandLine.arguments.count == 2, readLine() == "go" else { throw ARLError(code:"invalid_arguments") }
        let client = ARLClient(home: URL(fileURLWithPath:CommandLine.arguments[1]), app:"sample_app")
        let accepted = try await client.openAppSession(name:"示例应用", capabilities:["runtime.ping","ungranted.write"], icon:"sf:doc", version:"1.0")
        guard accepted == ["runtime.ping"] else { throw ARLError(code:"invalid_response") }
        print("connected"); fflush(stdout)
        guard readLine() == "close" else { throw ARLError(code:"invalid_arguments") }
        try await client.pingAppSession()
        try await client.closeAppSession()
        print("closed"); fflush(stdout)
    }
}
