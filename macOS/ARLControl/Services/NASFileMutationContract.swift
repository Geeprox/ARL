import Foundation
import CoreFoundation
import CryptoKit

/// Candidate DTOs only. No tool registration, credential access or scope issuer.
/// Caller parses JSON using the existing duplicate-key/depth-limited owner parser.
enum NASFileMutationFault: Error { case invalid, expired, unsupported, stale, invalidReply }

struct NASFileMutationRequest {
    static let maximumBytes = 32 * 1024 // bounded inline/chunk bytes; owner request is 64KiB
    static let maximumTransferBytes = 1024 * 1024 // existing upload/read-session cap
    let operation: String
    let operationID: String
    let sourceRef: String
    let generation: Int64
    let epoch: String
    let arguments: [String: Any]

    init(value: [String: Any], now: TimeInterval = Date().timeIntervalSince1970) throws {
        let common: Set<String> = ["operation", "operation_id", "source_ref", "config_generation", "connection_epoch"]
        let fields: [String: Set<String>] = [
            "upload_new": value["transfer_ref"] == nil ? ["directory_ref", "name", "attachment"] : ["directory_ref", "name", "transfer_ref", "size", "sha256"],
            "mkdir": ["directory_ref", "name"],
            "move": ["directory_ref", "name", "object_ref", "revision"],
            "download": ["object_ref", "revision", "name", "size"]]
        guard let op = value["operation"] as? String, let extra = fields[op],
              Set(value.keys) == common.union(extra),
              let id = value["operation_id"] as? String, UUID(uuidString: id)?.uuidString.lowercased() == id,
              let source = value["source_ref"] as? String, Self.matches(source, "^[A-Za-z0-9_-]{1,96}$"),
              let gen = Self.integer(value["config_generation"]), gen > 0,
              let epoch = value["connection_epoch"] as? String, Self.hex(epoch, 32),
              let name = value["name"] as? String, Self.name(name)
        else { throw NASFileMutationFault.invalid }
        if extra.contains("directory_ref"), !(value["directory_ref"] is NSNull) {
            guard let ref = value["directory_ref"] as? String, Self.hex(ref, 64) else { throw NASFileMutationFault.invalid }
        }
        if op == "move" || op == "download" {
            guard let ref = value["object_ref"] as? String, Self.hex(ref, 64),
                  let revision = value["revision"] as? String, Self.hex(revision, 64)
            else { throw NASFileMutationFault.invalid }
        }
        if op == "download" {
            guard let size = Self.integer(value["size"]), (0...Int64(Self.maximumTransferBytes)).contains(size)
            else { throw NASFileMutationFault.invalid }
        }
        if op == "upload_new" {
            if let ref = value["transfer_ref"] as? String {
                guard Self.hex(ref, 64), let size = Self.integer(value["size"]), size <= Self.maximumTransferBytes,
                      let sha = value["sha256"] as? String, Self.hex(sha, 64) else { throw NASFileMutationFault.invalid }
            } else {
                guard let attachment = value["attachment"] as? [String: Any] else { throw NASFileMutationFault.invalid }
                _ = try NASFileTransferInput(value: attachment, now: now)
            }
        }
        operation = op; operationID = id; sourceRef = source; generation = gen; self.epoch = epoch; arguments = value
    }

    static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }
    static func hex(_ text: String, _ count: Int) -> Bool { matches(text, "^[0-9a-f]{\(count)}$") }
    static func integer(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              !String(cString: number.objCType).contains("f"), !String(cString: number.objCType).contains("d"),
              number.decimalValue >= 0, number.decimalValue <= Decimal(Int64.max)
        else { return nil }
        return number.int64Value
    }
    static func name(_ text: String) -> Bool {
        let reserved = Set(["CON", "PRN", "AUX", "NUL"] + (1...9).flatMap { ["COM\($0)", "LPT\($0)"] })
        return (1...255).contains(text.utf8.count) && matches(text, "^[A-Za-z0-9_.-]+$") &&
            text != "." && text != ".." && !text.hasSuffix(".") && !text.lowercased().hasPrefix(".arl-") &&
            !reserved.contains(text.split(separator: ".", omittingEmptySubsequences: false).first.map(String.init)?.uppercased() ?? "")
    }

    /// Validate the full native return before forwarding it unchanged.
    func admitMutationResult(_ value: [String: Any]) throws {
        let keys: Set<String> = ["schema_version", "operation", "operation_id", "source_ref", "config_generation", "connection_epoch",
                                 "status", "failure", "entry", "bytes_confirmed", "content_sha256", "retry_allowed"]
        guard operation != "download", Set(value.keys) == keys,
              Self.integer(value["schema_version"]) == 1,
              value["operation"] as? String == operation, value["operation_id"] as? String == operationID,
              value["source_ref"] as? String == sourceRef, Self.integer(value["config_generation"]) == generation,
              value["connection_epoch"] as? String == epoch,
              let retry = value["retry_allowed"] as? NSNumber, CFGetTypeID(retry) == CFBooleanGetTypeID(), !retry.boolValue,
              let status = value["status"] as? String, ["committed", "held", "rejected", "uncertain"].contains(status),
              let bytes = Self.integer(value["bytes_confirmed"]), bytes <= Self.maximumTransferBytes
        else { throw NASFileMutationFault.invalidReply }
        if status == "committed" {
            guard value["failure"] is NSNull else { throw NASFileMutationFault.invalidReply }
            if operation == "upload_new" {
                let attachment = arguments["attachment"] as? [String: Any] ?? arguments
                guard bytes == Self.integer(attachment["size"]), value["content_sha256"] as? String == attachment["sha256"] as? String,
                      value["entry"] is NSNull else { throw NASFileMutationFault.invalidReply }
            } else {
                guard bytes == 0, value["content_sha256"] is NSNull,
                      let entry = value["entry"] as? [String: Any],
                      entry["kind"] as? String == (operation == "mkdir" ? "directory" : "file"),
                      let revision = entry["revision"] as? String, Self.hex(revision, 64),
                      let path = entry["path"] as? String,
                      path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ Self.name(String($0)) }),
                      path.split(separator: "/").last.map(String.init) == arguments["name"] as? String
                else { throw NASFileMutationFault.invalidReply }
            }
        } else {
            guard let failure = value["failure"] as? String, Self.matches(failure, "^[a-z_]{1,64}$"),
                  value["entry"] is NSNull, value["content_sha256"] is NSNull
            else { throw NASFileMutationFault.invalidReply }
        }
    }

    func admitDownloadResult(_ value: [String: Any]) throws {
        let keys: Set<String> = ["schema_version", "operation", "operation_id", "source_ref", "config_generation", "connection_epoch",
                                 "object_ref", "revision", "status", "failure", "transfer_kind", "name", "size", "sha256",
                                 "data_base64", "downloadable_artifact", "delivery_code"]
        guard operation == "download", Set(value.keys) == keys, Self.integer(value["schema_version"]) == 1,
              value["operation"] as? String == operation, value["operation_id"] as? String == operationID,
              value["source_ref"] as? String == sourceRef, Self.integer(value["config_generation"]) == generation,
              value["connection_epoch"] as? String == epoch,
              value["object_ref"] as? String == arguments["object_ref"] as? String,
              value["revision"] as? String == arguments["revision"] as? String,
              value["name"] as? String == arguments["name"] as? String,
              value["status"] as? String == "read", value["failure"] is NSNull,
              value["transfer_kind"] as? String == "inline_base64",
              let artifact = value["downloadable_artifact"] as? NSNumber,
              CFGetTypeID(artifact) == CFBooleanGetTypeID(), !artifact.boolValue,
              value["delivery_code"] as? String == "platform_file_publisher_required",
              let size = Self.integer(value["size"]), size == Self.integer(arguments["size"]), size <= Self.maximumBytes,
              let encoded = value["data_base64"] as? String, encoded.utf8.count <= 4 * ((Self.maximumBytes + 2) / 3),
              let bytes = Data(base64Encoded: encoded), bytes.count == size, bytes.base64EncodedString() == encoded,
              let sha = value["sha256"] as? String, Self.hex(sha, 64),
              SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == sha
        else { throw NASFileMutationFault.invalidReply }
    }

    func admitTransferManifest(_ value: [String: Any]) throws {
        let keys: Set<String> = ["schema_version", "operation_id", "source_ref", "config_generation", "connection_epoch",
                                 "transfer_ref", "name", "size", "sha256", "expires_in_seconds", "complete", "direction", "downloadable_artifact"]
        guard operation == "download" || operation == "upload_new", Set(value.keys) == keys,
              Self.integer(value["schema_version"]) == 1, value["operation_id"] as? String == operationID,
              value["source_ref"] as? String == sourceRef, Self.integer(value["config_generation"]) == generation,
              value["connection_epoch"] as? String == epoch,
              let ref = value["transfer_ref"] as? String, Self.hex(ref, 64),
              value["name"] as? String == arguments["name"] as? String,
              let size = Self.integer(value["size"]), size == Self.integer(arguments["size"]), size <= Self.maximumTransferBytes,
              let sha = value["sha256"] as? String, Self.hex(sha, 64),
              let expires = value["expires_in_seconds"] as? NSNumber, CFGetTypeID(expires) != CFBooleanGetTypeID(),
              expires.doubleValue.isFinite, expires.doubleValue > 0, expires.doubleValue <= 120,
              let complete = value["complete"] as? NSNumber, CFGetTypeID(complete) == CFBooleanGetTypeID(), complete.boolValue,
              let artifact = value["downloadable_artifact"] as? NSNumber, CFGetTypeID(artifact) == CFBooleanGetTypeID(), !artifact.boolValue,
              value["direction"] as? String == (operation == "download" ? "download" : "upload")
        else { throw NASFileMutationFault.invalidReply }
        if operation == "upload_new" {
            guard ref == arguments["transfer_ref"] as? String, sha == arguments["sha256"] as? String else { throw NASFileMutationFault.invalidReply }
        }
    }
}

struct NASFileTransferInput {
    let name: String
    let bytes: Data
    let sha256: String
    init(value: [String: Any], now: TimeInterval) throws {
        guard Set(value.keys) == ["transfer_kind", "name", "size", "sha256", "data_base64", "expires_at"],
              value["transfer_kind"] as? String == "inline_base64" else { throw NASFileMutationFault.unsupported }
        guard let expires = value["expires_at"] as? NSNumber, CFGetTypeID(expires) != CFBooleanGetTypeID(),
              now.isFinite, expires.doubleValue.isFinite, expires.doubleValue > now, expires.doubleValue <= now + 120
        else { throw NASFileMutationFault.expired }
        guard let name = value["name"] as? String, NASFileMutationRequest.name(name),
              let size = NASFileMutationRequest.integer(value["size"]), size <= NASFileMutationRequest.maximumBytes,
              let sha = value["sha256"] as? String, NASFileMutationRequest.hex(sha, 64),
              let encoded = value["data_base64"] as? String, encoded.utf8.count <= 4 * ((NASFileMutationRequest.maximumBytes + 2) / 3),
              let bytes = Data(base64Encoded: encoded), bytes.base64EncodedString() == encoded,
              bytes.count == size, SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == sha
        else { throw NASFileMutationFault.invalid }
        self.name = name; self.bytes = bytes; sha256 = sha
    }
}
