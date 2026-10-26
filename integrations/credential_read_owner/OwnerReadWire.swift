import Foundation
import CoreFoundation

// This is a tool result boundary. There is no CredentialInput, reference, URL,
// executable, argument-vector, credential mutation, login, or export operation.
enum OwnerReadFault: String, Error, Sendable {
    case held = "owner_route_held"
    case identity = "owner_identity_unverified"
    case invalid = "invalid_arguments"
    case unsupported = "unsupported_read_tool"
    case unavailable = "owner_unavailable"
    case deadline = "owner_deadline"
    case cancelled = "cancelled"
    case busy = "owner_busy"
    case cleanupUnproven = "cleanup_unproven"
    case unconfigured = "configuration_required"
    case provider = "provider_read_unavailable"
    case limit = "owner_response_limit"
    case businessLogUnavailable = "business_log_unavailable"
}

/// Only the cart caller requests this distinction. Other owner tools keep their
/// existing error contract. A validated owner rejection differs from lost data.
struct OwnerReadExplicitRejection: Error { let fault: OwnerReadFault }

enum OwnerReadWire {
    static let schema = 2
    // Match the existing 64 KiB MCP request-line budget; 500 encrypted IDs alone need 17,501 bytes.
    static let requestLimit = 65_536
    // The response frame carries its length as an unsigned 32-bit integer.
    static let responseLimit = Int(UInt32.max)
    static let seconds: Double = 20
    static let travel: Set<String> = [
        "mio_maps_geo", "mio_maps_regeocode", "mio_maps_text_search", "mio_maps_around_search",
        "mio_maps_search_detail", "mio_maps_direction_driving", "mio_maps_direction_walking",
        "mio_maps_bicycling", "mio_maps_direction_transit_integrated", "mio_maps_distance",
        "mio_maps_weather", "mio_flyai_search_flight", "mio_flyai_search_hotel",
        "mio_flyai_keyword_search", "mio_flyai_ai_search", "mio_flyai_search_train", "mio_flyai_search_poi"
    ]
    static let musicMetadataWrites: Set<String> = ["mio_netease_playlist_update_name", "mio_netease_playlist_update_desc"]
    static let musicWrites: Set<String> = Set(["mio_netease_playlist_create", "mio_netease_playlist_append_song"]).union(musicMetadataWrites).union(musicBatchWrites)
    static let musicBatchWrites: Set<String> = ["mio_netease_playlist_update_tags", "mio_netease_playlist_add_songs", "mio_netease_playlist_reorder", "mio_netease_playlist_remove_songs"]
    static func batchIntent(_ tool: String, _ args: [String: Any]) throws -> (id: UUID, name: String, playlist: String, intent: String, items: [String]) {
        let tags = tool == "mio_netease_playlist_update_tags", field = tags ? "tags" : "song_ids"
        let intents = ["mio_netease_playlist_update_tags":"update_playlist_tags", "mio_netease_playlist_add_songs":"add_songs", "mio_netease_playlist_reorder":"reorder_songs", "mio_netease_playlist_remove_songs":"remove_songs"]
        let required: Set<String> = ["request_id", "intent", "playlist_id", "playlist_name", field]
        guard let intent = intents[tool], required.isSubset(of: Set(args.keys)), Set(args.keys).isSubset(of: required.union(["reconcile_only"])),
              let rawID = args["request_id"] as? String, rawID.utf8.count == 36, let id = UUID(uuidString: rawID), args["intent"] as? String == intent,
              let playlist = args["playlist_id"] as? String, playlist.range(of:"^[a-fA-F0-9]{32}$",options:.regularExpression) != nil,
              let name = args["playlist_name"] as? String, !name.isEmpty, name.count <= 100, name.utf8.count <= 400,
              name == name.trimmingCharacters(in:.whitespacesAndNewlines), !name.hasPrefix("-"), !name.unicodeScalars.contains(where:{$0.value < 32 || $0.value == 127}),
              let items = args[field] as? [String], !items.isEmpty else { throw OwnerReadFault.invalid }
        if let flag = args["reconcile_only"] { guard let n = flag as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { throw OwnerReadFault.invalid } }
        if tags {
            guard items.count <= 3, Set(items).count == items.count, items.allSatisfy({!$0.isEmpty && !$0.unicodeScalars.contains(where:{$0.value < 32 || $0.value == 127})}) else { throw OwnerReadFault.invalid }
        } else {
            guard items.allSatisfy({$0.range(of:"^[a-fA-F0-9]{32}$",options:.regularExpression) != nil}), Set(items.map{$0.lowercased()}).count == items.count,
                  intent != "remove_songs" || items.count <= 500 else { throw OwnerReadFault.invalid }
        }
        return (id,name,playlist,intent,items)
    }
    static var musicBatchDescriptors: [[String: Any]] {
        [("mio_netease_playlist_update_tags","update_playlist_tags"), ("mio_netease_playlist_add_songs","add_songs"), ("mio_netease_playlist_reorder","reorder_songs"), ("mio_netease_playlist_remove_songs","remove_songs")].map { tool,intent in
            let tags = intent == "update_playlist_tags", field = tags ? "tags" : "song_ids"
            var array: [String: Any] = ["type":"array", "minItems":1, "uniqueItems":true, "items":tags ? ["type":"string","minLength":1] : ["type":"string","pattern":"^[a-fA-F0-9]{32}$","minLength":32,"maxLength":32]]
            if tags { array["maxItems"] = 3 }; if intent == "remove_songs" { array["maxItems"] = 500 }
            let detail = tags ? "Set 1–3 official tag names from playlist_get_tags; verify tags and unchanged ordered songs." : intent == "add_songs" ? "Add this complete batch in one official request. Provider placement of new songs is unspecified; verify all requested IDs and preservation of existing order." : intent == "reorder_songs" ? "Provide ALL current playlist song IDs in the desired order; membership must match the complete read. Verify the exact full order." : "Remove only the selected songs from this playlist (maximum500 per official contract). Does not delete the playlist or cloud files. Verify every removal and the remaining order."
            return ["name":tool,"description":detail+" Bind current playlist_name and encrypted playlist_id from playlist_describe. Preserve request_id across uncertainty; reconcile_only only reads its existing record. No automatic replay or chunking. Requests are bounded by the existing 64 KiB MCP line transport; no unspecified provider size guarantee. External edits can race; no atomic revision API.",
                "inputSchema":["type":"object","additionalProperties":false,"required":["request_id","intent","playlist_id","playlist_name",field],"properties":["request_id":["type":"string","format":"uuid","minLength":36,"maxLength":36],"intent":["type":"string","const":intent],"playlist_id":["type":"string","pattern":"^[a-fA-F0-9]{32}$","minLength":32,"maxLength":32],"playlist_name":["type":"string","minLength":1,"maxLength":100],field:array,"reconcile_only":["type":"boolean"]]],
                "annotations":["readOnlyHint":false,"destructiveHint":intent == "remove_songs","idempotentHint":true,"openWorldHint":true]]
        }
    }
    static func metadataIntent(_ tool: String, _ args: [String: Any]) throws -> (id: UUID, name: String, playlist: String, value: String, rename: Bool) {
        let rename = tool == "mio_netease_playlist_update_name", field = rename ? "new_name" : "description"
        let required: Set<String> = ["request_id", "intent", "playlist_name", "playlist_id", field]
        guard musicMetadataWrites.contains(tool), required.isSubset(of: Set(args.keys)), Set(args.keys).isSubset(of: required.union(["reconcile_only"])),
            let rawID = args["request_id"] as? String, rawID.utf8.count == 36, let id = UUID(uuidString: rawID),
            args["intent"] as? String == (rename ? "update_playlist_name" : "update_playlist_description"),
            let playlist = args["playlist_id"] as? String, playlist.range(of: "^[a-fA-F0-9]{32}$", options: .regularExpression) != nil,
            let name = args["playlist_name"] as? String, !name.isEmpty, name.count <= 100, name.utf8.count <= 400,
            name == name.trimmingCharacters(in: .whitespacesAndNewlines), !name.hasPrefix("-"),
            !name.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }), let value = args[field] as? String
        else { throw OwnerReadFault.invalid }
        if let flag = args["reconcile_only"] { guard let n = flag as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { throw OwnerReadFault.invalid } }
        if rename {
            guard !value.isEmpty, value.unicodeScalars.count <= 100, value.utf8.count <= 400,
                value == value.trimmingCharacters(in: .whitespacesAndNewlines), !value.hasPrefix("-"),
                !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw OwnerReadFault.invalid }
        } else {
            guard value.unicodeScalars.count <= 1000, value.utf8.count <= 4000,
                !value.unicodeScalars.contains(where: { ($0.value < 32 && $0.value != 9 && $0.value != 10) || $0.value == 127 }) else { throw OwnerReadFault.invalid }
        }
        return (id, name, playlist, value, rename)
    }
    static var musicMetadataDescriptors: [[String: Any]] {
        [true, false].map { rename in
            let field = rename ? "new_name" : "description"
            return ["name": rename ? "mio_netease_playlist_update_name" : "mio_netease_playlist_update_desc",
                "description": "Explicit metadata-only playlist update through the official API. Bind the current playlist name and encrypted ID from playlist_describe. Preserve request_id across uncertainty; reconcile_only only inspects an existing request. Exact metadata and complete ordered songs are read back before verified. No song, order or cover change. Empty description clears it. External edits can race; the API has no atomic revision check.",
                "inputSchema": ["type": "object", "additionalProperties": false,
                    "required": ["request_id", "intent", "playlist_id", "playlist_name", field],
                    "properties": ["request_id": ["type": "string", "format": "uuid", "minLength": 36, "maxLength": 36],
                        "intent": ["type": "string", "const": rename ? "update_playlist_name" : "update_playlist_description"],
                        "playlist_id": ["type": "string", "pattern": "^[a-fA-F0-9]{32}$", "minLength": 32, "maxLength": 32],
                        "playlist_name": ["type": "string", "minLength": 1, "maxLength": 100],
                        field: ["type": "string", "minLength": rename ? 1 : 0, "maxLength": rename ? 100 : 1000],
                        "reconcile_only": ["type": "boolean"]]],
                "annotations": ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": true, "openWorldHint": true]]
        }
    }
    static let musicReconcile = "mio_netease_playlist_reconcile"
    static var musicReconcileDescriptor: [String: Any] {
        ["name": musicReconcile,
         "description": "只读核实已经存在的网易云歌单写入请求。仅接受原 request_id，原目标从持久记录读取；记录缺失不创建、不发送效果，不允许重放。not_dispatched 只表示该记录已保存明确未发出证据；历史未知记录不会据空列表改写。",
         "inputSchema": ["type": "object", "additionalProperties": false, "required": ["request_id"],
            "properties": ["request_id": ["type": "string", "format": "uuid", "minLength": 36, "maxLength": 36]]],
         "annotations": ["readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": true]]
    }
    static let musicAppendRecovery = "mio_netease_playlist_recover_append_once"
    static var musicAppendRecoveryDescriptor: [String: Any] {
        ["name": musicAppendRecovery,
         "description": "仅在用户明确要求恢复一次、已核对当前账号和原目标后调用。只接受现有 append 请求的原 request_id；ARL 从原记录取歌单和歌曲，完整回读并核对归属后最多保留一次新增恢复尝试。官方批量添加已处理重复歌曲；旧未知历史不会清除。记录缺失或原请求是创建歌单时不写；本工具重复调用或重启后只查证已保留的恢复尝试，不得自动调用或换 UUID。",
         "inputSchema": ["type": "object", "additionalProperties": false, "required": ["request_id"],
            "properties": ["request_id": ["type": "string", "format": "uuid", "minLength": 36, "maxLength": 36]]],
         "annotations": ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": true, "openWorldHint": true]]
    }
    static let musicCurrentCloudAppend = "mio_netease_playlist_append_current_cloud_song"
    static var musicCurrentCloudAppendDescriptor: [String: Any] {
        let uuid: [String: Any] = ["type":"string", "format":"uuid", "minLength":36, "maxLength":36]
        return ["name":musicCurrentCloudAppend,
            "description":"Append the explicitly selected current version of the SAME private-cloud file to the original playlist. Use supersedes_request_id of the existing legacy append and selection_id from that cloud search record. ARL rechecks stable pcId/title/artists/album, resolves current IDs, and atomically links one current-resource operation; old request/recovery are unchanged. No caller replacement UUID. Repeated calls only reconcile the reserved successor, even after unknown results. Do not use this to retry the old resource or guess a same-name recording.",
            "inputSchema":["type":"object", "additionalProperties":false, "required":["intent","supersedes_request_id","pc_id","selection_id"],
                "properties":["intent":["type":"string","enum":["append_current_cloud_song"]],"supersedes_request_id":uuid,"pc_id":["type":"string","pattern":"^[1-9][0-9]{0,19}$"],"selection_id":uuid]],
            "annotations":["readOnlyHint":false,"destructiveHint":false,"idempotentHint":true,"openWorldHint":true]]
    }
    static func currentCloudIntent(_ args: [String: Any]) throws -> (supersedes: String, pcID: String, selection: String) {
        guard Set(args.keys) == ["intent","supersedes_request_id","pc_id","selection_id"],
              args["intent"] as? String == "append_current_cloud_song",
              let parent = args["supersedes_request_id"] as? String, parent.utf8.count == 36, UUID(uuidString: parent) != nil,
              let pc = args["pc_id"] as? String, pc.range(of:"^[1-9][0-9]{0,19}$",options:.regularExpression) != nil,
              let selection = args["selection_id"] as? String, selection.utf8.count == 36, UUID(uuidString: selection) != nil else { throw OwnerReadFault.invalid }
        return (parent, pc, selection)
    }
    // Additive aggregate entry: legacy song_search keeps its public offset contract.
    static let musicAggregate = "mio_netease_song_search_unified"
    static var musicAggregateDescriptor: [String: Any] {
        let text: [String: Any] = ["type": "string", "minLength": 1, "maxLength": 100]
        var unsupported = text
        unsupported["description"] = "兼容旧参数；当前供应方搜索不支持独立此项过滤，ARL 不过滤、不排序，也不拼入 keyword。请在 keyword 明确写出完整搜索词。"
        return ["name": musicAggregate,
            "description": "按原始 keyword 搜索公共曲库，并检索当前账号云盘缓存。公共候选保留供应方顺序与业务字段；artist/album/recording_version 兼容但不生效，见 search.unsupported_parameters。field 只选择云盘本地检索字段；云盘按全部空白分词的确定性文本命中返回。来源记录独立，不证明同一录音。云盘索引保留现有12小时刷新/退避；stale/partial 说明覆盖限制。仅用 next_cursor 原样续读同一查询；完整条目分页，不写歌单。",
            "inputSchema": ["type": "object", "additionalProperties": false, "required": ["keyword"],
                "properties": ["keyword": text, "field": ["type": "string", "enum": ["any", "title", "artist", "album"], "default": "any", "description": "仅选择云盘本地检索字段，不作为公共搜索过滤条件。"],
                    "artist": unsupported, "album": unsupported, "recording_version": unsupported,
                    "cursor": ["type": "string", "format": "uuid", "minLength": 36, "maxLength": 36,
                        "description": "仅使用本入口返回的search.next_cursor；原样保留keyword/field/artist/album/recording_version，不改重音、大小写或全角；有效期最多300秒。"]]],
            "annotations": ["readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": true]]
    }
    static let musicLibraryNames: Set<String> = ["mio_netease_search_all", "mio_netease_search_album", "mio_netease_search_playlist", "mio_netease_album_get", "mio_netease_album_tracks", "mio_netease_album_collected", "mio_netease_artist_songs", "mio_netease_song_lyric", "mio_netease_playlist_collected", "mio_netease_playlist_get_tags"]
    static let musicLibraryJSON = #"""
[{"annotations":{"destructiveHint":false,"idempotentHint":true,"openWorldHint":true,"readOnlyHint":true},"description":"Read-only official NetEase search.all. Uses the existing account in ARL. Returns complete safe provider business JSON for this response, actual forwarded parameters and single_provider_response coverage; complete=false does not claim all inventory. No order, playback, write or extra endpoint. Encrypted 32-hex IDs must come from provider results; no guessed IDs.","inputSchema":{"additionalProperties":false,"properties":{"keyword":{"maxLength":100,"minLength":1,"type":"string"}},"required":["keyword"],"type":"object"},"name":"mio_netease_search_all"},{"annotations":{"destructiveHint":false,"idempotentHint":true,"openWorldHint":true,"readOnlyHint":true},"description":"Read-only official NetEase search.album. Uses the existing account in ARL. Returns complete safe provider business JSON for this response, actual forwarded parameters and single_provider_response coverage; complete=false does not claim all inventory. No order, playback, write or extra endpoint. Encrypted 32-hex IDs must come from provider results; no guessed IDs.","inputSchema":{"additionalProperties":false,"properties":{"keyword":{"maxLength":100,"minLength":1,"type":"string"},"limit":{"maximum":100,"minimum":1,"type":"integer"},"offset":{"maximum":9007199254740991,"minimum":0,"type":"integer"}},"required":["keyword"],"type":"object"},"name":"mio_netease_search_album"},{"annotations":{"destructiveHint":false,"idempotentHint":true,"openWorldHint":true,"readOnlyHint":true},"description":"Read-only official NetEase search.playlist. Uses the existing account in ARL. Returns complete safe provider business JSON for this response, actual forwarded parameters and single_provider_response coverage; complete=false does not claim all inventory. No order, playback, write or extra endpoint. Encrypted 32-hex IDs must come from provider results; no guessed IDs.","inputSchema":{"additionalProperties":false,"properties":{"keyword":{"maxLength":100,"minLength":1,"type":"string"},"limit":{"maximum":100,"minimum":1,"type":"integer"},"offset":{"maximum":9007199254740991,"minimum":0,"type":"integer"}},"required":["keyword"],"type":"object"},"name":"mio_netease_search_playlist"},{"annotations":{"destructiveHint":false,"idempotentHint":true,"openWorldHint":true,"readOnlyHint":true},"description":"Read-only official NetEase album.get. Uses the existing account in ARL. Returns complete safe provider business JSON for this response, actual forwarded parameters and single_provider_response coverage; complete=false does not claim all inventory. No order, playback, write or extra endpoint. Encrypted 32-hex IDs must come from provider results; no guessed IDs.","inputSchema":{"additionalProperties":false,"properties":{"album_id":{"maxLength":32,"minLength":32,"pattern":"^[0-9a-fA-F]{32}$","type":"string"},"desc_flag":{"type":"boolean"}},"required":["album_id"],"type":"object"},"name":"mio_netease_album_get"},{"annotations":{"destructiveHint":false,"idempotentHint":true,"openWorldHint":true,"readOnlyHint":true},"description":"Read-only official NetEase album.tracks. Uses the existing account in ARL. Returns complete safe provider business JSON for this response, actual forwarded parameters and single_provider_response coverage; complete=false does not claim all inventory. No order, playback, write or extra endpoint. Encrypted 32-hex IDs must come from provider results; no guessed IDs.","inputSchema":{"additionalProperties":false,"properties":{"album_id":{"maxLength":32,"minLength":32,"pattern":"^[0-9a-fA-F]{32}$","type":"string"},"quality_flag":{"type":"boolean"}},"required":["album_id"],"type":"object"},"name":"mio_netease_album_tracks"},{"annotations":{"destructiveHint":false,"idempotentHint":true,"openWorldHint":true,"readOnlyHint":true},"description":"Read-only official NetEase album.collected. Uses the existing account in ARL. Returns complete safe provider business JSON for this response, actual forwarded parameters and single_provider_response coverage; complete=false does not claim all inventory. No order, playback, write or extra endpoint. Encrypted 32-hex IDs must come from provider results; no guessed IDs.","inputSchema":{"additionalProperties":false,"properties":{"limit":{"maximum":100,"minimum":1,"type":"integer"},"offset":{"maximum":9007199254740991,"minimum":0,"type":"integer"}},"required":["limit","offset"],"type":"object"},"name":"mio_netease_album_collected"},{"annotations":{"destructiveHint":false,"idempotentHint":true,"openWorldHint":true,"readOnlyHint":true},"description":"Read-only official NetEase artist.songs. Uses the existing account in ARL. Returns complete safe provider business JSON for this response, actual forwarded parameters and single_provider_response coverage; complete=false does not claim all inventory. No order, playback, write or extra endpoint. Encrypted 32-hex IDs must come from provider results; no guessed IDs.","inputSchema":{"additionalProperties":false,"properties":{"artist_id":{"maxLength":32,"minLength":32,"pattern":"^[0-9a-fA-F]{32}$","type":"string"},"end_time":{"maximum":9007199254740991,"minimum":0,"type":"integer"},"limit":{"maximum":100,"minimum":1,"type":"integer"},"offset":{"maximum":9007199254740991,"minimum":0,"type":"integer"},"start_time":{"maximum":9007199254740991,"minimum":0,"type":"integer"}},"required":["artist_id","limit","offset","start_time","end_time"],"type":"object"},"name":"mio_netease_artist_songs"},{"annotations":{"destructiveHint":false,"idempotentHint":true,"openWorldHint":true,"readOnlyHint":true},"description":"Read-only official NetEase song.lyric. Uses the existing account in ARL. Returns complete safe provider business JSON for this response, actual forwarded parameters and single_provider_response coverage; complete=false does not claim all inventory. No order, playback, write or extra endpoint. Encrypted 32-hex IDs must come from provider results; no guessed IDs.","inputSchema":{"additionalProperties":false,"properties":{"song_id":{"maxLength":32,"minLength":32,"pattern":"^[0-9a-fA-F]{32}$","type":"string"}},"required":["song_id"],"type":"object"},"name":"mio_netease_song_lyric"},{"name":"mio_netease_playlist_collected","description":"List playlists collected by the current account; distinct from the created-playlist list. Read-only official NetEase playlist query through the existing ARL account. Preserves safe provider business JSON and actual forwarded parameters. Coverage is this response/page only; no total-inventory completeness claim. No write, collection change or added filter.","inputSchema":{"type":"object","additionalProperties":false,"required":[],"properties":{"limit":{"type":"integer","minimum":1,"maximum":500,"description":"Optional page size; provider default20, maximum500."},"offset":{"type":"integer","minimum":0,"maximum":9007199254740991,"description":"Optional page offset; provider default0. One page does not prove full collection coverage."}}},"annotations":{"readOnlyHint":true,"destructiveHint":false,"idempotentHint":true,"openWorldHint":true}},{"name":"mio_netease_playlist_get_tags","description":"Read the official selectable playlist tag taxonomy. Takes no business parameters. Read-only official NetEase playlist query through the existing ARL account. Preserves safe provider business JSON and actual forwarded parameters. Coverage is this response/page only; no total-inventory completeness claim. No write, collection change or added filter.","inputSchema":{"type":"object","additionalProperties":false,"required":[],"properties":{}},"annotations":{"readOnlyHint":true,"destructiveHint":false,"idempotentHint":true,"openWorldHint":true}}]
"""#
    static var musicLibraryDescriptors:[[String:Any]] {(try? JSONSerialization.jsonObject(with:Data(musicLibraryJSON.utf8)) as? [[String:Any]]) ?? []}
    static let musicStatus = "mio_netease_connection_status"
    static func seconds(for tool: String) -> Double {
        if music.contains(tool) || musicLibraryNames.contains(tool) || tool == musicAggregate { return 35 }
        if NASCapability.names.contains(tool) { return 110 }
        if tool == "mio_flyai_ai_search" { return 75 }
        if tool == AppleCapability.reminderCreate || AppleProductCapability.names.contains(tool) { return 210 }
        return (tool == MusicPlaylistCoverCapability.name || musicWrites.contains(tool) || tool == musicReconcile || tool == musicAppendRecovery || tool == musicCurrentCloudAppend) ? 180 : seconds }
    static let music: Set<String> = ["mio_netease_playlist_list", "mio_netease_playlist_describe", "mio_netease_song_search"]
    static func isReadTool(_ value: String) -> Bool { NASCapability.names.contains(value) || travel.contains(value) || musicLibraryNames.contains(value) || music.contains(value) || value == musicReconcile || value == musicAggregate }
    static func isTool(_ value: String) -> Bool {
        AppleProductCapability.names.contains(value) || AppleCapability.names.contains(value) || isReadTool(value) || musicWrites.contains(value) || value == musicAppendRecovery || value == musicCurrentCloudAppend || value == musicStatus || value == MusicPlaylistCoverCapability.name
    }
    static func integer(_ value: Any?, _ expected: Int) -> Bool {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return false }
        return n.doubleValue == Double(expected)
    }
    static func falseBoolean(_ value: Any?) -> Bool {
        guard let value=value as? NSNumber, CFGetTypeID(value)==CFBooleanGetTypeID() else { return false }
        return !value.boolValue
    }
    static func trueBoolean(_ value: Any?) -> Bool {
        guard let value = value as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { return false }
        return value.boolValue
    }
    static func uuid(_ value: Any?) -> String? {
        guard let text = value as? String, text.utf8.count == 36,
              let id = UUID(uuidString: text), id.uuidString == text else { return nil }
        return text
    }
    static func encode(_ value: [String: Any], limit: Int) throws -> Data {
        let bytes = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
        guard bytes.count <= limit else { throw OwnerReadFault.limit }
        return bytes
    }
    static func request(_ data: Data, generation: String) throws -> OwnerReadRequest {
        let object = try OwnerReadJSON.object(data, limit: requestLimit)
        guard Set(object.keys) == ["schema", "generation", "callID", "tool", "arguments"],
              integer(object["schema"], schema), object["generation"] as? String == generation,
              let callID = uuid(object["callID"]), let tool = object["tool"] as? String,
              isTool(tool), let arguments = object["arguments"] as? [String: Any]
        else { throw OwnerReadFault.invalid }
        return .init(generation: generation, callID: callID, tool: tool,
                     argumentsJSON: try encode(arguments, limit: requestLimit))
    }
    static func hello(_ generation: String) throws -> Data {
        try encode(["schema": schema, "generation": generation, "event": "ready"], limit: 1024)
    }
    static func response(_ request: OwnerReadRequest, payload: Data?, error: OwnerReadFault?) throws -> Data {
        var object: [String: Any] = ["schema": schema, "generation": request.generation,
                                    "callID": request.callID, "tool": request.tool]
        if let error { object["error"] = error.rawValue }
        else if let payload { object["payload"] = try OwnerReadJSON.object(payload, limit: responseLimit, maximumDepth: 32) }
        else { throw OwnerReadFault.invalid }
        return try encode(object, limit: responseLimit)
    }
    static func payload(_ data: Data, request: OwnerReadRequest, distinguishRejection: Bool = false) throws -> Data {
        let object = try OwnerReadJSON.object(data, limit: responseLimit, maximumDepth: 32)
        let base: Set<String> = ["schema", "generation", "callID", "tool"]
        guard integer(object["schema"], schema), object["generation"] as? String == request.generation,
              object["callID"] as? String == request.callID, object["tool"] as? String == request.tool
        else { throw OwnerReadFault.identity }
        if Set(object.keys) == base.union(["error"]), let code = object["error"] as? String,
           let fault = OwnerReadFault(rawValue: code) {
            if distinguishRejection { throw OwnerReadExplicitRejection(fault: fault) }
            throw fault
        }
        guard Set(object.keys) == base.union(["payload"]), let payload = object["payload"] as? [String: Any]
        else { throw OwnerReadFault.invalid }
        return try encode(payload, limit: responseLimit)
    }
}

struct OwnerReadRequest: Sendable {
    let generation: String
    let callID: String
    let tool: String
    let argumentsJSON: Data
    func encoded() throws -> Data {
        try OwnerReadWire.encode(["schema": OwnerReadWire.schema, "generation": generation,
                                  "callID": callID, "tool": tool,
                                  "arguments": OwnerReadJSON.object(argumentsJSON, limit: OwnerReadWire.requestLimit)],
                                 limit: OwnerReadWire.requestLimit)
    }
}

/// Reject ambiguous keys (including escaped aliases), non-UTF8, deep values,
/// trailing tokens and oversized bytes before Foundation creates objects.
enum OwnerReadJSON {
    static func object(_ data: Data, limit: Int, maximumDepth: Int = 16) throws -> [String: Any] {
        guard (1...32).contains(maximumDepth), !data.isEmpty, data.count <= limit, String(data: data, encoding: .utf8) != nil
        else { throw OwnerReadFault.invalid }
        var parser = OwnerReadDuplicateParser(bytes: Array(data), maximumDepth: maximumDepth)
        try parser.value(depth: 0); parser.spaces()
        guard parser.index == data.count,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw OwnerReadFault.invalid }
        return object
    }
}
private struct OwnerReadDuplicateParser {
    var bytes: [UInt8]
    var index = 0
    let maximumDepth: Int
    mutating func spaces() { while index < bytes.count && [9,10,13,32].contains(bytes[index]) { index += 1 } }
    mutating func quoted() throws -> String {
        spaces()
        guard index < bytes.count, bytes[index] == 34 else { throw OwnerReadFault.invalid }
        let start = index; index += 1; var escaped = false
        while index < bytes.count {
            let byte = bytes[index]; index += 1
            if escaped { escaped = false; continue }
            if byte == 92 { escaped = true; continue }
            if byte == 34, let value = try JSONSerialization.jsonObject(with: Data(bytes[start..<index]), options: .fragmentsAllowed) as? String { return value }
        }
        throw OwnerReadFault.invalid
    }
    mutating func value(depth: Int) throws {
        guard depth < maximumDepth else { throw OwnerReadFault.invalid }; spaces()
        guard index < bytes.count else { throw OwnerReadFault.invalid }
        if bytes[index] == 34 { _ = try quoted(); return }
        if bytes[index] == 123 {
            index += 1; spaces(); var keys = Set<String>()
            if index < bytes.count, bytes[index] == 125 { index += 1; return }
            while true {
                let key = try quoted(); guard keys.insert(key).inserted else { throw OwnerReadFault.invalid }
                spaces(); guard index < bytes.count, bytes[index] == 58 else { throw OwnerReadFault.invalid }
                index += 1; try value(depth: depth + 1); spaces()
                guard index < bytes.count else { throw OwnerReadFault.invalid }
                if bytes[index] == 125 { index += 1; return }
                guard bytes[index] == 44 else { throw OwnerReadFault.invalid }; index += 1
            }
        }
        if bytes[index] == 91 {
            index += 1; spaces()
            if index < bytes.count, bytes[index] == 93 { index += 1; return }
            while true {
                try value(depth: depth + 1); spaces()
                guard index < bytes.count else { throw OwnerReadFault.invalid }
                if bytes[index] == 93 { index += 1; return }
                guard bytes[index] == 44 else { throw OwnerReadFault.invalid }; index += 1
            }
        }
        let start = index
        while index < bytes.count && ![44,93,125,9,10,13,32].contains(bytes[index]) { index += 1 }
        guard index > start else { throw OwnerReadFault.invalid }
    }
}
