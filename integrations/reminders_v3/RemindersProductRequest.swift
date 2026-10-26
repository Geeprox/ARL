import Foundation
import CryptoKit
import ARLRemindersCore

/// Full-field product mutations reuse the existing adapter and journal. This
/// type grants no authority, reads no EventKit objects and never starts a host.
struct RemindersProductRequest {
    let taskID: String
    let request: ARLRemindersCore.Request
    let digest: String
    static let namespace = "arl.reminders.product.v1:"
    static let mutations: Set<String> = ["list.create", "create", "update", "complete", "uncomplete", "delete"]

    static func operationID(_ taskID: String) throws -> String {
        guard UUID(uuidString: taskID)?.uuidString.lowercased() == taskID else {
            throw AdapterFault("invalid_product_task_id")
        }
        let hex = SHA256.hash(data: Data((namespace + taskID).utf8)).map { String(format: "%02x", $0) }.joined()
        let h = Array(hex.prefix(32))
        return String(h[0..<8]) + "-" + String(h[8..<12]) + "-" + String(h[12..<16]) + "-" + String(h[16..<20]) + "-" + String(h[20..<32])
    }

    static func decode(taskID: String, requestJSON: Data) throws -> Self {
        let operationID = try operationID(taskID)
        try uniqueKeys(requestJSON)
        let request = try ARLRemindersCore.Request.decode(requestJSON)
        guard mutations.contains(request.operation), request.isMutation,
              request.args.operation_id == operationID else {
            throw AdapterFault("product_operation_mismatch")
        }
        return .init(taskID: taskID, request: request, digest: try ARLRemindersCore.digest(request))
    }

    /// Reject escaped duplicate keys at every level before Codable/JSONSerialization
    /// can collapse them. Foundation first validates syntax, then this bounded
    /// scanner only identifies object-key string tokens; it does not parse values.
    static func uniqueKeys(_ data: Data) throws {
        guard data.count <= 16_384,
              (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
            throw AdapterFault("invalid_arguments")
        }
        let b = Array(data); var i = 0; var depth = 0; var objects: [Set<String>] = []
        func whitespace(_ byte: UInt8) -> Bool { [9, 10, 13, 32].contains(byte) }
        while i < b.count {
            switch b[i] {
            case 123: depth += 1; objects.append([]); i += 1
            case 91: depth += 1; i += 1
            case 125: depth -= 1; guard !objects.isEmpty else { throw AdapterFault("invalid_arguments") }; objects.removeLast(); i += 1
            case 93: depth -= 1; i += 1
            case 34:
                let start = i; i += 1; var escaped = false; var ended = false
                while i < b.count {
                    let byte = b[i]; i += 1
                    if escaped { escaped = false; continue }
                    if byte == 92 { escaped = true; continue }
                    if byte == 34 { ended = true; break }
                }
                guard ended else { throw AdapterFault("invalid_arguments") }
                var next = i; while next < b.count && whitespace(b[next]) { next += 1 }
                if next < b.count && b[next] == 58 {
                    guard !objects.isEmpty,
                          let key = try JSONSerialization.jsonObject(with: Data(b[start..<i]), options: .fragmentsAllowed) as? String,
                          objects[objects.count - 1].insert(key).inserted else {
                        throw AdapterFault("duplicate_product_key")
                    }
                }
            default: i += 1
            }
            guard depth >= 0 && depth <= 32 else { throw AdapterFault("invalid_arguments") }
        }
        guard depth == 0 && objects.isEmpty else { throw AdapterFault("invalid_arguments") }
    }
}
