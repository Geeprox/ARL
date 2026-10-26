import Foundation

struct ControlLogExport: Sendable {
    let content: Data
    let count: Int
    let more: Bool
    let truncated: Bool
    static func decode(_ data: Data) throws -> Self {
        let r = try WireSchema.object(JSONSerialization.jsonObject(with:data),["schema_version","redaction_version","format","content","records_count","next_cursor","more","truncated","max_bytes"])
        try WireSchema.constantInt(r["schema_version"],2); try WireSchema.constantInt(r["redaction_version"],1)
        try WireSchema.choice(r["format"],["jsonl"]); try WireSchema.constantInt(r["max_bytes"],65536)
        guard let text = r["content"] as? String else { throw ARLError(code:"invalid_response") }
        let content = Data(text.utf8)
        guard content.count <= 65536 else { throw ARLError(code:"invalid_response") }
        let count = try WireSchema.integer(r["records_count"])
        guard count <= 500, text.isEmpty || text.hasSuffix("\n") else { throw ARLError(code:"invalid_response") }
        let lines = text.isEmpty ? [] : text.dropLast().split(separator:"\n",omittingEmptySubsequences:false)
        guard lines.count == count else { throw ARLError(code:"invalid_response") }
        let records = try lines.map { try JSONSerialization.jsonObject(with:Data($0.utf8)) }
        try WireSchema.records(records,maximum:500)
        try WireSchema.nullableString(r["next_cursor"],maximum:64)
        return Self(content:content,count:count,more:try WireSchema.boolean(r["more"]),truncated:try WireSchema.boolean(r["truncated"]))
    }
    static func filtered(_ records: [RedactedLogEntry]) throws -> Self {
        guard records.count<=500 else { throw ARLError(code:"invalid_response") }
        let encoder=JSONEncoder(); encoder.outputFormatting=[.sortedKeys]
        var data=Data()
        let encoded = try records.map { try encoder.encode($0) }
        try WireSchema.records(try encoded.map { try JSONSerialization.jsonObject(with:$0) },maximum:500)
        for record in encoded { data.append(record); data.append(10) }
        guard data.count<=65536 else { throw ARLError(code:"export_limit_exceeded") }
        return Self(content:data,count:records.count,more:false,truncated:false)
    }
}
