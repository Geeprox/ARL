import Foundation
import ARLCredentialOnboarding

@MainActor @main enum NASSharedConsumerTests {
    enum Failure: Error { case assertion(String), journal }
    static var checks = 0
    static func expect(_ value: Bool, _ name: String) throws { guard value else { throw Failure.assertion(name) }; checks += 1 }
    static func bytes(_ object: [String: Any]) throws -> Data { try OwnerReadWire.encode(object, limit: OwnerReadWire.responseLimit) }
    static func object(_ data: Data) throws -> [String: Any] { try OwnerReadJSON.object(data, limit: 196608, maximumDepth: 32) }
    static let epoch = String(repeating: "a", count: 32), ref = String(repeating: "b", count: 64), revision = String(repeating: "c", count: 64)
    static var entry: [String: Any] { ["object_ref": ref, "revision": revision, "path": "资料/原始文件.txt", "size": 131072,
        "modified_ns": Int64(1792412000123456789), "kind": "file", "media_kind": "other", "closed": NSNull(), "revision_basis": "metadata"] }
    static func reply(_ operation: String, count: Int = 131072) throws -> Data {
        var value: [String: Any] = ["schema_version": 1, "operation": operation, "source_ref": "synthetic", "config_generation": 1,
            "connection_epoch": epoch, "location": ["host":"nas.invalid", "port":445, "share":"share", "root":"资料"], "snapshot_consistent": false]
        if operation == "read" { value.merge(["entry": entry, "offset":0, "length":count, "bytes_read":count,
            "data_base64":Data(repeating: 0x61, count:count).base64EncodedString(), "eof":true, "next_offset":count]) { _, new in new } }
        else { value.merge(["directory_ref":NSNull(), "keyword":operation == "search" ? "原始" : NSNull(), "entries":[entry],
            "match_mode":operation == "search" ? "nfc_casefold_basename_literal_contains" : "all", "next_cursor":NSNull(),
            "enumeration_complete":true, "partial":false, "stopped_reason":"complete", "scanned_count":1, "pages":1, "recursive":false]) { _, new in new } }
        return try bytes(value)
    }
    static var readArgs: [String: Any] { ["source_ref":"synthetic", "config_generation":1, "connection_epoch":epoch,
        "object_ref":ref, "revision":revision, "offset":0, "length":131072] }
    final class SessionFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var stopped = false
        var closed: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
        func close() { lock.lock(); stopped = true; lock.unlock() }
    }
    @MainActor final class Fixture {
        var allowed = true, inputFail = false, outputFail = false, late = false, wait = false
        var error: NASRuntimeFailure?
        var connections = 0, consumes = 0
        var records: [(Data, Data?)] = []
        var payload: Data
        let session = SessionFlag()
        var executor: NASFileExecutor!
        init(_ payload: Data) {
            self.payload = payload
            executor = NASFileExecutor(port: .init(allowed: { self.allowed }, connectSavedScope: { self.connections += 1 }, consume: { _, _ in
            self.consumes += 1
            let session = self.session
            return try await withTaskCancellationHandler(operation: {
                while self.wait { try await Task.sleep(for: .milliseconds(5)) }
                if let error = self.error { throw error }
                if self.late { withUnsafeCurrentTask { $0?.cancel() } }
                return self.payload
            }, onCancel: { session.close() })
        }, record: { _, _, input, output in
            if output == nil && self.inputFail || output != nil && self.outputFail { throw Failure.journal }
            self.records.append((input, output))
        }))
        }
    }
    static func main() async throws {
        try expect(NASFileExecutor.code(ARLNASFault.configurationNotSaved) == "nas_scope_required", "missing selected directory is not a credential error")
        try expect(NASFileExecutor.code(ARLNASFault.credentialNotSaved) == "nas_credentials_unavailable", "actual missing credential identity remains distinct")
        try expect(NASFileExecutor.code(ARLNASFault.bindingMismatch) == "nas_source_changed", "identity/fingerprint mismatch is not missing credentials")
        let listInput = Data("{}".utf8), listReply = try reply("list")
        let f = Fixture(listReply), first = try await f.executor.execute(tool:"mio_nas_list", argumentsJSON:listInput, callID:UUID())
        try expect(first == listReply && f.connections == 1 && f.consumes == 1, "fresh list restores saved scope and preserves original return")
        try expect(f.records.count == 2 && f.records[0].0 == listInput && f.records[1].1 == first, "full arguments and raw return share call boundary")
        let cursor = try bytes(["cursor":epoch])
        _ = try await f.executor.execute(tool:"mio_nas_list", argumentsJSON:cursor, callID:UUID())
        try expect(f.connections == 1 && f.consumes == 2, "continuation never reconnects or remaps epoch")
        let read = try reply("read"), reader = Fixture(read)
        _ = try await reader.executor.execute(tool:"mio_nas_read", argumentsJSON:bytes(readArgs), callID:UUID())
        try expect(reader.connections == 0 && reader.consumes == 1, "read keeps original epoch and references")
        let code = try NASCapability.failure(operation:"list", code:"nas_cursor_expired"), failed = Fixture(code)
        let rawFailure = try await failed.executor.execute(tool:"mio_nas_list", argumentsJSON:listInput, callID:UUID())
        try expect(rawFailure == code, "finite native failure is not changed into music or invalid-reply error")
        let denied = Fixture(listReply); denied.error = .accessDenied
        let deniedReply = try object(await denied.executor.execute(tool:"mio_nas_list", argumentsJSON:listInput, callID:UUID()))
        try expect((deniedReply["error"] as? [String:Any])?["code"] as? String == NASRuntimeFailure.accessDenied.rawValue, "native finite error survives owner boundary")
        let invalid = Fixture(listReply)
        do { _ = try await invalid.executor.execute(tool:"mio_nas_list", argumentsJSON:bytes(["host":"elsewhere"]), callID:UUID()); throw Failure.assertion("host accepted") }
        catch OwnerReadFault.invalid { checks += 1 }
        try expect(invalid.records.isEmpty && invalid.connections == 0, "invalid selectors never log or reach native service")
        let inputFail = Fixture(listReply); inputFail.inputFail = true
        do { _ = try await inputFail.executor.execute(tool:"mio_nas_list", argumentsJSON:listInput, callID:UUID()); throw Failure.assertion("input log accepted") }
        catch Failure.journal { checks += 1 }
        try expect(inputFail.consumes == 0, "failed input persistence prevents I/O")
        let outputFail = Fixture(listReply); outputFail.outputFail = true
        do { _ = try await outputFail.executor.execute(tool:"mio_nas_list", argumentsJSON:listInput, callID:UUID()); throw Failure.assertion("output log accepted") }
        catch Failure.journal { checks += 1 }
        try expect(outputFail.consumes == 1 && !outputFail.executor.busy, "output persistence failure does not replay I/O and releases gate")
        let late = Fixture(listReply); late.late = true
        let lateReply = try object(await late.executor.execute(tool:"mio_nas_list", argumentsJSON:listInput, callID:UUID()))
        try expect((lateReply["error"] as? [String:Any])?["code"] as? String == "cancelled", "post-I/O cancellation suppresses late bytes")
        let busy = Fixture(listReply); busy.wait = true
        let running = Task { try await busy.executor.execute(tool:"mio_nas_list", argumentsJSON:listInput, callID:UUID()) }
        while busy.consumes == 0 { await Task.yield() }
        let blocked = try object(await busy.executor.execute(tool:"mio_nas_list", argumentsJSON:listInput, callID:UUID()))
        try expect((blocked["error"] as? [String:Any])?["code"] as? String == "nas_busy" && busy.consumes == 1, "concurrent call cannot start another native action")
        busy.executor.suspendForExit(); _ = try await running.value
        try expect(!busy.executor.busy, "exit cancellation drains tracked caller action")
        try expect(busy.session.closed, "true App exit still closes the accepted session and drains")
        let navigation = Fixture(read); navigation.wait = true
        let page = NASFilePageTaskHandle()
        var navigationResult: Data?
        let accepted = Task { navigationResult = try? await navigation.executor.execute(tool:"mio_nas_read", argumentsJSON:bytes(readArgs), callID:UUID()) }
        page.track(accepted)
        while navigation.consumes == 0 { await Task.yield() }
        page.leave(); await Task.yield()
        try expect(navigation.executor.busy && !navigation.session.closed, "actual page leave handle keeps admitted work and original epoch alive")
        let duringLeave = try object(await navigation.executor.execute(tool:"mio_nas_read", argumentsJSON:bytes(readArgs), callID:UUID()))
        try expect((duringLeave["error"] as? [String:Any])?["code"] as? String == "nas_busy" && navigation.consumes == 1, "new page/Mio request cannot duplicate operation after leave")
        navigation.wait = false
        await accepted.value
        try expect(navigationResult == read && !navigation.session.closed, "owner finishes original finite bytes after page leave")
        let explicit = Fixture(read); explicit.wait = true
        let stopHandle = NASFilePageTaskHandle()
        let stoppedPage = Task { _ = try? await explicit.executor.execute(tool:"mio_nas_read", argumentsJSON:bytes(readArgs), callID:UUID()) }
        stopHandle.track(stoppedPage)
        while explicit.consumes == 0 { await Task.yield() }
        stopHandle.stop(); await stoppedPage.value
        try expect(explicit.session.closed && !explicit.executor.busy, "explicit page stop still closes and drains original accepted operation")
        let list = try MioReadOwnerAdapter.respond(["jsonrpc":"2.0", "id":1, "method":"tools/list"], ownerCall:{_,_ in throw OwnerReadFault.unavailable})
        let descriptors = (list["result"] as! [String:Any])["tools"] as! [[String:Any]]
        try validateMioPublishedDescriptors(descriptors)
        let nasDescriptors = descriptors.filter { NASCapability.names.contains($0["name"] as? String ?? "") }
        try expect(try bytes(["tools":nasDescriptors]) == bytes(["tools":NASCapability.descriptors]), "actual published NAS descriptor block is the finite contract")
        for (tool, input, output, isError) in [("mio_nas_list", [String:Any](), first, false), ("mio_nas_read", readArgs, read, false), ("mio_nas_list", [String:Any](), rawFailure, true)] {
            let wireRequest = OwnerReadRequest(generation: UUID().uuidString, callID: UUID().uuidString, tool:tool, argumentsJSON:try bytes(input))
            let wire = try OwnerReadWire.response(wireRequest, payload:output, error:nil)
            let restored = try OwnerReadWire.payload(wire, request:wireRequest)
            let response = try MioReadOwnerAdapter.respond(["jsonrpc":"2.0", "id":2, "method":"tools/call", "params":["name":tool, "arguments":input]], ownerCall:{ name, args in
                try expect(name == tool && NSDictionary(dictionary:try object(args)).isEqual(to:input), "actual MCP dispatch preserves original tool and arguments")
                return restored
            })
            let result = response["result"] as! [String:Any], content = result["content"] as! [[String:Any]], text = content[0]["text"] as! String
            try expect(text == String(decoding:output, as:UTF8.self) && result["isError"] as? Bool == isError, "MCP text retains exact original JSON and finite error disposition")
            try expect(NSDictionary(dictionary:try object(output)).isEqual(to:result["structuredContent"] as! [String:Any]), "MCP structured result has all original fields")
            let total = try JSONSerialization.data(withJSONObject:response).count
            try expect(wire.count < OwnerReadWire.responseLimit && total < 1048576, "maximum native read fits existing owner and MCP bounds")
        }
        try expect(NASCapability.integer(NSNumber(value: true)) == nil, "boolean cannot become file limit")
        try expect(descriptors.filter { AppleCapability.names.contains($0["name"] as? String ?? "") }.count == 2, "existing Apple tools remain in actual expanded catalog")
        if CommandLine.arguments.count == 2 {
            let root = URL(fileURLWithPath: CommandLine.arguments[1])
            try expect(!FileManager.default.fileExists(atPath: root.path), "journal fixture is a new isolated directory")
            let journal = NASBusinessJournal(directory: root), id = UUID(), input = try bytes(readArgs)
            try journal.record(tool: "mio_nas_read", callID: id, argumentsJSON: input, responseJSON: nil)
            try journal.record(tool: "mio_nas_read", callID: id, argumentsJSON: input, responseJSON: read)
            let segments = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasSuffix(".jsonl.noindex") }
            let records = try segments.flatMap { try String(contentsOf: $0, encoding: .utf8).split(separator: "\n").map { try object(Data($0.utf8)) } }
            try expect(records.count == 2 && records.allSatisfy { $0["arguments_text"] as? String == String(decoding: input, as: UTF8.self) }, "real eight-day journal keeps full original read arguments")
            try expect(records.last?["response_text"] as? String == String(decoding: read, as: UTF8.self) && records.last?["call_id"] as? String == id.uuidString, "real journal retains maximum raw byte result and same call UUID")
        }
        print("PASS NAS shared consumer \(checks) checks; synthetic bytes only; network/keychain/prompt/install = 0")
    }
}
