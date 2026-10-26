import Foundation
import SwiftUI

@main struct Harness {
    @MainActor static func main() async {
        let args = CommandLine.arguments
        guard args.count >= 2 else { return }
        let home = URL(fileURLWithPath: args[1], isDirectory: true)
        let started = DispatchTime.now().uptimeNanoseconds
        var output: [String: Any] = [:]
        if args.count >= 3 {
            do {
                let client = ARLClient(home: home, app: "settings")
                let reply: ARLJSON
                if args[2] == "test-connect-deadline" { reply = try await client.connect(timeout: 0.25) }
                else { reply = try await client.rpc(args[2]) }
                output["result"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(reply))
                output["ok"] = true
            } catch { output["ok"] = false; output["error"] = (error as? ARLError)?.code ?? "invalid_response" }
        } else {
            let store = RuntimeStore(arguments: ["Harness", "--runtime-home", home.path])
            await store.refresh()
            output["title"] = store.title
            output["detail"] = store.detail
            output["reading"] = store.reading
            output["error"] = store.errorCode ?? NSNull() as Any
            output["updated"] = store.lastUpdated != nil
            if let snapshot = store.snapshot {
                output["snapshot"] = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot))
                output["outstanding"] = snapshot.outstanding
            }
        }
        output["elapsed_ms"] = Double(DispatchTime.now().uptimeNanoseconds-started)/1_000_000
        if let data = try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]), let text = String(data:data, encoding:.utf8) { print(text) }
    }
}
