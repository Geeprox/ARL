import Foundation
import Darwin
import Security
import CryptoKit
import CoreFoundation

/// Selected platform attachment only. No owner/NAS socket, credentials or journal.
enum MioAttachmentInspection {
    static let name = "mio_attachment_inspect"
    // Canonical descriptor generated from the frozen Python inspection_descriptor.
    static let descriptorJSON = #"{"_meta":{"arl/capability":"mio_attachment","arl/requiresConfirmation":false,"arl/version":1,"openai/fileParams":["file"]},"annotations":{"destructiveHint":false,"idempotentHint":true,"openWorldHint":false,"readOnlyHint":true},"description":"Use this when the user selects a ChatGPT attachment to verify ARL can receive it. Reads at most 1MiB through platform fileParams and returns only size/SHA256. No file is retained or written to NAS. This call does not need or create a NAS scope; do not construct a URL.","inputSchema":{"additionalProperties":false,"properties":{"file":{"additionalProperties":false,"properties":{"download_url":{"maxLength":16384,"type":"string"},"file_id":{"maxLength":134,"type":"string"},"file_name":{"maxLength":255,"type":"string"},"mime_type":{"maxLength":255,"type":"string"}},"required":["download_url","file_id"],"type":"object"},"operation_id":{"format":"uuid","pattern":"^[0-9a-f-]{36}$","type":"string"}},"required":["file","operation_id"],"type":"object"},"name":"mio_attachment_inspect","outputSchema":{"additionalProperties":false,"properties":{"automatic_replay":{"const":false,"type":"boolean"},"file_id":{"type":"string"},"nas_write_performed":{"const":false,"type":"boolean"},"operation":{"const":"inspect_attachment","type":"string"},"operation_id":{"format":"uuid","pattern":"^[0-9a-f-]{36}$","type":"string"},"schema_version":{"const":1,"type":"integer"},"sha256":{"pattern":"^[0-9a-f]{64}$","type":"string"},"size":{"maximum":1048576,"minimum":0,"type":"integer"},"state":{"const":"verified","type":"string"},"stored":{"const":false,"type":"boolean"}},"required":["automatic_replay","file_id","nas_write_performed","operation","operation_id","schema_version","sha256","size","state","stored"],"type":"object"},"title":"Verify selected attachment input"}"#
    static var descriptor: [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(descriptorJSON.utf8)) as? [String: Any]) ?? [:]
    }
    struct Failure: Error { let code: String }
    struct Command { let executable: URL; let arguments: [String] }
    static func fail(_ code: String) throws -> Never { throw Failure(code: code) }
    static func respond(id: Any, arguments: [String: Any], cancelled: () -> Bool,
                        execute: (Data) throws -> Data) throws -> [String: Any] {
        var value: [String: Any], failed = true
        do {
            guard Set(arguments.keys) == ["operation_id", "file"],
                  let operation = arguments["operation_id"] as? String,
                  let uuid = UUID(uuidString: operation), uuid.uuidString.lowercased() == operation,
                  let file = arguments["file"] as? [String: Any],
                  Set(["file_id", "download_url"]).isSubset(of: Set(file.keys)),
                  Set(file.keys).isSubset(of: ["file_id", "download_url", "mime_type", "file_name"]),
                  let fileID = file["file_id"] as? String, !fileID.isEmpty, fileID.utf8.count <= 134,
                  let url = file["download_url"] as? String, !url.isEmpty, url.utf8.count <= 16384,
                  ["mime_type", "file_name"].allSatisfy({ file[$0] == nil || file[$0] is String })
            else { try fail("invalid_import_request") }
            guard !cancelled() else { throw OwnerReadFault.cancelled }
            var raw = try JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys, .withoutEscapingSlashes])
            raw.append(10)
            guard raw.count <= OwnerReadWire.requestLimit else { throw OwnerReadFault.limit }
            let response = try OwnerReadJSON.object(execute(raw), limit: 8192)
            guard !cancelled() else { throw OwnerReadFault.cancelled }
            if Set(response.keys) == ["ok", "error"], OwnerReadWire.falseBoolean(response["ok"]),
               let error = response["error"] as? [String: Any], Set(error.keys) == ["code"],
               let code = error["code"] as? String, safeCode(code) { try fail(code) }
            guard Set(response.keys) == ["ok", "result"], OwnerReadWire.trueBoolean(response["ok"]),
                  let result = response["result"] as? [String: Any],
                  Set(result.keys) == ["schema_version", "operation", "operation_id", "state", "file_id", "size", "sha256", "nas_write_performed", "stored", "automatic_replay"],
                  OwnerReadWire.integer(result["schema_version"], 1), result["operation"] as? String == "inspect_attachment",
                  result["state"] as? String == "verified", result["operation_id"] as? String == operation,
                  result["file_id"] as? String == fileID,
                  let size = result["size"] as? NSNumber, CFGetTypeID(size) != CFBooleanGetTypeID(),
                  size.doubleValue.isFinite, (0...1048576).contains(size.intValue), size.doubleValue == Double(size.intValue),
                  let sha = result["sha256"] as? String, sha.utf8.count == 64,
                  sha.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  OwnerReadWire.falseBoolean(result["nas_write_performed"]), OwnerReadWire.falseBoolean(result["stored"]),
                  OwnerReadWire.falseBoolean(result["automatic_replay"])
            else { try fail("attachment_receipt_invalid") }
            value = result; failed = false
        } catch {
            let code = (error as? Failure)?.code ?? (error as? OwnerReadFault)?.rawValue ?? "attachment_inspection_unavailable"
            value = ["schema_version": 1, "operation": "inspect_attachment", "state": "failed",
                     "error": ["code": safeCode(code) ? code : "attachment_inspection_unavailable"],
                     "stored": false, "nas_write_performed": false, "automatic_replay": false]
        }
        let text = String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
        return ["jsonrpc": "2.0", "id": id, "result": ["content": [["type": "text", "text": text]], "structuredContent": value, "isError": failed]]
    }
    private static func safeCode(_ code: String) -> Bool {
        code.utf8.count <= 96 && !code.isEmpty && code.utf8.allSatisfy({ (97...122).contains($0) || $0 == 95 })
    }
    static func call(_ request: Data, cancelled: () -> Bool) throws -> Data {
        guard !cancelled() else { throw OwnerReadFault.cancelled }
        let command = try bundledCommand()
        return try run(request, command: command, cancelled: cancelled)
    }
    private static func bundledCommand() throws -> Command {
        let authority = try OwnerReadAuthority.load(role: .mio)
        let app = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard let owner = Bundle(url: app), owner.bundleIdentifier == authority.owner.identifier,
              owner.object(forInfoDictionaryKey: OwnerReadAuthority.sealKey) as? String == authority.seal,
              app.appendingPathComponent("Contents/Library/LoginItems/ARLMioAppleBridge.app").path == Bundle.main.bundleURL.path,
              let seal = owner.object(forInfoDictionaryKey: "ARLCoreRuntimeManifestSHA256") as? String,
              let resources = owner.resourceURL else { throw OwnerReadFault.identity }
        var code: SecStaticCode?, rule: SecRequirement?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(authority.owner.requirement(seal: authority.seal) as CFString, [], &rule) == errSecSuccess, let rule,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckNestedCode | kSecCSCheckAllArchitectures), rule) == errSecSuccess
        else { throw OwnerReadFault.identity }
        let runtime = resources.appendingPathComponent("CoreRuntime")
        let raw = try OwnerReadAuthority.readRegular(runtime.appendingPathComponent("manifest.json").path, limit: 1048576)
        guard SHA256.hash(data: raw).map({ String(format: "%02x", $0) }).joined() == seal else { throw OwnerReadFault.identity }
        let python = resources.appendingPathComponent("NASRuntime/python/bin/python3.12")
        let entry = runtime.appendingPathComponent("entry.py")
        try OwnerReadAuthority.inspectPath(python.path); try OwnerReadAuthority.inspectPath(entry.path)
        return Command(executable: python, arguments: ["-I", "-B", entry.path, "--parent-pid", String(getpid()), "--attachment-inspect"])
    }
    /// Synchronous isolated child; stdin is private and stderr is discarded.
    /// The outer watchdog includes DNS and aborts when the original caller leaves.
    static func run(_ request: Data, command: Command, seconds: Double = 25, cancelled: () -> Bool) throws -> Data {
        guard !request.isEmpty, request.count <= OwnerReadWire.requestLimit, request.last == 10,
              seconds > 0, seconds <= 25, !cancelled() else { throw OwnerReadFault.invalid }
        let deadline = OwnerReadSocket.now + seconds
        let input = Pipe(), output = Pipe(), process = Process()
        process.executableURL = command.executable; process.arguments = command.arguments
        process.environment = ["PATH": "/usr/bin:/bin", "LANG": "C", "PYTHONDONTWRITEBYTECODE": "1"]
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        let owned = try OwnedPID(process.processIdentifier)
        defer {
            try? input.fileHandleForWriting.close(); try? output.fileHandleForReading.close()
            owned.signal(SIGTERM)
            if !owned.stopped(by: OwnerReadSocket.now + 0.5) { owned.signal(SIGKILL) }
            if owned.stopped(by: OwnerReadSocket.now + 1) { process.waitUntilExit() }
        }
        try input.fileHandleForReading.close(); try output.fileHandleForWriting.close()
        let writer = input.fileHandleForWriting.fileDescriptor, reader = output.fileHandleForReading.fileDescriptor
        try OwnerReadSocket.configure(writer); try OwnerReadSocket.configure(reader)
        try request.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try OwnerReadSocket.wait(writer, event: Int16(POLLOUT), deadline: deadline, cancelled: cancelled)
                let count = Darwin.write(writer, bytes.baseAddress!.advanced(by: offset), bytes.count-offset)
                if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                guard count > 0 else { throw OwnerReadFault.unavailable }; offset += count
            }
        }
        try input.fileHandleForWriting.close()
        var response = Data()
        while true {
            guard !cancelled() else { throw OwnerReadFault.cancelled }
            guard OwnerReadSocket.now < deadline else { throw OwnerReadFault.deadline }
            var descriptor = pollfd(fd: reader, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 50)
            if ready < 0 && errno == EINTR { continue }
            guard ready >= 0 else { throw OwnerReadFault.unavailable }
            if ready == 0 { continue }
            var bytes = [UInt8](repeating: 0, count: 4096)
            let count = Darwin.read(reader, &bytes, bytes.count)
            if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            guard count >= 0 else { throw OwnerReadFault.unavailable }
            if count == 0 { break }
            response.append(contentsOf: bytes.prefix(count))
            guard response.count <= 8192 else { throw OwnerReadFault.limit }
        }
        while process.isRunning {
            guard !cancelled() else { throw OwnerReadFault.cancelled }
            guard OwnerReadSocket.now < deadline else { throw OwnerReadFault.deadline }; usleep(10000)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0, response.last == 10,
              response.filter({ $0 == 10 }).count == 1 else { throw OwnerReadFault.unavailable }
        return response
    }
}
