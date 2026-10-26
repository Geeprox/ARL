import Foundation
import CoreFoundation
import CryptoKit

/// Shared pure admission for scoped reads. No connection, scope restoration,
/// credentials, filesystem IO, document parser, or attachment publisher.
public enum NASFileReaderContract {
    public enum Fault: Error, Equatable, Sendable { case invalidRequest, invalidReply }
    public static let names: Set<String> = ["mio_nas_search_recursive", "mio_nas_read_text"]
    private static let fence: Set<String> = ["source_ref", "config_generation", "connection_epoch"]
    private static let replyBase: Set<String> = ["schema_version", "operation", "source_ref", "config_generation", "connection_epoch", "location", "snapshot_consistent"]
    private static let textBudget = 196608 - 16384

    public static var descriptors: [[String: Any]] {
        names.sorted().map { tool in
            let search = tool == "mio_nas_search_recursive"
            var properties: [String: Any] = [
                "source_ref": ["type": "string", "pattern": "^[A-Za-z0-9_-]{1,96}$"],
                "config_generation": ["type": "integer", "minimum": 1, "maximum": Int64.max],
                "connection_epoch": ["type": "string", "pattern": "^[0-9a-f]{32}$"]]
            let required: [String]
            if search {
                properties["keyword"] = ["type": "string", "minLength": 1, "maxLength": 256, "description": "At most 256 UTF-8 bytes. Literal NFC casefold filename substring, not content search."]
                properties["directory_ref"] = ["type": "string", "pattern": "^[0-9a-f]{64}$"]
                properties["cursor"] = ["type": "string", "pattern": "^[0-9a-f]{32}$"]
                properties["limit"] = ["type": "integer", "minimum": 1, "maximum": 32, "default": 32]
                required = fence.sorted() + ["keyword"]
            } else {
                properties["object_ref"] = ["type": "string", "pattern": "^[0-9a-f]{64}$"]
                properties["revision"] = ["type": "string", "pattern": "^[0-9a-f]{64}$"]
                properties["size"] = ["type": "integer", "minimum": 0, "maximum": Int64.max]
                properties["offset"] = ["type": "integer", "minimum": 0, "default": 0]
                properties["max_bytes"] = ["type": "integer", "minimum": 1, "maximum": 65536, "default": 65536]
                required = fence.sorted() + ["object_ref", "revision", "size"]
            }
            return ["name": tool, "description": search
                ? "Search filenames recursively only within the existing live saved NAS scope and original source/configuration/epoch. No reconnect or scope restore. Preserve cursor and query for continuation. Bounded traversal reports partial results and reasons; zero partial results do not prove absence. Does not search file contents."
                : "Read a page of an exact NAS file reference/revision as strict UTF-8, with original bytes and SHA256. Continue using next_offset with the same reference, revision and size. max_bytes bounds one delivery page. Binary or invalid UTF-8 is reported explicitly. No PDF/Office extraction or downloadable attachment is implied. No reconnect or scope restore.",
                "inputSchema": ["type": "object", "additionalProperties": false, "properties": properties, "required": required],
                "annotations": ["readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": true],
                "_meta": ["arl/capability": "mio_nas", "arl/version": 1, "arl/risk": "low", "arl/requiresConfirmation": false]]
        }
    }

    /// Normalized private wire; caller must retain this exact request for admit.
    public static func request(tool: String, argumentsJSON: Data) throws -> [String: Any] {
        guard names.contains(tool), argumentsJSON.count <= 65536,
              let args = (try? JSONSerialization.jsonObject(with: argumentsJSON)) as? [String: Any]
        else { throw Fault.invalidRequest }
        let search = tool == "mio_nas_search_recursive"
        let extra: Set<String> = search ? ["keyword", "directory_ref", "cursor", "limit"] : ["object_ref", "revision", "size", "max_bytes", "offset"]
        guard Set(args.keys).isSubset(of: fence.union(extra)), validFence(args) else { throw Fault.invalidRequest }
        var wire = args
        if search {
            guard let keyword = args["keyword"] as? String, (1...256).contains(keyword.utf8.count),
                  !keyword.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
                  args["directory_ref"] == nil || hex(args["directory_ref"], 64),
                  args["cursor"] == nil || hex(args["cursor"], 32),
                  args["limit"] == nil || inRange(args["limit"], 1, 32)
            else { throw Fault.invalidRequest }
            wire["operation"] = "search_recursive"; wire["recursive"] = true
            wire["limit"] = args["limit"] ?? 32
        } else {
            guard hex(args["object_ref"], 64), hex(args["revision"], 64), inRange(args["size"], 0, Int64.max),
                  (args["offset"] == nil || inRange(args["offset"], 0, integer(args["size"])!)),
                  args["max_bytes"] == nil || inRange(args["max_bytes"], 1, 65536)
            else { throw Fault.invalidRequest }
            wire["operation"] = "read_text"; wire["max_bytes"] = args["max_bytes"] ?? 65536; wire["offset"] = args["offset"] ?? 0
        }
        return wire
    }

    /// Success only. The enclosing owner handles its finite failure envelope.
    public static func admit(_ value: [String: Any], request wire: [String: Any], expectedLocation: [String: Any]? = nil) throws {
        guard let operation = wire["operation"] as? String, ["search_recursive", "read_text"].contains(operation)
        else { throw Fault.invalidReply }
        var args = wire; args.removeValue(forKey: "operation")
        if operation == "search_recursive" {
            guard boolean(args.removeValue(forKey: "recursive")) == true else { throw Fault.invalidReply }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: args),
              let canonical = try? Self.request(tool: "mio_nas_" + operation, argumentsJSON: data),
              Set(canonical.keys) == Set(wire.keys),
              integer(value["schema_version"]) == 1, value["operation"] as? String == operation,
              validFence(value), sameFence(value, wire), boolean(value["snapshot_consistent"]) == false,
              let location = value["location"] as? [String: Any], validLocation(location),
              (expectedLocation == nil || exactLocation(location, expectedLocation!)),
              let byteCount = asciiJSONSize(value), byteCount <= 196608
        else { throw Fault.invalidReply }
        if operation == "search_recursive" { try admitSearch(value, wire: canonical, location: location) }
        else { try admitText(value, wire: canonical, location: location) }
    }

    private static func admitSearch(_ value: [String: Any], wire: [String: Any], location: [String: Any]) throws {
        let fields: Set<String> = ["directory_ref", "keyword", "recursive", "match_mode", "entries", "next_cursor", "enumeration_complete", "partial", "scanned_count", "pages", "total_scanned_count", "total_pages", "stopped_reasons", "stopped_reason"]
        guard Set(value.keys) == replyBase.union(fields), boolean(value["recursive"]) == true,
              sameText(value["keyword"], wire["keyword"]),
              optionalString(value["directory_ref"], equals: wire["directory_ref"]),
              value["match_mode"] as? String == "nfc_casefold_basename_contains",
              let entries = value["entries"] as? [[String: Any]], entries.count <= Int(integer(wire["limit"])!),
              let pages = integer(value["pages"]), (0...4).contains(pages),
              let scanned = integer(value["scanned_count"]), (0...(pages * 32)).contains(scanned),
              let totalPages = integer(value["total_pages"]), totalPages >= max(1, pages),
              let totalScanned = integer(value["total_scanned_count"]), (scanned...(totalPages * 32)).contains(totalScanned),
              let reasons = value["stopped_reasons"] as? [String], reasons == Array(Set(reasons)).sorted(),
              Set(reasons).isSubset(of: ["scan_page_budget", "directory_budget", "depth_budget", "provider_incomplete"]),
              isNull(value["next_cursor"]) || hex(value["next_cursor"], 32),
              let complete = boolean(value["enumeration_complete"]), boolean(value["partial"]) == !complete,
              complete == (isNull(value["next_cursor"]) && reasons.isEmpty)
        else { throw Fault.invalidReply }
        if reasons.contains("scan_page_budget"), totalPages != 64 { throw Fault.invalidReply }
        if complete {
            guard isNull(value["stopped_reason"]) else { throw Fault.invalidReply }
        } else if let first = reasons.first {
            guard value["stopped_reason"] as? String == first else { throw Fault.invalidReply }
        } else {
            guard let reason = value["stopped_reason"] as? String,
                  reason == "result_budget" || reason == "page_budget" && pages == 4
            else { throw Fault.invalidReply }
        }
        let match = folded(wire["keyword"] as! String)
        for entry in entries {
            guard validEntry(entry, location: location), entry["kind"] as? String == "file",
                  let path = entry["path"] as? String, folded(String(path.split(separator: "/").last!)).contains(match)
            else { throw Fault.invalidReply }
        }
    }

    private static func admitText(_ value: [String: Any], wire: [String: Any], location: [String: Any]) throws {
        let fields: Set<String> = ["object_ref", "revision", "entry", "size", "bytes_read", "data_base64", "sha256_of_returned_bytes", "encoding", "text", "undecoded_tail_base64", "complete", "truncated", "next_offset", "stopped_reason", "downloadable_artifact"]
        let offset = integer(wire["offset"]) ?? 0
        guard Set(value.keys).subtracting(["offset"]) == replyBase.union(fields),
              integer(value["offset"] ?? 0) == offset,
              value["object_ref"] as? String == wire["object_ref"] as? String,
              value["revision"] as? String == wire["revision"] as? String,
              let size = integer(value["size"]), size == integer(wire["size"]),
              let entry = value["entry"] as? [String: Any], validEntry(entry, location: location),
              entry["kind"] as? String == "file", entry["object_ref"] as? String == wire["object_ref"] as? String,
              entry["revision"] as? String == wire["revision"] as? String, integer(entry["size"]) == size,
              let raw = base64(value["data_base64"]), Int64(raw.count) <= min(size-offset, integer(wire["max_bytes"])!), (raw.count > 0 || offset == size),
              integer(value["bytes_read"]) == Int64(raw.count),
              value["sha256_of_returned_bytes"] as? String == digest(raw),
              let complete = boolean(value["complete"]), complete == (offset + Int64(raw.count) == size),
              boolean(value["truncated"]) == !complete, boolean(value["downloadable_artifact"]) == false,
              (complete ? isNull(value["next_offset"]) : integer(value["next_offset"]) == offset + Int64(raw.count)),
              let tail = base64(value["undecoded_tail_base64"]),
              let decoded = utf8Prefix(raw, complete: complete)
        else { throw Fault.invalidReply }
        guard tail == decoded.tail else { throw Fault.invalidReply }
        let reason = value["stopped_reason"] as? String
        if let text = value["text"] as? String {
            guard let expected = decoded.text, !expected.contains("\0"), text.utf8.elementsEqual(expected.utf8),
                  (asciiJSONSize(value) ?? Int.max) <= textBudget,
                  value["encoding"] as? String == "utf-8",
                  complete ? isNull(value["stopped_reason"]) : reason == "text_byte_budget"
            else { throw Fault.invalidReply }
        } else {
            guard isNull(value["text"]), isNull(value["encoding"]) else { throw Fault.invalidReply }
            if reason == "binary_or_invalid_utf8" {
                guard decoded.text == nil || decoded.text!.contains("\0") else { throw Fault.invalidReply }
            } else if reason == "text_output_budget" {
                guard let text = decoded.text, !text.contains("\0") else { throw Fault.invalidReply }
                var original = value; original["text"] = text; original["encoding"] = "utf-8"
                original["stopped_reason"] = complete ? NSNull() : "text_byte_budget"
                guard let count = asciiJSONSize(original), count > textBudget else { throw Fault.invalidReply }
            } else { throw Fault.invalidReply }
        }
    }

    // Match Python's strict incremental UTF8 decoder, including valid trailing
    // prefixes only. Python defers ED A0..BF until a third byte; retain that
    // undecoded tail, never emit a surrogate or claim complete UTF8 text.
    private static func utf8Prefix(_ raw: Data, complete: Bool) -> (text: String?, tail: Data)? {
        if let text = String(data: raw, encoding: .utf8) { return (text, Data()) }
        if !complete {
            let bytes = Array(raw)
            for count in 1...min(3, bytes.count) {
                let suffix = Array(bytes.suffix(count)); let lead = suffix[0]
                let width = (0xC2...0xDF).contains(lead) ? 2 : (0xE0...0xEF).contains(lead) ? 3 : (0xF0...0xF4).contains(lead) ? 4 : 0
                guard count < width else { continue }
                var valid = true
                for index in 1..<count {
                    let b = suffix[index]
                    if !(0x80...0xBF).contains(b) || index == 1 && (lead == 0xE0 && b < 0xA0 || lead == 0xF0 && b < 0x90 || lead == 0xF4 && b > 0x8F) { valid = false }
                }
                if valid, let text = String(data: raw.dropLast(count), encoding: .utf8) { return (text, Data(suffix)) }
            }
        }
        return (nil, Data())
    }

    private static func validEntry(_ value: [String: Any], location: [String: Any]) -> Bool {
        let keys: Set<String> = ["object_ref", "kind", "revision", "size", "modified_ns", "media_kind", "closed", "revision_basis", "path"]
        guard Set(value.keys) == keys, hex(value["object_ref"], 64), hex(value["revision"], 64),
              value["kind"] as? String == "file", inRange(value["size"], 0, Int64.max),
              isNull(value["modified_ns"]) || integer(value["modified_ns"]) != nil,
              ["image", "video", "audio", "other"].contains(value["media_kind"] as? String ?? ""),
              isNull(value["closed"]), value["revision_basis"] as? String == "metadata",
              let path = value["path"] as? String, relative(path), let root = location["root"] as? String
        else { return false }
        return root.isEmpty || path.utf8.starts(with: (root + "/").utf8)
    }
    private static func validLocation(_ value: [String: Any]) -> Bool {
        guard Set(value.keys) == ["host", "port", "share", "root"],
              matches(value["host"], "^[A-Za-z0-9.-]{1,253}$"), inRange(value["port"], 1, 65535),
              let share = value["share"] as? String, relative(share), !share.contains("/"), share.utf8.count <= 255,
              let root = value["root"] as? String, root.isEmpty || relative(root)
        else { return false }; return true
    }
    private static func exactLocation(_ left: [String: Any], _ right: [String: Any]) -> Bool {
        validLocation(right) && ["host", "share", "root"].allSatisfy { sameText(left[$0], right[$0]) } && integer(left["port"]) == integer(right["port"])
    }
    private static func relative(_ path: String) -> Bool {
        !path.isEmpty && path.utf8.count <= 1024 && !path.contains("\\") && !path.contains(":") && !path.unicodeScalars.contains { $0.value < 32 } && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255 }
    }
    private static func validFence(_ value: [String: Any]) -> Bool {
        matches(value["source_ref"], "^[A-Za-z0-9_-]{1,96}$") && inRange(value["config_generation"], 1, Int64.max) && hex(value["connection_epoch"], 32)
    }
    private static func sameFence(_ left: [String: Any], _ right: [String: Any]) -> Bool {
        ["source_ref", "connection_epoch"].allSatisfy { sameText(left[$0], right[$0]) } && integer(left["config_generation"]) == integer(right["config_generation"])
    }
    private static func sameText(_ left: Any?, _ right: Any?) -> Bool {
        guard let a = left as? String, let b = right as? String else { return false }; return a.utf8.elementsEqual(b.utf8)
    }
    private static func folded(_ text: String) -> String { text.precomposedStringWithCanonicalMapping.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX")) }
    private static func matches(_ value: Any?, _ pattern: String) -> Bool {
        guard let text = value as? String, let range = text.range(of: pattern, options: .regularExpression) else { return false }
        return range == text.startIndex..<text.endIndex
    }
    private static func hex(_ value: Any?, _ count: Int) -> Bool { matches(value, "^[0-9a-f]{\(count)}$") }
    private static func isNull(_ value: Any?) -> Bool { value is NSNull }
    private static func boolean(_ value: Any?) -> Bool? {
        guard let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }; return n.boolValue
    }
    private static func integer(_ value: Any?) -> Int64? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
              !["f", "d"].contains(String(cString: n.objCType)), let result = Int64(n.stringValue) else { return nil }; return result
    }
    private static func inRange(_ value: Any?, _ low: Int64, _ high: Int64) -> Bool { integer(value).map { low <= $0 && $0 <= high } ?? false }
    private static func optionalString(_ value: Any?, equals expected: Any?) -> Bool { expected == nil ? isNull(value) : value as? String == expected as? String }
    private static func base64(_ value: Any?) -> Data? {
        guard let text = value as? String, let data = Data(base64Encoded: text), data.base64EncodedString() == text else { return nil }; return data
    }
    private static func digest(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }

    /// Exact size of Python json.dumps(ensure_ascii=True) with default separators.
    /// Property order does not affect size. Only finite admitted JSON types occur.
    private static func asciiJSONSize(_ value: Any) -> Int? {
        // Measure the actual UTF8 transport, not a hypothetical ASCII re-encoding.
        (try? JSONSerialization.data(withJSONObject:value,options:[.fragmentsAllowed,.withoutEscapingSlashes]))?.count
    }
}
