import Foundation

// Private helper transport only. Not an ARL/Mio published tool or arl/1 change.
enum NotesWire {
    static let maxRequestFrame = 32768
    static let maxResponseFrame = 4096
    static func encode(_ object: [String: Any], limit: Int) throws -> Data {
        let raw = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        guard raw.count + 1 <= limit else { throw ReviewFault("frame_too_large") }
        return raw
    }
    static func create(_ raw: Data) throws -> Data {
        _ = try NotesCreateProposal(raw)
        return try encode(["schema_version": 1, "method": "create", "request_base64": raw.base64EncodedString(),
                           "request_sha256": digest(raw), "request_byte_count": raw.count], limit: maxRequestFrame)
    }
    static func unpackCreate(_ frame: Data) throws -> Data {
        let v = try flatObject(frame, limit: maxRequestFrame - 1)
        guard Set(v.keys) == Set(["schema_version", "method", "request_base64", "request_sha256", "request_byte_count"]),
              integer(v["schema_version"]) == 1, v["method"] as? String == "create",
              let encoded = v["request_base64"] as? String, let raw = Data(base64Encoded: encoded), raw.base64EncodedString() == encoded,
              integer(v["request_byte_count"]) == Int64(raw.count), v["request_sha256"] as? String == digest(raw) else { throw ReviewFault("invalid_transport_request") }
        _ = try NotesCreateProposal(raw)
        return raw
    }
    static func cancel(_ operation: String, requestHash: String) throws -> Data {
        guard uuid(operation), requestHash.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil else { throw ReviewFault("invalid_transport_request") }
        return try encode(["schema_version": 1, "method": "cancel", "operation_id": operation, "request_sha256": requestHash], limit: maxRequestFrame)
    }
    static func response(_ method: String, receipt: [String: Any]? = nil, error: String? = nil) throws -> Data {
        let json: Any
        if let receipt { json = String(decoding: try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys]), as: UTF8.self) }
        else { json = NSNull() }
        return try encode(["schema_version": 1, "method": method, "status": error == nil ? "ok" : "rejected",
                           "receipt_json": json, "error_code": error as Any? ?? NSNull()], limit: maxResponseFrame)
    }
    static func receipt(_ frame: Data, proposal: NotesCreateProposal, targetHash: String) throws -> [String: Any] {
        let v = try flatObject(frame, limit: maxResponseFrame - 1)
        guard Set(v.keys) == Set(["schema_version", "method", "status", "receipt_json", "error_code"]),
              integer(v["schema_version"]) == 1, v["method"] as? String == "create" else { throw ReviewFault("invalid_transport_response") }
        if v["status"] as? String == "rejected" {
            guard v["receipt_json"] is NSNull, let code = v["error_code"] as? String, NotesHostSession.errors.contains(code) else { throw ReviewFault("invalid_transport_response") }
            throw ReviewFault(code)
        }
        guard v["status"] as? String == "ok", v["error_code"] is NSNull,
              let text = v["receipt_json"] as? String else { throw ReviewFault("invalid_transport_response") }
        let r = try flatObject(Data(text.utf8), limit: 2048)
        guard Set(r.keys) == Set(["schema_version", "operation_id", "request_sha256", "target_binding_sha256", "persistence", "cloud_sync"]),
              integer(r["schema_version"]) == 1, r["operation_id"] as? String == proposal.operationID,
              r["request_sha256"] as? String == proposal.rawHash, r["target_binding_sha256"] as? String == targetHash,
              r["persistence"] as? String == "created_local", r["cloud_sync"] as? String == "not_checked" else { throw ReviewFault("receipt_mismatch") }
        return r
    }
}
