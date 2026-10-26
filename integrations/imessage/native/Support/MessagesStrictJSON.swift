import Foundation

struct MessagesJSON: @unchecked Sendable {
    let value: [String: Any]
    init(_ value: [String: Any]) { self.value = value }
    var data: Data { get throws { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]) } }
    static func decode(_ data: Data, limit: Int = 65536) throws -> Self {
        guard data.count <= limit else { throw MessagesTransportFault("invalid_request") }
        var parser = DuplicateKeyParser(bytes: Array(data))
        try parser.value(depth: 0)
        parser.spaces()
        guard parser.index == data.count,
              let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MessagesTransportFault("invalid_request")
        }
        return Self(value)
    }
}

private struct DuplicateKeyParser {
    let bytes: [UInt8]
    var index = 0
    mutating func spaces() { while index < bytes.count && [9,10,13,32].contains(bytes[index]) { index += 1 } }
    mutating func quoted() throws -> String {
        spaces()
        guard index < bytes.count, bytes[index] == 34 else { throw MessagesTransportFault("invalid_request") }
        let start = index
        index += 1
        var escape = false
        while index < bytes.count {
            let byte = bytes[index]; index += 1
            if escape { escape = false; continue }
            if byte == 92 { escape = true; continue }
            if byte == 34, let value = try JSONSerialization.jsonObject(with: Data(bytes[start..<index]), options: .fragmentsAllowed) as? String { return value }
        }
        throw MessagesTransportFault("invalid_request")
    }
    mutating func value(depth: Int) throws {
        guard depth < 16 else { throw MessagesTransportFault("invalid_request") }
        spaces()
        guard index < bytes.count else { throw MessagesTransportFault("invalid_request") }
        if bytes[index] == 34 { _ = try quoted(); return }
        if bytes[index] == 123 {
            index += 1; spaces(); var keys = Set<String>()
            if index < bytes.count, bytes[index] == 125 { index += 1; return }
            while true {
                let key = try quoted()
                guard keys.insert(key).inserted else { throw MessagesTransportFault("invalid_request") }
                spaces(); guard index < bytes.count, bytes[index] == 58 else { throw MessagesTransportFault("invalid_request") }
                index += 1; try value(depth: depth + 1); spaces()
                guard index < bytes.count else { throw MessagesTransportFault("invalid_request") }
                if bytes[index] == 125 { index += 1; return }
                guard bytes[index] == 44 else { throw MessagesTransportFault("invalid_request") }; index += 1
            }
        }
        if bytes[index] == 91 {
            index += 1; spaces()
            if index < bytes.count, bytes[index] == 93 { index += 1; return }
            while true {
                try value(depth: depth + 1); spaces()
                guard index < bytes.count else { throw MessagesTransportFault("invalid_request") }
                if bytes[index] == 93 { index += 1; return }
                guard bytes[index] == 44 else { throw MessagesTransportFault("invalid_request") }; index += 1
            }
        }
        let start = index
        while index < bytes.count && ![44,93,125,9,10,13,32].contains(bytes[index]) { index += 1 }
        guard index > start else { throw MessagesTransportFault("invalid_request") }
    }
}

struct MessagesControlFrame: Sendable {
    let requestID: String
    let command: String
    let arguments: [String: String]
    let json: MessagesJSON
    static let fields: [String: Set<String>] = [
        "snapshot":[], "begin":[], "refresh":[], "open_messages":[], "confirm_account":["report"],
        "permission_action":["capability_id","action"], "discover_groups":[], "select_group":["candidate_id"],
        "prepare_test":[], "start_test":["plan_id"], "verify_mio":[], "disable":[], "cancel":[], "reconnect":[]]
    static func decode(_ data: Data) throws -> Self {
        let json = try MessagesJSON.decode(data, limit: 16384)
        let value = json.value
        guard Set(value.keys) == ["schema_version","request_id","command","arguments"],
              MessagesNativeIO.integer(value["schema_version"]) == 1,
              let id = value["request_id"] as? String, UUID(uuidString:id)?.uuidString.lowercased() == id,
              let command = value["command"] as? String, let fields = fields[command],
              let arguments = value["arguments"] as? [String:String], Set(arguments.keys) == fields,
              arguments.values.allSatisfy({ $0.utf8.count <= 128 && !$0.contains("\0") }) else { throw MessagesTransportFault("invalid_request") }
        return Self(requestID:id, command:command, arguments:arguments, json:json)
    }
}
