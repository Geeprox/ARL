import Foundation
import CoreFoundation
import CryptoKit
#if canImport(ARLCredentialOnboarding)
import ARLCredentialOnboarding
#endif

/// Finite shared MCP schema only; no endpoint, credential, authority or file IO.
enum NASCapability {
    static let names:Set<String> = Set(["mio_nas_list","mio_nas_search","mio_nas_read"]).union(NASDownloadCapability.names).union(NASFileReaderContract.names).union(NASDocumentContract.names)
    struct Request:Sendable {
        let tool:String
        let operation:String
        let argumentsJSON:Data
        let mayRestoreSavedScope:Bool
    }
    static var descriptors:[[String:Any]] {
        let bytes=Data(#"{"tools":[{"name":"mio_nas_list","description":"列出已选目录的真实文件；使用原游标续页，不递归。","inputSchema":{"type":"object","additionalProperties":false,"properties":{"directory_ref":{"type":"string","pattern":"^[0-9a-f]{64}$"},"cursor":{"type":"string","pattern":"^[0-9a-f]{32}$"},"limit":{"type":"integer","minimum":1,"maximum":32,"default":16}},"required":[]},"annotations":{"readOnlyHint":true,"destructiveHint":false,"idempotentHint":true,"openWorldHint":true},"_meta":{"arl/capability":"mio_nas","arl/version":1,"arl/risk":"low","arl/requiresConfirmation":false}},{"name":"mio_nas_search","description":"在已选单目录按文件名搜索；保留真实路径、原始条目及有限分页。","inputSchema":{"type":"object","additionalProperties":false,"properties":{"directory_ref":{"type":"string","pattern":"^[0-9a-f]{64}$"},"cursor":{"type":"string","pattern":"^[0-9a-f]{32}$"},"limit":{"type":"integer","minimum":1,"maximum":32,"default":16},"keyword":{"type":"string","minLength":1,"maxLength":256,"description":"Maximum 256 UTF-8 bytes; NFC casefold basename literal contains."}},"required":["keyword"]},"annotations":{"readOnlyHint":true,"destructiveHint":false,"idempotentHint":true,"openWorldHint":true},"_meta":{"arl/capability":"mio_nas","arl/version":1,"arl/risk":"low","arl/requiresConfirmation":false}},{"name":"mio_nas_read","description":"按原搜索/列表的引用和版本读取有限原字节；禁止改绑来源或自动重试。","inputSchema":{"type":"object","additionalProperties":false,"properties":{"source_ref":{"type":"string","pattern":"^[A-Za-z0-9_-]{1,96}$"},"config_generation":{"type":"integer","minimum":1,"maximum":9223372036854775807},"connection_epoch":{"type":"string","pattern":"^[0-9a-f]{32}$"},"object_ref":{"type":"string","pattern":"^[0-9a-f]{64}$"},"revision":{"type":"string","pattern":"^[0-9a-f]{64}$"},"offset":{"type":"integer","minimum":0,"maximum":9223372036854775807},"length":{"type":"integer","minimum":1,"maximum":131072,"description":"Explicit byte count; recommend 65536."}},"required":["source_ref","config_generation","connection_epoch","object_ref","revision","offset","length"]},"annotations":{"readOnlyHint":true,"destructiveHint":false,"idempotentHint":true,"openWorldHint":true},"_meta":{"arl/capability":"mio_nas","arl/version":1,"arl/risk":"low","arl/requiresConfirmation":false}}]}"#.utf8)
        return ((try! OwnerReadJSON.object(bytes,limit:OwnerReadWire.requestLimit))["tools"] as! [[String:Any]]) + NASDownloadCapability.descriptors + NASFileReaderContract.descriptors + NASDocumentContract.descriptors
    }
    static func integer(_ value:Any?) -> Int? {
        guard let n=value as? NSNumber,CFGetTypeID(n) != CFBooleanGetTypeID(),n.doubleValue.isFinite,
              n.doubleValue.rounded(.towardZero)==n.doubleValue,
              n.compare(NSNumber(value:Int64.min)) != .orderedAscending,
              n.compare(NSNumber(value:Int64.max)) != .orderedDescending else{return nil}
        return n.intValue
    }
    static func matches(_ value:Any?,_ pattern:String)->Bool {
        guard let text=value as? String else{return false};return text.range(of:pattern,options:.regularExpression) != nil
    }
    static func hex(_ value:Any?,_ length:Int)->Bool {matches(value,"^[0-9a-f]{"+String(length)+"}$")}
    static func request(tool:String,argumentsJSON:Data)throws->Request {
        guard names.contains(tool) else{throw OwnerReadFault.unsupported}
        let args=try OwnerReadJSON.object(argumentsJSON,limit:OwnerReadWire.requestLimit)
        let operation=String(tool.dropFirst("mio_nas_".count))
        if NASDocumentContract.names.contains(tool) {
            do {_ = try NASDocumentContract.request(tool:tool,argumentsJSON:argumentsJSON)}
            catch {throw OwnerReadFault.invalid}
            return .init(tool:tool,operation:operation,argumentsJSON:argumentsJSON,mayRestoreSavedScope:false)
        }
        if NASFileReaderContract.names.contains(tool) {
            do {_ = try NASFileReaderContract.request(tool:tool,argumentsJSON:argumentsJSON)}
            catch {throw OwnerReadFault.invalid}
            return .init(tool:tool,operation:operation,argumentsJSON:argumentsJSON,mayRestoreSavedScope:false)
        }
        if NASDownloadCapability.names.contains(tool) {
            try NASDownloadCapability.validate(tool:tool,args:args)
            return .init(tool:tool,operation:operation,argumentsJSON:argumentsJSON,mayRestoreSavedScope:false)
        }
        if operation=="read" {
            guard Set(args.keys)==["source_ref","config_generation","connection_epoch","object_ref","revision","offset","length"],
                  matches(args["source_ref"],"^[A-Za-z0-9_-]{1,96}$"),hex(args["connection_epoch"],32),hex(args["object_ref"],64),hex(args["revision"],64),
                  let generation=integer(args["config_generation"]),generation>0,
                  let offset=integer(args["offset"]),offset>=0,let length=integer(args["length"]),(1...131072).contains(length)
            else{throw OwnerReadFault.invalid}
        } else {
            let keys:Set<String>=operation=="search" ? ["keyword","directory_ref","cursor","limit"]:["directory_ref","cursor","limit"]
            guard Set(args.keys).isSubset(of:keys),args["directory_ref"]==nil || hex(args["directory_ref"],64),
                  args["cursor"]==nil || hex(args["cursor"],32),args["limit"]==nil || (1...32).contains(integer(args["limit"]) ?? 0)
            else{throw OwnerReadFault.invalid}
            if operation=="search" {
                guard let keyword=args["keyword"] as? String,(1...256).contains(keyword.utf8.count),
                      !keyword.unicodeScalars.contains(where:{CharacterSet.controlCharacters.contains($0)})
                else{throw OwnerReadFault.invalid}
            }
        }
        return .init(tool:tool,operation:operation,argumentsJSON:argumentsJSON,mayRestoreSavedScope:operation != "read" && args["cursor"]==nil)
    }
    static func failure(operation:String,code:String)throws->Data {
        let finite=code.range(of:"^[A-Za-z][A-Za-z0-9_]{0,95}$",options:.regularExpression) == nil ? "nas_unavailable":code
        return try OwnerReadWire.encode(["schema_version":1,"operation":operation,"state":"failed","error":["code":finite],"automatic_replay":false],limit:OwnerReadWire.responseLimit)
    }
    /// Native has already admitted full scope/revision/result bounds. The public
    /// projection additionally binds the response type and request references.
    static func admit(_ value:[String:Any],request:Request)throws->Bool {
        guard integer(value["schema_version"])==1,value["operation"] as? String==request.operation else{throw OwnerReadFault.invalid}
        if value["state"] as? String=="failed" {
            guard Set(value.keys)==["schema_version","operation","state","error","automatic_replay"],
                  let error=value["error"] as? [String:Any],Set(error.keys)==["code"],
                  matches(error["code"],"^[A-Za-z][A-Za-z0-9_]{0,95}$"),OwnerReadWire.falseBoolean(value["automatic_replay"])
            else{throw OwnerReadFault.invalid};return false
        }
        if NASDocumentContract.names.contains(request.tool) {
            do {
                let wire=try NASDocumentContract.request(tool:request.tool,argumentsJSON:request.argumentsJSON)
                try NASDocumentContract.admit(value,request:wire)
                return true
            } catch {throw OwnerReadFault.invalid}
        }
        if NASFileReaderContract.names.contains(request.tool) {
            do {
                let wire=try NASFileReaderContract.request(tool:request.tool,argumentsJSON:request.argumentsJSON)
                try NASFileReaderContract.admit(value,request:wire)
                return true
            } catch {throw OwnerReadFault.invalid}
        }
        if NASDownloadCapability.names.contains(request.tool) {
            return try NASDownloadCapability.admit(value,tool:request.tool,args:OwnerReadJSON.object(request.argumentsJSON,limit:OwnerReadWire.requestLimit))
        }
        let base:Set<String>=["schema_version","operation","source_ref","config_generation","connection_epoch","location","snapshot_consistent"]
        let fields:Set<String>=request.operation=="read" ? ["entry","offset","length","bytes_read","data_base64","eof","next_offset"]
            : ["directory_ref","keyword","entries","match_mode","next_cursor","enumeration_complete","partial","stopped_reason","scanned_count","pages","recursive"]
        guard Set(value.keys)==base.union(fields),matches(value["source_ref"],"^[A-Za-z0-9_-]{1,96}$"),
              (integer(value["config_generation"]) ?? 0)>0,hex(value["connection_epoch"],32),
              value["location"] is [String:Any],OwnerReadWire.falseBoolean(value["snapshot_consistent"])
        else{throw OwnerReadFault.invalid}
        let args=try OwnerReadJSON.object(request.argumentsJSON,limit:OwnerReadWire.requestLimit)
        if request.operation=="read" {
            guard value["source_ref"] as? String==args["source_ref"] as? String,
                  integer(value["config_generation"])==integer(args["config_generation"]),value["connection_epoch"] as? String==args["connection_epoch"] as? String,
                  let entry=value["entry"] as? [String:Any],entry["object_ref"] as? String==args["object_ref"] as? String,
                  entry["revision"] as? String==args["revision"] as? String,integer(value["offset"])==integer(args["offset"]),
                  integer(value["length"])==integer(args["length"]),let count=integer(value["bytes_read"]),count>=0,count<=(integer(args["length"]) ?? 0),
                  let encoded=value["data_base64"] as? String,let bytes=Data(base64Encoded:encoded),bytes.count==count
            else{throw OwnerReadFault.invalid}
        } else {
            guard let entries=value["entries"] as? [[String:Any]],entries.count<=(integer(args["limit"]) ?? 16),
                  OwnerReadWire.falseBoolean(value["recursive"]),
                  (args["directory_ref"]==nil ? value["directory_ref"] is NSNull:value["directory_ref"] as? String==args["directory_ref"] as? String),
                  (args["keyword"]==nil ? value["keyword"] is NSNull:value["keyword"] as? String==args["keyword"] as? String)
            else{throw OwnerReadFault.invalid}
        }
        return true
    }
}


/// Two read-only tools over the existing native read scope. No URL importer,
/// persistent scope issuer, mutation permit or platform artifact publisher.
enum NASDownloadCapability {
    static let names:Set<String>=["mio_nas_download","mio_nas_transfer_read"]
    static let chunkBytes=32768, fileBytes=1048576
    static var common:Set<String> {["operation_id","source_ref","config_generation","connection_epoch"]}
    static var descriptors:[[String:Any]] {
        names.sorted().map { tool in
            let download=tool=="mio_nas_download"
            var properties:[String:Any]=[
                "operation_id":["type":"string","format":"uuid","pattern":"^[0-9a-f-]{36}$"],
                "source_ref":["type":"string","pattern":"^[A-Za-z0-9_-]{1,96}$"],
                "config_generation":["type":"integer","minimum":1,"maximum":Int64.max],
                "connection_epoch":["type":"string","pattern":"^[0-9a-f]{32}$"],
                "size":["type":"integer","minimum":0,"maximum":fileBytes]]
            if download {
                properties["object_ref"]=["type":"string","pattern":"^[0-9a-f]{64}$"]
                properties["revision"]=["type":"string","pattern":"^[0-9a-f]{64}$"]
                properties["name"]=["type":"string","minLength":1,"maxLength":255,"description":"Output basename only; no path or NAS selector."]
            } else {
                properties["transfer_ref"]=["type":"string","pattern":"^[0-9a-f]{64}$"]
                properties["sha256"]=["type":"string","pattern":"^[0-9a-f]{64}$"]
                properties["offset"]=["type":"integer","minimum":0,"maximum":fileBytes]
                properties["length"]=["type":"integer","minimum":1,"maximum":chunkBytes]
            }
            return ["name":tool,"description":download
                ? "Use this to read a complete selected NAS file using the exact source, epoch, object_ref, revision and size from list/search. First-round whole-file budget is 1MiB, read in 32KiB ranges within the existing epoch's cumulative budget. Returns SHA256 and a 120-second ephemeral transfer_ref. Does not reconnect, create a URL, or publish a ChatGPT attachment. No automatic retry."
                : "Use this to read a verified 32KiB byte chunk from the original NAS download transfer_ref. Preserve operation_id, scope/epoch, size and whole-file SHA256 from the manifest. The native owner rechecks current saved scope and credential identity. Expiry/revocation never reconnects or rebinds the file. Bytes are not a downloadable ChatGPT artifact.",
                "inputSchema":["type":"object","additionalProperties":false,"properties":properties,"required":properties.keys.sorted()],
                "annotations":["readOnlyHint":true,"destructiveHint":false,"idempotentHint":true,"openWorldHint":true],
                "_meta":["arl/capability":"mio_nas","arl/version":1,"arl/risk":"low","arl/requiresConfirmation":false]]
        }
    }
    static func validate(tool:String,args:[String:Any])throws {
        let download=tool=="mio_nas_download"
        let extra:Set<String>=download ? ["object_ref","revision","name","size"] : ["transfer_ref","size","sha256","offset","length"]
        guard names.contains(tool),Set(args.keys)==common.union(extra),
              let id=args["operation_id"] as? String,UUID(uuidString:id)?.uuidString.lowercased()==id,
              NASCapability.matches(args["source_ref"],"^[A-Za-z0-9_-]{1,96}$"),
              (NASCapability.integer(args["config_generation"]) ?? 0)>0,NASCapability.hex(args["connection_epoch"],32),
              let size=NASCapability.integer(args["size"]),(0...fileBytes).contains(size)
        else {throw OwnerReadFault.invalid}
        if download {
            guard NASCapability.hex(args["object_ref"],64),NASCapability.hex(args["revision"],64),
                  let name=args["name"] as? String,(1...255).contains(name.utf8.count),name != ".",name != "..",
                  !name.contains("/"),!name.contains("\\"),!name.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains)
            else {throw OwnerReadFault.invalid}
        } else {
            guard NASCapability.hex(args["transfer_ref"],64),NASCapability.hex(args["sha256"],64),
                  let offset=NASCapability.integer(args["offset"]),(0...size).contains(offset),
                  let length=NASCapability.integer(args["length"]),(1...chunkBytes).contains(length)
            else {throw OwnerReadFault.invalid}
        }
    }
    static func admit(_ value:[String:Any],tool:String,args:[String:Any])throws->Bool {
        try validate(tool:tool,args:args)
        let download=tool=="mio_nas_download",operation=download ? "download":"transfer_read"
        let base=common.union(["schema_version","operation","size","sha256","transfer_ref","downloadable_artifact","delivery_code"])
        let keys=download ? base.union(["name","object_ref","revision","expires_in_seconds","complete","direction"])
            : base.union(["offset","length","bytes_read","data_base64","chunk_sha256","eof","next_offset"])
        guard Set(value.keys)==keys,NASCapability.integer(value["schema_version"])==1,value["operation"] as? String==operation,
              common.allSatisfy({ key in
                  if key=="config_generation" {return NASCapability.integer(value[key])==NASCapability.integer(args[key])}
                  return value[key] as? String==args[key] as? String
              }),NASCapability.integer(value["size"])==NASCapability.integer(args["size"]),
              NASCapability.hex(value["sha256"],64),NASCapability.hex(value["transfer_ref"],64),
              OwnerReadWire.falseBoolean(value["downloadable_artifact"]),value["delivery_code"] as? String=="platform_file_publisher_required"
        else {throw OwnerReadFault.invalid}
        if download {
            guard ["name","object_ref","revision"].allSatisfy({value[$0] as? String==args[$0] as? String}),
                  NASFileBool.trueValue(value["complete"]),value["direction"] as? String=="download",
                  let ttl=value["expires_in_seconds"] as? NSNumber,CFGetTypeID(ttl) != CFBooleanGetTypeID(),ttl.doubleValue.isFinite,
                  ttl.doubleValue>0,ttl.doubleValue<=120 else {throw OwnerReadFault.invalid}
        } else {
            guard value["transfer_ref"] as? String==args["transfer_ref"] as? String,value["sha256"] as? String==args["sha256"] as? String,
                  let offset=NASCapability.integer(value["offset"]),offset==NASCapability.integer(args["offset"]),
                  let length=NASCapability.integer(value["length"]),length==NASCapability.integer(args["length"]),
                  let size=NASCapability.integer(value["size"]),let count=NASCapability.integer(value["bytes_read"]),count==min(length,size-offset),
                  let encoded=value["data_base64"] as? String,encoded.utf8.count<=4*((chunkBytes+2)/3),
                  let bytes=Data(base64Encoded:encoded),bytes.count==count,bytes.base64EncodedString()==encoded,
                  value["chunk_sha256"] as? String==hash(bytes),
                  (count==size-offset ? NASFileBool.trueValue(value["eof"]):OwnerReadWire.falseBoolean(value["eof"])),
                  count==size-offset ? value["next_offset"] is NSNull:NASCapability.integer(value["next_offset"])==offset+count
            else {throw OwnerReadFault.invalid}
        }
        return true
    }
    static func hash(_ data:Data)->String {SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
}

private enum NASFileBool {
    static func trueValue(_ value:Any?)->Bool {
        guard let n=value as? NSNumber,CFGetTypeID(n)==CFBooleanGetTypeID() else{return false}
        return n.boolValue
    }
}
