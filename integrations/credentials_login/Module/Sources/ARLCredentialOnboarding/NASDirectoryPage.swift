import Foundation
import CoreFoundation

/// Native configuration UI only. Paths stay relative to the admitted root;
/// the public metadata/Mio response remains opaque.
public struct NASDirectoryPage: Equatable, Sendable {
    public let path: String
    public let directories: [String]
    public let nextCursor: String?
    // Literal SMB names: no URL decoding occurs in the pinned runtime.
    public static func validatePath(_ path: String) throws {
        guard path.utf8.count <= 1024,
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !path.contains(where: { "\\:".contains($0) }),
              path.isEmpty || path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({
                  !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255
              }) else { throw CredentialError.invalidInput }
    }
    public init(path: String, directories: [String], nextCursor: String?) throws {
        try Self.validatePath(path)
        guard directories.count <= 128, Set(directories).count == directories.count,
              nextCursor == nil || nextCursor?.range(of: "^[0-9a-f]{32}$", options: .regularExpression) != nil
        else { throw CredentialError.invalidInput }
        for entry in directories {
            try Self.validatePath(entry)
            let components = entry.split(separator: "/")
            guard !components.isEmpty, components.dropLast().joined(separator: "/") == path
            else { throw CredentialError.invalidInput }
        }
        self.path = path; self.directories = directories; self.nextCursor = nextCursor
    }
    init(data: Data, expectedPath: String) throws {
        guard data.count <= 262144,
              let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(value.keys) == ["path", "directories", "next_cursor"], value["path"] as? String == expectedPath,
              let directories = value["directories"] as? [String],
              value["next_cursor"] is NSNull || value["next_cursor"] is String
        else { throw CredentialError.invalidInput }
        try self.init(path: expectedPath, directories: directories, nextCursor: value["next_cursor"] as? String)
    }
}


/// Exact read-only file tool DTO shared by the native UI and authenticated owner.
/// Endpoint, credentials, executable paths and caller grants cannot be selected here.
public struct NASFileRequest: Equatable, Sendable {
    public let operation: String
    public let wireJSON: Data
    public var toolName: String { "mio_nas_" + operation }
    public init(tool: String, argumentsJSON: Data) throws {
        if NASDocumentContract.names.contains(tool) {
            _ = try MusicStrictJSON.object(argumentsJSON, limit: 16384)
            let value = try NASDocumentContract.request(tool: tool, argumentsJSON: argumentsJSON)
            operation = "read_document"
            wireJSON = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
            return
        }
        if NASFileReaderContract.names.contains(tool) {
            do {
                _ = try MusicStrictJSON.object(argumentsJSON, limit: 16384)
                let value = try NASFileReaderContract.request(tool: tool, argumentsJSON: argumentsJSON)
                operation = String(tool.dropFirst("mio_nas_".count))
                wireJSON = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
                return
            } catch { throw NASRuntimeFailure.invalidRequest }
        }
        guard ["mio_nas_list", "mio_nas_search", "mio_nas_read"].contains(tool),
              var value = try? MusicStrictJSON.object(argumentsJSON, limit: 16384)
        else { throw NASRuntimeFailure.invalidRequest }
        let operation = String(tool.dropFirst("mio_nas_".count))
        if operation == "read" {
            guard Set(value.keys) == ["source_ref", "config_generation", "connection_epoch", "object_ref", "revision", "offset", "length"],
                  Self.text(value["source_ref"], pattern: "^[A-Za-z0-9_-]{1,96}$"),
                  Self.hex(value["connection_epoch"], 32), Self.hex(value["object_ref"], 64), Self.hex(value["revision"], 64),
                  let generation = Self.integer(value["config_generation"]), generation > 0,
                  let offset = Self.integer(value["offset"]), offset >= 0,
                  let length = Self.integer(value["length"]), (1...131072).contains(length)
            else { throw NASRuntimeFailure.invalidRequest }
        } else {
            let keys: Set<String> = operation == "search" ? ["keyword", "directory_ref", "cursor", "limit"] : ["directory_ref", "cursor", "limit"]
            guard Set(value.keys).isSubset(of: keys),
                  value["directory_ref"] == nil || Self.hex(value["directory_ref"], 64),
                  value["cursor"] == nil || Self.hex(value["cursor"], 32)
            else { throw NASRuntimeFailure.invalidRequest }
            if operation == "search" {
                guard let keyword = value["keyword"] as? String, (1...256).contains(keyword.utf8.count),
                      !keyword.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
                else { throw NASRuntimeFailure.invalidRequest }
            }
            if value["limit"] == nil { value["limit"] = 16 }
            guard let limit = Self.integer(value["limit"]), (1...32).contains(limit)
            else { throw NASRuntimeFailure.invalidRequest }
        }
        value["operation"] = operation
        self.operation = operation
        wireJSON = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
    }
    static func integer(_ value: Any?) -> Int? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
              n.doubleValue.isFinite, n.doubleValue.rounded(.towardZero) == n.doubleValue,
              n.compare(NSNumber(value: Int64.min)) != .orderedAscending,
              n.compare(NSNumber(value: Int64.max)) != .orderedDescending else { return nil }
        return n.intValue
    }
    static func text(_ value: Any?, pattern: String) -> Bool {
        guard let text = value as? String else { return false }
        return text.range(of: pattern, options: .regularExpression) != nil
    }
    static func hex(_ value: Any?, _ count: Int) -> Bool { text(value, pattern: "^[0-9a-f]{" + String(count) + "}$") }
    static func boolean(_ value: Any?, _ expected: Bool) -> Bool {
        guard let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return false }
        return n.boolValue == expected
    }

    /// Preserve the original result bytes after validating exact scope and bounds.
    func validateResult(_ data: Data, configuration: NASConnectionConfiguration, epoch: String) throws {
        if NASDocumentContract.names.contains(toolName) {
            do {
                let value = try MusicStrictJSON.object(data, limit: 196608, maximumDepth: 16)
                let request = try MusicStrictJSON.object(wireJSON, limit: 16384)
                guard request["source_ref"] as? String == configuration.sourceRef,
                      Self.integer(request["config_generation"]) == Int(configuration.generation),
                      request["connection_epoch"] as? String == epoch else { throw NASRuntimeFailure.invalidReply }
                try NASDocumentContract.admit(value, request: request,
                    expectedLocation: ["host":configuration.host,"port":configuration.port,"share":configuration.share,"root":configuration.root])
                return
            } catch { throw NASRuntimeFailure.invalidReply }
        }
        if NASFileReaderContract.names.contains(toolName) {
            do {
                let value = try MusicStrictJSON.object(data, limit: 196608, maximumDepth: 16)
                let request = try MusicStrictJSON.object(wireJSON, limit: 16384)
                guard request["source_ref"] as? String == configuration.sourceRef,
                      Self.integer(request["config_generation"]) == Int(configuration.generation),
                      request["connection_epoch"] as? String == epoch else { throw NASRuntimeFailure.invalidReply }
                try NASFileReaderContract.admit(value, request: request,
                    expectedLocation: ["host":configuration.host,"port":configuration.port,"share":configuration.share,"root":configuration.root])
                return
            } catch { throw NASRuntimeFailure.invalidReply }
        }
        let value = try MusicStrictJSON.object(data, limit: 196608, maximumDepth: 16)
        let request = try MusicStrictJSON.object(wireJSON, limit: 16384)
        let base: Set<String> = ["schema_version", "operation", "source_ref", "config_generation", "connection_epoch", "location", "snapshot_consistent"]
        let keys = operation == "read"
            ? base.union(["entry", "offset", "length", "bytes_read", "data_base64", "eof", "next_offset"])
            : base.union(["directory_ref", "keyword", "entries", "match_mode", "next_cursor", "enumeration_complete", "partial", "stopped_reason", "scanned_count", "pages", "recursive"])
        guard Set(value.keys) == keys, Self.integer(value["schema_version"]) == 1,
              value["operation"] as? String == operation, value["source_ref"] as? String == configuration.sourceRef,
              Self.integer(value["config_generation"]) == Int(configuration.generation),
              value["connection_epoch"] as? String == epoch, Self.hex(epoch, 32),
              Self.boolean(value["snapshot_consistent"], false),
              let location = value["location"] as? [String: Any], Set(location.keys) == ["host", "port", "share", "root"],
              location["host"] as? String == configuration.host, Self.integer(location["port"]) == configuration.port,
              location["share"] as? String == configuration.share, location["root"] as? String == configuration.root
        else { throw NASRuntimeFailure.invalidReply }
        func entry(_ value: Any?) throws -> [String: Any] {
            guard let e = value as? [String: Any], Set(e.keys) == ["object_ref", "kind", "revision", "size", "modified_ns", "media_kind", "closed", "revision_basis", "path"],
                  Self.hex(e["object_ref"], 64), Self.hex(e["revision"], 64),
                  ["file", "directory"].contains(e["kind"] as? String ?? ""),
                  let size = Self.integer(e["size"]), size >= 0,
                  e["modified_ns"] is NSNull || (Self.integer(e["modified_ns"]) ?? -1) >= 0,
                  ["image", "video", "audio", "other"].contains(e["media_kind"] as? String ?? ""),
                  e["closed"] is NSNull, e["revision_basis"] as? String == "metadata",
                  let path = e["path"] as? String else { throw NASRuntimeFailure.invalidReply }
            let prefix = configuration.root.isEmpty ? "" : configuration.root + "/"
            guard path.hasPrefix(prefix) else { throw NASRuntimeFailure.invalidReply }
            try NASDirectoryPage.validatePath(String(path.dropFirst(prefix.count)))
            guard path.count > prefix.count else { throw NASRuntimeFailure.invalidReply }
            return e
        }
        if operation == "read" {
            let e = try entry(value["entry"])
            guard e["kind"] as? String == "file", e["object_ref"] as? String == request["object_ref"] as? String,
                  e["revision"] as? String == request["revision"] as? String,
                  request["source_ref"] as? String == configuration.sourceRef,
                  Self.integer(request["config_generation"]) == Int(configuration.generation), request["connection_epoch"] as? String == epoch,
                  let offset = Self.integer(value["offset"]), offset == Self.integer(request["offset"]),
                  let length = Self.integer(value["length"]), length == Self.integer(request["length"]),
                  let count = Self.integer(value["bytes_read"]), let size = Self.integer(e["size"]), offset <= size,
                  count == min(length, size - offset), let raw = value["data_base64"] as? String,
                  let bytes = Data(base64Encoded: raw), bytes.count == count,
                  Self.boolean(value["eof"], count == size - offset),
                  count == size - offset ? value["next_offset"] is NSNull : Self.integer(value["next_offset"]) == offset + count
            else { throw NASRuntimeFailure.invalidReply }
        } else {
            guard let entries = value["entries"] as? [[String: Any]], entries.count <= (Self.integer(request["limit"]) ?? 0),
                  Set(entries.compactMap { $0["object_ref"] as? String }).count == entries.count,
                  (request["directory_ref"] == nil ? value["directory_ref"] is NSNull : value["directory_ref"] as? String == request["directory_ref"] as? String),
                  (request["keyword"] == nil ? value["keyword"] is NSNull : value["keyword"] as? String == request["keyword"] as? String),
                  value["next_cursor"] is NSNull || Self.hex(value["next_cursor"], 32),
                  let pages = Self.integer(value["pages"]), (0...2).contains(pages),
                  let scanned = Self.integer(value["scanned_count"]), (0...256).contains(scanned),
                  Self.boolean(value["recursive"], false)
            else { throw NASRuntimeFailure.invalidReply }
            let complete = Self.boolean(value["enumeration_complete"], true)
            guard Self.boolean(value["enumeration_complete"], complete), Self.boolean(value["partial"], !complete),
                  complete ? (value["next_cursor"] is NSNull && value["stopped_reason"] is NSNull)
                    : ["result_budget", "page_budget", "provider_incomplete"].contains(value["stopped_reason"] as? String ?? ""),
                  operation == "search" ? value["match_mode"] as? String == "nfc_casefold_basename_contains" : value["match_mode"] is NSNull
            else { throw NASRuntimeFailure.invalidReply }
            for item in entries { _ = try entry(item) }
        }
    }
}
