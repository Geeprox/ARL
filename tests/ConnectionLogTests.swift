import Foundation
import Darwin

@main enum ConnectionLogTests {
    static func check(_ value: Bool, _ label: String) { precondition(value, label) }
    static func files(_ root: URL) throws -> [URL] { try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.pathExtension == "jsonl" } }
    static func rows(_ root: URL) throws -> [[String:Any]] {
        try files(root).flatMap { url in try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String:Any] } }
    }
    static func main() throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let a=root.appendingPathComponent("projection"),log=ARLConnectionLog(directory:a,rotateBytes:1200)
        let secrets=["TOP-SECRET-TOKEN-ABC", "COOKIE-SECRET-DEF", "SIGNED-URL-SECRET-GHI"]
        let parser=ARLConnectionOutput(log:log,source:"tunnel",stream:"stdout")
        let event:[String:Any] = ["level":"WARN","msg":"poll failed; backing off","attrs":["error":secrets[0]+" deadline exceeded https://example.invalid/?Signature="+secrets[2],"Cookie":secrets[1],"retry_in_ms":200,"status_code":429,"elapsed_ms":37,"request_id":"upstream-test","cmd_request_id":"command-test","rpc_request_id":19,"client_instance_id":"fixture-client","tunnel_request_id":"fixture-request"]]
        var bytes=try JSONSerialization.data(withJSONObject:event);bytes.append(10)
        parser.feed(bytes.prefix(17));parser.feed(bytes.dropFirst(17))
        for _ in 0..<11 { parser.feed(bytes) } // repeated failures must not disappear behind startup deduplication
        let fields=ARLConnectionLog.requestFields(["id":19,"method":"tools/call","params":["name":"mio_netease_status","arguments":["cookie":secrets[1]]]])
        log.record("mio","request_received",fields)
        var finished=fields;finished["failed"]=false;finished["elapsed_ms"]=14
        log.record("mio","request_finished",finished)
        log.record("owner","owner_finished",["owner_call_id":"00000000-0000-4000-8000-000000000001","failed":false,"token":secrets[0],"url":"https://example.invalid/?Signature="+secrets[2]])
        parser.feed(Data(repeating:65,count:70000));parser.feed(Data([10]))
        parser.feed(Data("plain stderr token ".utf8)+Data(secrets[0].utf8),end:true)
        let all=try rows(a);check(all.filter{$0["event"] as? String == "retry"}.count==12,"retry retention")
        let retry=all.first{$0["event"] as? String == "retry"}!
        check(retry["http_status"] as? Int==429 && retry["elapsed_ms"] as? Int==37 && retry["retry_in_ms"] as? Int==200,"typed HTTP metadata")
        check(retry["error_kind"] as? String=="timeout","finite error classification")
        check(retry["upstream_request_sha256"] as? String == ARLConnectionLog.fingerprint("upstream-test") && retry["command_request_sha256"] as? String == ARLConnectionLog.fingerprint("command-test") && retry["rpc_id_sha256"] as? String == (fields["rpc_id_sha256"] as? String),"SDK request correlation without raw IDs")
        check(all.contains{$0["event"] as? String=="output_oversize"},"oversize recovery")
        check(all.contains{$0["event"] as? String=="output_eof"},"EOF flush")
        for f in try files(a) {
            let text=try String(contentsOf:f,encoding:.utf8);check(secrets.allSatisfy{!text.contains($0)},"secret projection")
            let st=try FileManager.default.attributesOfItem(atPath:f.path);check((st[.posixPermissions] as! NSNumber).intValue==0o600,"file mode")
        }
        check(try files(a).count>2,"size rotation")
        let old=a.appendingPathComponent("connection-10000-123-00000000-0000-4000-8000-000000000002.jsonl")
        let recent=a.appendingPathComponent("connection-10000-123-00000000-0000-4000-8000-000000000003.jsonl")
        try Data("old\n".utf8).write(to:old);try Data("recent\n".utf8).write(to:recent)
        try FileManager.default.setAttributes([.modificationDate:Date().addingTimeInterval(-8*86400)],ofItemAtPath:old.path)
        try FileManager.default.setAttributes([.modificationDate:Date().addingTimeInterval(-6*86400)],ofItemAtPath:recent.path)
        ARLConnectionLog(directory:a).record("arl","started")
        check(!FileManager.default.fileExists(atPath:old.path) && FileManager.default.fileExists(atPath:recent.path),"seven-day retention")
        let concurrent=root.appendingPathComponent("concurrent"),parallel=ARLConnectionLog(directory:concurrent,rotateBytes:4096)
        DispatchQueue.concurrentPerform(iterations:100) { _ in parallel.record("mio","request_finished",["failed":false,"elapsed_ms":1]) }
        check(try rows(concurrent).count==100,"concurrent records")
        let dayNow=Date().timeIntervalSince1970
        let dayA=ARLConnectionLog(directory:root.appendingPathComponent("days"),clock:{Date(timeIntervalSince1970:dayNow)})
        dayA.record("arl","started")
        ARLConnectionLog(directory:root.appendingPathComponent("days"),clock:{Date(timeIntervalSince1970:dayNow+86400)}).record("arl","started")
        check(try files(root.appendingPathComponent("days")).count==2,"day segments")
        let target=root.appendingPathComponent("protected");try Data("KEEP".utf8).write(to:target)
        let symlink=root.appendingPathComponent("symlink");try FileManager.default.createSymbolicLink(at:symlink,withDestinationURL:target)
        ARLConnectionLog(directory:symlink).record("arl","started")
        check(try String(contentsOf:target,encoding:.utf8)=="KEEP","symlink unchanged; nonthrowing failure")
        let disabled=root.appendingPathComponent("disabled");ARLConnectionLog(directory:disabled,enabled:false).record("mio","request_received")
        check(!FileManager.default.fileExists(atPath:disabled.path),"disabled test/unsigned process")
        print("{\"status\":\"PASS\",\"retry_rows\":12,\"concurrent_rows\":100,\"rotation\":true,\"retention\":true,\"secrets_absent\":true,\"failure_nonthrowing\":true,\"real_network\":0}")
    }
}
