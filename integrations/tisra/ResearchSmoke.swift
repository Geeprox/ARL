import Foundation

@main struct ResearchSmoke {
    static func main() async throws {
        // Supervisor registers this exact test executable lifetime before allowing RPC.
        print("prepared"); fflush(stdout)
        guard let home=readLine() else { throw ARLError(code:"missing_test_home") }
        let client=ARLResearchClient(home:URL(fileURLWithPath:home))
        let request: [String:Any] = ["model":"fixture-model","store":false,"stream":false,
          "background":false,"truncation":"disabled","max_output_tokens":4096,
          "include":["reasoning.encrypted_content"],"input":[["role":"user","content":"synthetic question"]],
          "text":["format":["type":"json_schema","name":"sourced_research","strict":true,"schema":["type":"object"]]],"instructions":"Use supplied evidence"]
        var raw=try JSONSerialization.data(withJSONObject:request,options:[.sortedKeys])
        raw.append(Data(repeating:32,count:524_288-raw.count))
        let d=ARLResearchDescriptor(executionID:UUID(),threadID:UUID(),sequence:0,model:"fixture-model",
          requestDigest:ARLResearchClient.digest(raw),requestBytes:raw.count,
          evidence:[(UUID(),ARLResearchClient.digest(Data("synthetic evidence".utf8)))])
        let s=try await client.submit(rawRequest:raw,descriptor:d,epoch:0,provider:"responses_fixture",modelFingerprint:"test-double-revision-1")
        let deadline=Date().addingTimeInterval(5)
        while true {
            let state=try await client.status(s).state
            if state != "queued" && state != "running" { break }
            guard Date()<deadline else { throw ARLError(code:"test_timeout") }
            try await Task.sleep(for:.milliseconds(10))
        }
        let output=try await client.response(s)
        let receipt=try await client.status(s)
        let summary:[String:Any] = ["state":receipt.state,"request_bytes":raw.count,"response_bytes":output.count,"response_sha256":ARLResearchClient.digest(output)]
        let data=try JSONSerialization.data(withJSONObject:summary,options:[.sortedKeys])
        print(String(decoding:data,as:UTF8.self))
    }
}
