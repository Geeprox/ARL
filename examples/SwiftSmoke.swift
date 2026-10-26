import Foundation

@main struct SwiftSmoke {
    static func main() async throws {
        guard CommandLine.arguments.count >= 2 else { fatalError("Pass private ARL home") }
        if CommandLine.arguments.contains("--await-host") {
            FileHandle.standardOutput.write(Data("prepared\n".utf8))
            _ = readLine()
        }
        let args = CommandLine.arguments
        let app = args.firstIndex(of: "--app").flatMap { args.indices.contains($0+1) ? args[$0+1] : nil } ?? "sample_app"
        let client = ARLClient(home: URL(fileURLWithPath: CommandLine.arguments[1]), app: app)
        _ = try await client.connect()
        let health = try await client.rpc("health")
        guard health["ready"] == .bool(true) else { fatalError("Not ready") }
        let job = try await client.submit(tool: "text.sha256", args: ["text": .string("Swift ARL")], key: "swift-smoke-v1")
        guard let id = job["id"]?.text else { fatalError("Missing job") }
        for _ in 0..<100 {
            let result = try await client.rpc("get", params: ["id": .string(id)])
            if result["state"] == .string("succeeded") {
                print("Swift6 RPC + real tool: passed")
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        fatalError("Job timeout")
    }
}
