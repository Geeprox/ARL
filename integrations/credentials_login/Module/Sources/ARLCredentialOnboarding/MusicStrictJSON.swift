import Foundation

/// Bounds JSON nesting and rejects duplicate keys before Foundation decoding.
/// Private protocol/envelope helper; never includes input in its errors.
enum MusicStrictJSON {
    static func object(_ data: Data, limit: Int, maximumDepth: Int = 16) throws -> [String: Any] {
        guard let object = try value(data, limit: limit, maximumDepth: maximumDepth) as? [String: Any] else { throw CredentialError.invalidInput }
        return object
    }
    static func value(_ data: Data, limit: Int, maximumDepth: Int = 16) throws -> Any {
        guard !data.isEmpty, data.count <= limit, String(data: data, encoding: .utf8) != nil
        else { throw CredentialError.invalidInput }
        var parser = MusicDuplicateKeyParser(bytes: Array(data), maximumDepth: maximumDepth)
        defer { parser.bytes.withUnsafeMutableBufferPointer { $0.initialize(repeating: 0) } }
        try parser.value(depth: 0)
        parser.spaces()
        guard parser.index == data.count else { throw CredentialError.invalidInput }
        return try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
    }
}

private struct MusicDuplicateKeyParser {
    var bytes: [UInt8]
    var index = 0
    let maximumDepth: Int
    mutating func spaces() { while index < bytes.count && [9,10,13,32].contains(bytes[index]) { index += 1 } }
    mutating func quoted() throws -> String {
        spaces()
        guard index < bytes.count, bytes[index] == 34 else { throw CredentialError.invalidInput }
        let start = index
        index += 1
        var escape = false
        while index < bytes.count {
            let byte = bytes[index]; index += 1
            if escape { escape = false; continue }
            if byte == 92 { escape = true; continue }
            if byte == 34, let value = try JSONSerialization.jsonObject(with: Data(bytes[start..<index]), options: .fragmentsAllowed) as? String { return value }
        }
        throw CredentialError.invalidInput
    }
    mutating func value(depth: Int) throws {
        guard depth < maximumDepth else { throw CredentialError.invalidInput }
        spaces()
        guard index < bytes.count else { throw CredentialError.invalidInput }
        if bytes[index] == 34 { _ = try quoted(); return }
        if bytes[index] == 123 {
            index += 1; spaces(); var keys = Set<String>()
            if index < bytes.count, bytes[index] == 125 { index += 1; return }
            while true {
                let key = try quoted()
                guard keys.insert(key).inserted else { throw CredentialError.invalidInput }
                spaces(); guard index < bytes.count, bytes[index] == 58 else { throw CredentialError.invalidInput }
                index += 1; try value(depth: depth + 1); spaces()
                guard index < bytes.count else { throw CredentialError.invalidInput }
                if bytes[index] == 125 { index += 1; return }
                guard bytes[index] == 44 else { throw CredentialError.invalidInput }; index += 1
            }
        }
        if bytes[index] == 91 {
            index += 1; spaces()
            if index < bytes.count, bytes[index] == 93 { index += 1; return }
            while true {
                try value(depth: depth + 1); spaces()
                guard index < bytes.count else { throw CredentialError.invalidInput }
                if bytes[index] == 93 { index += 1; return }
                guard bytes[index] == 44 else { throw CredentialError.invalidInput }; index += 1
            }
        }
        let start = index
        while index < bytes.count && ![44,93,125,9,10,13,32].contains(bytes[index]) { index += 1 }
        guard index > start else { throw CredentialError.invalidInput }
    }
}
