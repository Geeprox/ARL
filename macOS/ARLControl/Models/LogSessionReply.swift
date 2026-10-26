import Foundation

/// Consumer for the settings.logs.v3 read-only contract.
/// Cursor contents remain opaque. Session IDs are compared only for equality.
enum LogSessionReply {
    private static func session(_ value: Any?) throws -> String {
        let token = try WireSchema.string(value, maximum: 32)
        guard token.range(of: "^[a-f0-9]{32}$", options: .regularExpression) != nil else {
            throw ARLError(code: "invalid_response")
        }
        return token
    }
    static func checkpoint(_ data: Data) throws -> (sessionID: String, latestSequence: Int) {
        let raw = try WireSchema.object(JSONSerialization.jsonObject(with: data), ["schema_version", "redaction_version", "mode", "session_id", "latest_sequence"])
        try WireSchema.constantInt(raw["schema_version"], 3)
        try WireSchema.constantInt(raw["redaction_version"], 1)
        try WireSchema.choice(raw["mode"], ["checkpoint"])
        return (try session(raw["session_id"]), try WireSchema.integer(raw["latest_sequence"]))
    }
    static func page(_ data: Data) throws -> (sessionID: String, latestSequence: Int, scannedThroughSequence: Int, page: RedactedLogPage) {
        var raw = try WireSchema.object(JSONSerialization.jsonObject(with: data), ["schema_version", "redaction_version", "mode", "session_id", "latest_sequence", "scanned_through_sequence", "records", "next_cursor", "more", "truncated"])
        try WireSchema.constantInt(raw["schema_version"], 3)
        try WireSchema.constantInt(raw["redaction_version"], 1)
        try WireSchema.choice(raw["mode"], ["page"])
        let token = try session(raw["session_id"])
        let latest = try WireSchema.integer(raw["latest_sequence"])
        let scanned = try WireSchema.integer(raw["scanned_through_sequence"])
        guard scanned <= latest else { throw ARLError(code: "invalid_response") }
        // Reuse the strict existing redacted-record/page decoder after validating
        // the v3 envelope. This does not negotiate or silently accept v2 replies.
        raw.removeValue(forKey: "mode")
        raw.removeValue(forKey: "session_id")
        raw.removeValue(forKey: "latest_sequence")
        raw.removeValue(forKey: "scanned_through_sequence")
        raw["schema_version"] = 2
        let page = try ControlLogResponse.decode(JSONSerialization.data(withJSONObject: raw)).presentation
        guard page.nextCursor != nil, page.entries.allSatisfy({ $0.sequence <= scanned }),
              page.hasMore ? scanned < latest : scanned == latest else { throw ARLError(code: "invalid_response") }
        return (token, latest, scanned, page)
    }
}
