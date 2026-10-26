import Foundation
import CoreFoundation

/// Two product inputs: target and image. request_id/intent retain the existing
/// automatic caller bookkeeping; no caller SHA, old cover or playlist name.
enum MusicPlaylistCoverCapability {
    static let name = "mio_netease_playlist_update_cover"
    static var descriptor: [String: Any] {
        let text: [String: Any] = ["type":"string", "minLength":1]
        return ["name":name,
            "description":"Set the selected playlist cover from an HTTPS image URL, or use image_ref with a song_id returned by this playlist to select its coverImgUrl. The caller generates request_id and reuses it after uncertainty; repeated IDs read cached status by default. For an existing proven token failure before any upload, explicitly supply reconcile_only:false to request one recovery per reviewed bridge generation; omitted or true only queries an existing task. Unknown/pending or possibly dispatched effects never replay. No image SHA or previous cover is required. Original image composition is preserved; songs and cloud files are unchanged.",
            "inputSchema":["type":"object", "additionalProperties":false, "required":["request_id","playlist_id"],
                "properties":["request_id":["type":"string","format":"uuid","minLength":36,"maxLength":36],
                    "intent":["type":"string","enum":["update_playlist_cover"]],
                    "playlist_id":["type":"string","pattern":"^[0-9a-fA-F]{32}$","minLength":32,"maxLength":32],
                    "image_url":text, "image_ref":["type":"string","pattern":"^[0-9a-fA-F]{32}$","minLength":32,"maxLength":32],
                    "reconcile_only":["type":"boolean","default":false]],
                "oneOf":[["required":["image_url"]],["required":["image_ref"]]]],
            "annotations":["readOnlyHint":false,"destructiveHint":false,"idempotentHint":false,"openWorldHint":true]]
    }
    static func requestsRecovery(_ args: [String: Any]) -> Bool {
        guard args.keys.contains("reconcile_only"), let value = args["reconcile_only"] as? NSNumber,
              CFGetTypeID(value) == CFBooleanGetTypeID() else { return false }
        return !value.boolValue
    }
    static func validate(_ args: [String: Any]) throws -> String {
        let required: Set<String> = ["request_id","playlist_id"]
        guard required.isSubset(of: Set(args.keys)),
              Set(args.keys).isSubset(of: required.union(["intent","image_url","image_ref","reconcile_only"])),
              let id = args["request_id"] as? String, id.utf8.count == 36, UUID(uuidString:id) != nil,
              args["intent"] == nil || args["intent"] as? String == "update_playlist_cover",
              let playlist = args["playlist_id"] as? String,
              playlist.range(of:"^[0-9a-fA-F]{32}$",options:.regularExpression) != nil,
              (args["image_url"] == nil) != (args["image_ref"] == nil) else { throw OwnerReadFault.invalid }
        if let value = args["reconcile_only"] {
            guard let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { throw OwnerReadFault.invalid }
        }
        if let value = args["image_ref"] {
            guard let s = value as? String, s.range(of:"^[0-9a-fA-F]{32}$",options:.regularExpression) != nil else { throw OwnerReadFault.invalid }
        }
        if let value = args["image_url"] {
            guard let s = value as? String, !s.isEmpty, let u = URLComponents(string:s),
                  u.user == nil, u.password == nil, u.host?.isEmpty == false,
                  u.scheme == "https" || u.scheme == "http" && ["p1.music.126.net","p2.music.126.net"].contains(u.host ?? "") else { throw OwnerReadFault.invalid }
        }
        return id
    }
}
