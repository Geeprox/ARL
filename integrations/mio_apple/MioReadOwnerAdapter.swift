import Foundation
import CoreFoundation

/// Native replacement for Host.legacy's per-call Python/runpy process. Fixed travel reads and six music tools enter the owner socket.
/// Catalog and connectivity ping never read credentials.
enum MioReadOwnerAdapter {
    static func respond(_ request: [String: Any], cancelled: () -> Bool = { false },
                        ownerCall: ((String, Data) throws -> Data)? = nil,
                        attachmentCall: (Data) throws -> Data = { _ in throw MioAttachmentInspection.Failure(code: "attachment_inspection_unavailable") }) throws -> [String: Any] {
        func callOwner(_ name: String, _ arguments: Data) throws -> Data {
            if let ownerCall { return try ownerCall(name, arguments) }
            return try OwnerReadClient().call(tool: name, argumentsJSON: arguments, logCorrelation: ARLConnectionLog.fingerprint(request["id"]), cancelled: cancelled)
        }
        guard Set(request.keys).isSubset(of: ["jsonrpc", "id", "method", "params"]),
              request["jsonrpc"] as? String == "2.0", let method = request["method"] as? String,
              let id = request["id"], validID(id)
        else { return protocolError(id: NSNull(), code: -32600, message: "Invalid request.") }
        var params: [String: Any]
        if let value = request["params"] {
            guard let object = value as? [String: Any]
            else { return invalidParams(id) }; params = object
        } else { params = [:] }
        // MCP Request.params reserves an optional metadata object. It has no
        // authority and is never forwarded into tool arguments or owner IPC.
        // The caller already applied OwnerReadJSON's byte/depth/key limits.
        if let metadata = params.removeValue(forKey: "_meta") {
            guard metadata is [String: Any] else { return invalidParams(id) }
        }
        var result: [String: Any]
        switch method {
        case "initialize":
            guard Set(params.keys).isSubset(of: ["protocolVersion", "capabilities", "clientInfo"]) else { return invalidParams(id) }
            let requested = params["protocolVersion"] as? String ?? "2024-11-05"
            let version = ["2024-11-05", "2025-03-26", "2025-06-18"].contains(requested) ? requested : "2024-11-05"
            result = ["protocolVersion": version, "capabilities": ["tools": ["listChanged": true]],
                      "serverInfo": ["name": "arl-native-owner-read", "version": "1"]]
        case "ping":
            guard params.isEmpty else { return invalidParams(id) }; result = [:]
        case "tools/list":
            guard params.isEmpty else { return invalidParams(id) }
            var registry = try CapabilityRegistry(legacy: MioReadCatalog.descriptors())
            for descriptor in OwnerReadWire.musicLibraryDescriptors { try registry.append(descriptor) }
            for descriptor in OwnerReadWire.musicBatchDescriptors { try registry.append(descriptor) }
            for descriptor in OwnerReadWire.musicMetadataDescriptors { try registry.append(descriptor) }
            for descriptor in MioReadCatalog.flyAIAdditionDescriptors { try registry.append(descriptor) }
            try registry.append(MioReadCatalog.playlistCoverDescriptor)
            try registry.append(OwnerReadWire.musicAppendRecoveryDescriptor)
            try registry.append(OwnerReadWire.musicCurrentCloudAppendDescriptor)
            try registry.append(OwnerReadWire.musicReconcileDescriptor)
            try registry.append(OwnerReadWire.musicAggregateDescriptor)
            for descriptor in AppleCapability.descriptors { try registry.append(descriptor) }
            for descriptor in AppleProductCapability.descriptors {try registry.append(descriptor)}
            for descriptor in NASCapability.descriptors { try registry.append(descriptor) }
            try registry.append(MioAttachmentInspection.descriptor)
            result = ["tools": registry.tools]
        case "tools/call":
            guard Set(params.keys).isSubset(of: ["name", "arguments"]), let name = params["name"] as? String,
                  let arguments = (params["arguments"] ?? [:]) as? [String: Any]
            else { return invalidParams(id) }
            if name == MioAttachmentInspection.name {
                return try MioAttachmentInspection.respond(id: id, arguments: arguments, cancelled: cancelled, execute: attachmentCall)
            }
            if AppleProductCapability.names.contains(name) {
                return try respondAppleProduct(name:name,arguments:arguments,id:id,callOwner:callOwner)
            }
            if NASCapability.names.contains(name) {
                return try respondNAS(name:name,arguments:arguments,id:id,callOwner:callOwner)
            }
            var appleTaskID: String?
            var musicRequestID: String?
            var cloudSupersedesID: String?
            var ownerReplyReceived = false
            var ownerCallStarted = false
            do {
                if name == "mio_tunnel_ping" {
                    guard arguments.isEmpty else { throw OwnerReadFault.invalid }
                    result = ["content": [["type": "text", "text": "pong from mac-mini"]], "isError": false]
                } else {
                    guard OwnerReadWire.isTool(name) else { throw OwnerReadFault.unsupported }
                    if AppleCapability.names.contains(name) {
                        appleTaskID = try AppleCapability.request(tool:name, argumentsJSON:OwnerReadWire.encode(arguments,limit:OwnerReadWire.requestLimit)).taskID
                    }
                    if name == OwnerReadWire.musicReconcile || name == OwnerReadWire.musicAppendRecovery {
                        guard Set(arguments.keys) == ["request_id"], let text = arguments["request_id"] as? String,
                              text.utf8.count == 36, UUID(uuidString: text) != nil else { throw OwnerReadFault.invalid }
                        if name == OwnerReadWire.musicAppendRecovery { musicRequestID = text }
                    }
                    if name == OwnerReadWire.musicCurrentCloudAppend { cloudSupersedesID = try OwnerReadWire.currentCloudIntent(arguments).supersedes }
                    if name == MusicPlaylistCoverCapability.name { musicRequestID = try MusicPlaylistCoverCapability.validate(arguments) }
                    if OwnerReadWire.musicWrites.contains(name) { musicRequestID = try musicIntentID(name, arguments) }
                    let encoded = try OwnerReadWire.encode(arguments, limit: OwnerReadWire.requestLimit)
                    ownerCallStarted = true
                    let bytes = try callOwner(name, encoded)
                    ownerReplyReceived = true
                    var value = try OwnerReadJSON.object(bytes, limit: OwnerReadWire.responseLimit, maximumDepth: 32)
                    if let appleTaskID {
                        guard let returned=value["task_id"] as? String, UUID(uuidString:returned)==UUID(uuidString:appleTaskID),
                              OwnerReadWire.falseBoolean(value["automatic_replay"]), OwnerReadWire.falseBoolean(value["new_submission_allowed"])
                        else { throw OwnerReadFault.invalid }
                    }
                    if let cloudSupersedesID {
                        guard let returned = value["supersedes_request_id"] as? String,
                              UUID(uuidString: returned) == UUID(uuidString: cloudSupersedesID),
                              let replay = value["automatic_replay"] as? NSNumber, CFGetTypeID(replay) == CFBooleanGetTypeID(), !replay.boolValue,
                              let submit = value["new_submission_allowed"] as? NSNumber, CFGetTypeID(submit) == CFBooleanGetTypeID(), !submit.boolValue else { throw OwnerReadFault.invalid }
                    }
                    if let musicRequestID, ["outcome_unknown","readback_failed","song_absent","incomplete_read"].contains(value["state"] as? String ?? "") {
                        guard let returnedID = value["request_id"] as? String,
                              UUID(uuidString: returnedID) == UUID(uuidString: musicRequestID) else { throw OwnerReadFault.invalid }
                        let originalState = value["state"]
                        value.merge(musicUnknown(musicRequestID)) { _, new in new }
                        value["state"] = originalState
                    }
                    if name == OwnerReadWire.musicReconcile || name == OwnerReadWire.musicAppendRecovery {
                        guard let original = arguments["request_id"] as? String, let returned = value["request_id"] as? String,
                              UUID(uuidString: original) == UUID(uuidString: returned),
                              let replay = value["automatic_replay"] as? NSNumber, CFGetTypeID(replay) == CFBooleanGetTypeID(), !replay.boolValue,
                              let submit = value["new_submission_allowed"] as? NSNumber, CFGetTypeID(submit) == CFBooleanGetTypeID(), !submit.boolValue
                        else { throw OwnerReadFault.invalid }
                    }
                    if OwnerReadWire.musicWrites.contains(name), value["state"] as? String == "not_dispatched" {
                        value["automatic_replay"] = false; value["new_submission_allowed"] = true
                        value["next_step"] = "本次明确未发送。修复已报告原因后，可按用户明确要求使用原 request_id、原意图和原目标再次提交；禁止换 ID 或自动重试，实际提交仍由 ARL 核对原记录。"
                    }
                    if AppleCapability.names.contains(name) {
                        let succeeded=["saved_local","awaiting_local_action","operation_missing","cancelled"].contains(value["state"] as? String ?? "")
                        result=try content(value,error:!succeeded);result["structuredContent"]=value
                        return ["jsonrpc":"2.0","id":id,"result":result]
                    }
                    let succeeded = ["authorized_read", "succeeded", "ready", "verified", "already_present"].contains(value["state"] as? String ?? "")
                        || name == OwnerReadWire.musicReconcile && ["record_missing", "not_dispatched", "outcome_unknown", "account_changed", "readback_failed", "song_absent", "incomplete_read"].contains(value["state"] as? String ?? "")
                    if name == "mio_flyai_ai_search", value["state"] as? String == "timedOut" {
                        value["error_code"] = "UNAVAILABLE"
                        value["retryable"] = true
                        value["automatic_retry"] = false
                    }
                    result = try content(value, error: !succeeded)
                    if OwnerReadWire.travel.contains(name) || name == OwnerReadWire.musicReconcile ||
                        name == OwnerReadWire.musicAppendRecovery || name.hasPrefix("mio_netease_") { result["structuredContent"] = value }
                }
            } catch {
                let fault = (error as? OwnerReadExplicitRejection)?.fault ?? (error as? OwnerReadFault) ?? .unavailable
                if let appleTaskID {
                    let value: [String:Any] = ["state":name == AppleCapability.reminderStatus ? "status_unavailable":"outcome_unknown","ready":false,"task_id":appleTaskID,
                        "automatic_replay":false,"new_submission_allowed":false,"error":["code":fault.rawValue],
                        "next_step":"Inspect this same task_id with mio_reminders_operation_status. Never replace its UUID or automatically retry creation."]
                    result=try content(value,error:true);result["structuredContent"]=value
                    return ["jsonrpc":"2.0","id":id,"result":result]
                }
                if let cloudSupersedesID, ownerCallStarted,
                   ownerReplyReceived || !(error is OwnerReadExplicitRejection) || fault == .businessLogUnavailable {
                    let value: [String: Any] = ["state":"outcome_unknown", "ready":false,
                        "supersedes_request_id":cloudSupersedesID, "automatic_replay":false,"new_submission_allowed":false,
                        "error":["code":fault.rawValue],
                        "next_step":"Repeat this SAME current-cloud operation to reconcile its reserved successor; do not use old recovery or replace its target/UUID."]
                    result = try content(value, error:true); result["structuredContent"] = value
                    return ["jsonrpc":"2.0","id":id,"result":result]
                }
                if let musicRequestID, ownerCallStarted,
                   ownerReplyReceived || !(error is OwnerReadExplicitRejection) || fault == .businessLogUnavailable {
                    var value = musicUnknown(musicRequestID)
                    value["error"] = ["code": fault.rawValue]
                    value["failure_stage"] = ownerReplyReceived ? "owner_reply_decode" : "owner_call"
                    result = try content(value, error: true); result["structuredContent"] = value
                    return ["jsonrpc": "2.0", "id": id, "result": result]
                }
                var value: [String: Any] = ["error": ["code": fault.rawValue], "ready": false]
                if let musicRequestID {
                    value["request_id"] = musicRequestID; value["automatic_replay"] = false; value["new_submission_allowed"] = false
                    value["next_step"] = "Preserve the original request ID; inspect the reported error and reconcile before any explicitly authorized recovery."
                }
                if [.held, .unavailable, .unconfigured, .identity].contains(fault) {
                    value["configuration_ui"] = setupUI(name)
                    value["next_step"] = "请打开 ARL Control 的服务连接，检查应用凭据、登录状态及已审核 owner 连接。"
                }
                result = try content(value, error: true)
                if OwnerReadWire.travel.contains(name) || name.hasPrefix("mio_netease_") && !OwnerReadWire.musicWrites.contains(name) {result["structuredContent"] = value}

            }
        default:
            return ["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Unsupported method."]]
        }
        return ["jsonrpc": "2.0", "id": id, "result": result]
    }
    private static func invalidParams(_ id: Any) -> [String: Any] {
        protocolError(id: id, code: -32602, message: "Invalid params.")
    }
    private static func musicIntentID(_ tool: String, _ args: [String: Any]) throws -> String {
        if OwnerReadWire.musicBatchWrites.contains(tool) { return try OwnerReadWire.batchIntent(tool, args).id.uuidString }
        if OwnerReadWire.musicMetadataWrites.contains(tool) { return try OwnerReadWire.metadataIntent(tool, args).id.uuidString }
        let create = tool == "mio_netease_playlist_create"
        let required: Set<String> = create ? ["request_id", "intent", "name"] : ["request_id", "intent", "playlist_name", "playlist_id", "song_id"]
        guard required.isSubset(of: Set(args.keys)), Set(args.keys).isSubset(of: required.union(["reconcile_only"])),
              let id = args["request_id"] as? String, id.utf8.count == 36, UUID(uuidString: id) != nil,
              args["intent"] as? String == (create ? "create_playlist" : "append_song"),
              let name = args[create ? "name" : "playlist_name"] as? String, !name.isEmpty, name.count <= 100,
              name.utf8.count <= 400, name == name.trimmingCharacters(in: .whitespacesAndNewlines), !name.hasPrefix("-"),
              !name.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw OwnerReadFault.invalid }
        if let value = args["reconcile_only"] {
            guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw OwnerReadFault.invalid }
        }
        if !create {
            for key in ["playlist_id", "song_id"] {
                guard let value = args[key] as? String, value.utf8.count == 32,
                      value.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else { throw OwnerReadFault.invalid }
            }
        }
        return id
    }
    private static func musicUnknown(_ id: String) -> [String: Any] {
        ["state": "outcome_unknown", "ready": false, "request_id": id, "automatic_replay": false, "new_submission_allowed": false,
         "reconcile_only": true, "next_step": "保留原 request_id 和原目标，调用 mio_netease_playlist_reconcile 只查证已存在的请求；记录不存在也不写入。禁止重复 create 或换 ID 盲重试。"]
    }
    private static func protocolError(id: Any, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }
    private static func validID(_ value: Any) -> Bool {
        if let text = value as? String { return text.utf8.count <= 100 }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, abs(number.doubleValue) <= 9_007_199_254_740_991
        else { return false }; return number.doubleValue.rounded() == number.doubleValue
    }
    private static func respondAppleProduct(name:String,arguments:[String:Any],id:Any,
        callOwner:(String,Data)throws->Data)throws->[String:Any] {
        let bytes:Data
        let value:[String:Any]
        let succeeded:Bool
        var dispatched=false
        do {
            let input=try OwnerReadWire.encode(arguments,limit:OwnerReadWire.requestLimit)
            _=try AppleProductCapability.arguments(tool:name,data:input)
            dispatched=true
            let raw=try callOwner(name,input)
            let parsed=try OwnerReadJSON.object(raw,limit:OwnerReadWire.responseLimit-1024,maximumDepth:32)
            guard OwnerReadWire.integer(parsed["schema_version"],1),parsed["capability"] as? String=="apple.product.v1",
                  parsed["tool"] as? String==name,OwnerReadWire.falseBoolean(parsed["automatic_replay"]),
                  parsed["state"] is String,let code=parsed["code"] as? String,
                  code.range(of:"^[a-z0-9_]{1,96}$",options:.regularExpression) != nil else{throw OwnerReadFault.invalid}
            if let task=arguments["task_id"] as? String {guard parsed["task_id"] as? String==task else{throw OwnerReadFault.invalid}}
            let admitted=try AppleProductCapability.admit(parsed,tool:name,arguments:arguments)
            value=parsed;bytes=raw;succeeded=admitted
        } catch {
            let fault=(error as? OwnerReadExplicitRejection)?.fault ?? (error as? OwnerReadFault) ?? .unavailable
            let definitelyUnsent = !dispatched || error is OwnerReadExplicitRejection
            var failure:[String:Any]=["schema_version":1,"capability":"apple.product.v1","tool":name,"state":definitelyUnsent ? "not_dispatched" : AppleProductCapability.mutations.contains(name) ? "outcome_unknown":"unavailable",
                "code":fault.rawValue,"automatic_replay":false]
            if let task=arguments["task_id"] as? String {failure["task_id"]=task}
            failure["next_step"]="Preserve the original task ID and inspect the native result. Never replace an uncertain operation with a new ID or automatically retry."
            value=failure;bytes=try OwnerReadWire.encode(failure,limit:OwnerReadWire.responseLimit);succeeded=false
        }
        return ["jsonrpc":"2.0","id":id,"result":["content":[["type":"text","text":String(decoding:bytes,as:UTF8.self)]],"structuredContent":value,"isError":!succeeded]]
    }
    private static func respondNAS(name:String,arguments:[String:Any],id:Any,
                                   callOwner:(String,Data)throws->Data)throws->[String:Any] {
        let operation=String(name.dropFirst("mio_nas_".count))
        let bytes:Data
        let value:[String:Any]
        let succeeded:Bool
        do {
            let input=try OwnerReadWire.encode(arguments,limit:OwnerReadWire.requestLimit)
            let request=try NASCapability.request(tool:name,argumentsJSON:input)
            let original=try callOwner(name,input)
            let parsed=try OwnerReadJSON.object(original,limit:196608,maximumDepth:32)
            succeeded=try NASCapability.admit(parsed,request:request)
            bytes=original;value=parsed
        } catch {
            let fault=(error as? OwnerReadExplicitRejection)?.fault ?? (error as? OwnerReadFault) ?? .unavailable
            bytes=try NASCapability.failure(operation:operation,code:fault.rawValue)
            value=try OwnerReadJSON.object(bytes,limit:OwnerReadWire.responseLimit);succeeded=false
        }
        // Native JSON text is retained, not summarized/re-serialized or routed
        // through music state/error/setup projection. Structured fields match it.
        return ["jsonrpc":"2.0","id":id,"result":["content":[["type":"text","text":String(decoding:bytes,as:UTF8.self)]],
            "structuredContent":value,"isError":!succeeded]]
    }
    private static func content(_ value: [String: Any], error: Bool) throws -> [String: Any] {
        let bytes = try OwnerReadWire.encode(value, limit: OwnerReadWire.responseLimit)
        return ["content": [["type": "text", "text": String(decoding: bytes, as: UTF8.self)]], "isError": error]
    }
    private static func setupUI(_ tool: String) -> String {
        let provider = tool.hasPrefix("mio_maps_") ? "高德地图" : tool.hasPrefix("mio_flyai_") ? "飞猪" : "网易云音乐"
        return "ARL Control > 服务连接 > " + provider
    }
}
