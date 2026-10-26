import Foundation

@main struct TisraIntegrationSmoke {
    static func main() async throws {
        let home = URL(fileURLWithPath: CommandLine.arguments[1])
        FileHandle.standardOutput.write(Data("prepared\n".utf8))
        guard readLine() == "go" else { fatalError("Host gate closed") }
        let passive = TisraRuntime(home: home)
        guard await passive.refresh() == .disabled else { fatalError("Default must be disabled") }
        let runtime = TisraRuntime(home: home, enabled: true)
        guard case .ready = await runtime.refresh() else { fatalError("Not ready") }
        let action = ReviewedARLAction.digest(id: UUID(), text: "synthetic Tisra action")
        let first = try await runtime.submit(action)
        let duplicate = try await runtime.submit(action)
        guard first["id"] == duplicate["id"], let id = first["id"]?.text else { fatalError("No stable dedupe") }
        for _ in 0..<100 {
            let receipt = try await runtime.receipt(id: id)
            if receipt["state"] == .string("succeeded") {
                print("{\"app\":\"tisra\",\"native_swift6\":true,\"opt_in_default_disabled\":true,\"deduplicated\":true}")
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        fatalError("Job did not finish")
    }
}
