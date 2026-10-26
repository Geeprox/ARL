import Foundation
import CoreFoundation
import CryptoKit

@MainActor @main enum NASFileReaderContractTests {
    static var checks = 0
    static let location: [String: Any] = ["host": "synthetic.invalid", "port": 445, "share": "home", "root": "ARL-Test"]
    static let fence: [String: Any] = ["source_ref": "synthetic", "config_generation": 1, "connection_epoch": String(repeating: "e", count: 32)]
    static let object = String(repeating: "a", count: 64), revision = String(repeating: "b", count: 64)
    static func check(_ value: Bool, _ label: String = "", line: Int = #line) {
        checks += 1; precondition(value, "\(label) line \(line)")
    }
    static func json(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }
    static func copy(_ value: [String: Any]) throws -> [String: Any] { try JSONSerialization.jsonObject(with: json(value)) as! [String: Any] }
    static func request(_ search: Bool = true, _ changes: [String: Any] = [:]) throws -> [String: Any] {
        var args = fence
        if search { args["keyword"] = "原文" }
        else { args["object_ref"] = object; args["revision"] = revision; args["size"] = 0 }
        args.merge(changes) { _, b in b }
        return try NASFileReaderContract.request(tool: search ? "mio_nas_search_recursive" : "mio_nas_read_text", argumentsJSON: json(args))
    }
    static func rejectRequest(_ changes: [String: Any], search: Bool = true) throws {
        do { _ = try request(search, changes); check(false, "request accepted") }
        catch NASFileReaderContract.Fault.invalidRequest { checks += 1 }
    }
    static func accept(_ value: [String: Any], _ wire: [String: Any], expected: [String: Any]? = location) throws {
        // Exercise JSON/NSNumber/NSNull representations used by both owners.
        try NASFileReaderContract.admit(try copy(value), request: try copy(wire), expectedLocation: expected); checks += 1
    }
    static func reject(_ value: [String: Any], _ wire: [String: Any], expected: [String: Any]? = location) throws {
        do { try NASFileReaderContract.admit(try copy(value), request: try copy(wire), expectedLocation: expected); check(false, "reply accepted") }
        catch NASFileReaderContract.Fault.invalidReply { checks += 1 }
    }
    static func entry(_ size: Int) -> [String: Any] {
        ["object_ref": object, "kind": "file", "revision": revision, "size": size, "modified_ns": NSNull(),
         "media_kind": "other", "closed": NSNull(), "revision_basis": "metadata", "path": "ARL-Test/原文.txt"]
    }
    static func searchReply(_ changes: [String: Any] = [:]) -> [String: Any] {
        var result = fence
        result.merge(["schema_version": 1, "operation": "search_recursive", "location": location, "snapshot_consistent": false,
                      "directory_ref": NSNull(), "keyword": "原文", "recursive": true,
                      "match_mode": "nfc_casefold_basename_contains", "entries": [entry(0)], "next_cursor": NSNull(),
                      "enumeration_complete": true, "partial": false, "scanned_count": 1, "pages": 1,
                      "total_scanned_count": 1, "total_pages": 1, "stopped_reasons": [String](), "stopped_reason": NSNull()]) { _, b in b }
        result.merge(changes) { _, b in b }; return result
    }
    static func readReply(_ bytes: Data, size: Int? = nil, text: Any, tail: Data = Data(), reason: Any? = nil) -> [String: Any] {
        let size = size ?? bytes.count, complete = size == bytes.count
        var result = fence
        result.merge(["schema_version": 1, "operation": "read_text", "location": location, "snapshot_consistent": false,
                      "object_ref": object, "revision": revision, "entry": entry(size), "size": size,
                      "bytes_read": bytes.count, "data_base64": bytes.base64EncodedString(),
                      "sha256_of_returned_bytes": SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
                      "encoding": text is NSNull ? NSNull() : "utf-8", "text": text, "undecoded_tail_base64": tail.base64EncodedString(),
                      "complete": complete, "truncated": !complete, "next_offset": complete ? NSNull() : bytes.count,
                      "stopped_reason": reason ?? (complete ? NSNull() : "text_byte_budget"), "downloadable_artifact": false]) { _, b in b }
        return result
    }
    static func main() throws {
        check(NASFileReaderContract.names == ["mio_nas_search_recursive", "mio_nas_read_text"])
        for descriptor in NASFileReaderContract.descriptors {
            let schema = descriptor["inputSchema"] as! [String: Any]
            check((schema["additionalProperties"] as? Bool) == false)
            let properties = schema["properties"] as! [String: Any]
            check(properties["host"] == nil && properties["path"] == nil && properties["root"] == nil && properties["recursive"] == nil)
            check(Set(schema["required"] as! [String]).isSuperset(of: ["source_ref", "config_generation", "connection_epoch"]))
        }
        let search = try request(); check(search["operation"] as? String == "search_recursive")
        check(search["recursive"] as? Bool == true); check(search["limit"] as? Int == 32)
        let read = try request(false); check(read["max_bytes"] as? Int == 65536)
        check(try request(true, ["config_generation": Int64.max])["config_generation"] as? NSNumber == NSNumber(value: Int64.max))
        for changes: [String: Any] in [["root": "outside"], ["share": "home"], ["host": "outside"], ["path": "../outside"],
            ["recursive": true], ["operation": "search_recursive"], ["directory_ref": NSNull()], ["directory_ref": "../outside"],
            ["cursor": "x"], ["limit": true], ["limit": 0], ["limit": 33], ["keyword": ""], ["keyword": "a\n"],
            ["keyword": String(repeating: "汉", count: 86)], ["source_ref": "../outside"], ["source_ref": "synthetic\n"],
            ["connection_epoch": String(repeating: "F", count: 32)], ["config_generation": true], ["config_generation": 0],
            ["config_generation": NSNull()], ["config_generation": NSNumber(value: UInt64.max)]] {
            try rejectRequest(changes)
        }
        for changes: [String: Any] in [["size": -1], ["size": true], ["object_ref": "x"], ["revision": NSNull()],
                                     ["max_bytes": 0], ["max_bytes": 65537], ["max_bytes": true], ["offset": 1]] {
            try rejectRequest(changes, search: false)
        }
        do { _ = try NASFileReaderContract.request(tool: "mio_nas_read_text", argumentsJSON: Data("[]".utf8)); check(false) }
        catch NASFileReaderContract.Fault.invalidRequest { checks += 1 }
        do { _ = try NASFileReaderContract.request(tool: "mio_nas_read", argumentsJSON: Data("{}".utf8)); check(false) }
        catch NASFileReaderContract.Fault.invalidRequest { checks += 1 }
        try accept(searchReply(["total_pages": 65]), search);
        try accept(searchReply(), search); try accept(searchReply(), search, expected: nil)
        try accept(searchReply(["entries": [[String: Any]](), "scanned_count": 0, "total_scanned_count": 0]), search)
        let token = String(repeating: "c", count: 32)
        try accept(searchReply(["entries": [[String: Any]](), "next_cursor": token, "enumeration_complete": false, "partial": true,
                                "pages": 4, "total_pages": 4, "stopped_reason": "page_budget"]), search)
        try accept(searchReply(["next_cursor": token, "enumeration_complete": false, "partial": true, "pages": 0, "scanned_count": 0,
                                "stopped_reason": "result_budget"]), search)
        for reason in ["depth_budget", "directory_budget", "provider_incomplete", "scan_page_budget"] {
            try accept(searchReply(["enumeration_complete": false, "partial": true, "stopped_reasons": [reason],
                                    "stopped_reason": reason, "total_pages": reason == "scan_page_budget" ? 64 : 1]), search)
        }
        for changes: [String: Any] in [["source_ref": "other"], ["connection_epoch": String(repeating: "f", count: 32)],
            ["config_generation": 2], ["schema_version": true], ["operation": "search"], ["recursive": false],
            ["recursive": 1], ["keyword": "other"], ["snapshot_consistent": true], ["unexpected": 1], ["partial": true],
            ["next_cursor": token], ["pages": true], ["pages": 5], ["scanned_count": 33], 
            ["stopped_reasons": ["unknown"]], ["stopped_reason": "page_budget"], ["directory_ref": object],
            ["enumeration_complete": false], ["entries": Array(repeating: entry(0), count: 33)]] {
            try reject(searchReply(changes), search)
        }
        for changes: [String: Any] in [["path": "ARL-Test/../outside"], ["path": "ARL-Test2/原文.txt"], ["path": "ARL-Test\\原文.txt"],
            ["kind": "directory"], ["path": "ARL-Test/unmatched.txt"], ["revision": "x"], ["size": true], ["url": "https://outside.invalid"],
            ["closed": false], ["revision_basis": "content"]] {
            var changed = entry(0); changed.merge(changes) { _, b in b }
            try reject(searchReply(["entries": [changed]]), search)
        }
        var wrongLocation = location; wrongLocation["root"] = "other"
        try reject(searchReply(), search, expected: wrongLocation)
        wrongLocation = location; wrongLocation["port"] = true
        try reject(searchReply(["location": wrongLocation]), search, expected: nil)
        var unicodeEntry = entry(0); unicodeEntry["path"] = "ARL-Test/Cafe\u{301}.TXT"
        try accept(searchReply(["keyword": "CAFÉ", "entries": [unicodeEntry]]), try request(true, ["keyword": "CAFÉ"]))
        unicodeEntry["path"] = "ARL-Test/Straße.txt"
        try accept(searchReply(["keyword": "STRASSE", "entries": [unicodeEntry]]), try request(true, ["keyword": "STRASSE"]))
        let normal = Data("原文🙂\n".utf8), normalWire = try request(false, ["size": normal.count])
        let normalReply = readReply(normal, text: "原文🙂\n")
        try accept(normalReply, normalWire)
        try accept(readReply(Data(), text: ""), read)
        let prefix = Data([0x61, 0xF0, 0x9F]), prefixWire = try request(false, ["size": 6, "max_bytes": 3])
        let prefixReply = readReply(prefix, size: 6, text: "a", tail: Data([0xF0, 0x9F]))
        try accept(prefixReply, prefixWire)
        let invalid = [Data([0xFF]), Data([0xE0, 0x80]), Data([0xF4, 0x90]), Data([0xC0]), Data([0xF5]), Data([0x80])]
        for bytes in invalid {
            try accept(readReply(bytes, text: NSNull(), reason: "binary_or_invalid_utf8"), try request(false, ["size": bytes.count]))
            try accept(readReply(bytes, size: bytes.count + 1, text: NSNull(), reason: "binary_or_invalid_utf8"), try request(false, ["size": bytes.count + 1, "max_bytes": bytes.count]))
        }
        try accept(readReply(Data([0x61, 0]), text: NSNull(), reason: "binary_or_invalid_utf8"), try request(false, ["size": 2]))
        // Every valid incomplete scalar length, including constrained lead bytes.
        for bytes in [[UInt8](arrayLiteral: 0xC2), [0xE0], [0xE0, 0xA0], [0xED, 0x9F], [0xED, 0xA0], [0xED, 0xBF], [0xF0], [0xF0, 0x90], [0xF0, 0x90, 0x80], [0xF4, 0x8F, 0xBF]] {
            let tail = Data(bytes), raw = Data([0x61]) + tail
            try accept(readReply(raw, size: raw.count + 4, text: "a", tail: tail), try request(false, ["size": raw.count + 4, "max_bytes": raw.count]))
        }
        for changes: [String: Any] in [["text": "invented"], ["encoding": "utf-16"], ["data_base64": normal.base64EncodedString() + "\n"],
            ["data_base64": ""], ["sha256_of_returned_bytes": String(repeating: "0", count: 64)], ["size": normal.count + 1],
            ["bytes_read": true], ["bytes_read": normal.count - 1], ["complete": false], ["truncated": true], ["next_offset": 1],
            ["undecoded_tail_base64": "YQ=="], ["stopped_reason": "text_byte_budget"], ["object_ref": revision], ["revision": object],
            ["downloadable_artifact": true], ["encoding": NSNull()], ["state": "failed"]] {
            var changed = normalReply; changed.merge(changes) { _, b in b }; try reject(changed, normalWire)
        }
        for reason in ["binary_or_invalid_utf8", "text_output_budget"] {
            var changed = normalReply; changed["text"] = NSNull(); changed["encoding"] = NSNull(); changed["stopped_reason"] = reason
            try reject(changed, normalWire)
        }
        var changed = prefixReply; changed["undecoded_tail_base64"] = ""; try reject(changed, prefixWire)
        changed = prefixReply; changed["text"] = "a�"; try reject(changed, prefixWire)
        changed = normalReply; var wrongEntry = entry(normal.count); wrongEntry["revision"] = object; changed["entry"] = wrongEntry
        try reject(changed, normalWire)
        // Escaped text overflow is legal only when reconstructing the original
        // strict UTF8 result really exceeds Python's exact output budget.
        let large = Data(repeating: 1, count: 65536), largeWire = try request(false, ["size": large.count])
        try accept(readReply(large, text: NSNull(), reason: "text_output_budget"), largeWire)
        let bigPrefix = Data(repeating: 0x61, count: 65536)
        try accept(readReply(bigPrefix, size: 2 * 1048576, text: String(decoding: bigPrefix, as: UTF8.self)), try request(false, ["size": 2 * 1048576]))
        for fixturePath in CommandLine.arguments.dropFirst() {
            let fixtures = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: fixturePath))) as! [[String: Any]]
            for fixture in fixtures {
                let tool = fixture["tool"] as! String
                let args = fixture["arguments"] as! [String: Any]
                let wire = try NASFileReaderContract.request(tool: tool, argumentsJSON: json(args))
                do { try accept(fixture["value"] as! [String: Any], wire) }
                catch { FileHandle.standardError.write(Data("Python DTO rejected: \(fixture["label"]!)\n".utf8)); throw error }
            }
        }
        print("PASS NASFileReaderContract \(checks) checks; synthetic only; App build/install/NAS/UI/permissions=0")
    }
}
