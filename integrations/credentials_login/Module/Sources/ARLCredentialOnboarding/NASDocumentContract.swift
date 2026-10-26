import Foundation
import CoreFoundation

/// Pure scoped document contract. No parser, credential, reconnect or authority.
public enum NASDocumentContract {
    public enum Fault: Error { case invalidRequest, invalidReply }
    public static let name = "mio_nas_read_document"
    public static let names: Set<String> = [name]
    private static let requestKeys: Set<String> = ["source_ref","config_generation","connection_epoch","object_ref","revision","size","name"]
    private static func integer(_ value: Any?) -> Int64? {
        guard let n=value as? NSNumber,CFGetTypeID(n) != CFBooleanGetTypeID(),
              n.doubleValue.isFinite,n.doubleValue.rounded(.towardZero)==n.doubleValue,
              n.compare(NSNumber(value:Int64.min)) != .orderedAscending,
              n.compare(NSNumber(value:Int64.max)) != .orderedDescending else{return nil}
        return n.int64Value
    }
    private static func boolean(_ value:Any?)->Bool? {
        guard let n=value as? NSNumber,CFGetTypeID(n)==CFBooleanGetTypeID() else{return nil};return n.boolValue
    }
    private static func matches(_ value:Any?,_ regex:String)->Bool {
        (value as? String)?.range(of:regex,options:.regularExpression) != nil
    }
    public static var descriptors:[[String:Any]] {
        let properties:[String:Any]=[
            "source_ref":["type":"string","pattern":"^[A-Za-z0-9_-]{1,96}$"],
            "config_generation":["type":"integer","minimum":1,"maximum":Int64.max],
            "connection_epoch":["type":"string","pattern":"^[0-9a-f]{32}$"],
            "object_ref":["type":"string","pattern":"^[0-9a-f]{64}$"],
            "revision":["type":"string","pattern":"^[0-9a-f]{64}$"],
            "size":["type":"integer","minimum":0,"maximum":33554432],
            "unit_offset":["type":"integer","minimum":1],
            "text_offset":["type":"integer","minimum":0],
            "name":["type":"string","minLength":1,"maxLength":255,"description":"Original file basename; selects PDF/DOCX/XLSX/PPTX parser, never a path or executable."]]
        return [["name":name,
            "description":"Read text from one exact PDF/DOCX/XLSX/PPTX NAS object through the existing live read-only scope. Document parser memory budget 32MiB, independent of upload limits. Use next_unit_offset and next_text_offset to continue on the same immutable revision. Checks revision and SHA before parsing. No reconnect, scope restore, formula execution, OCR or downloadable attachment. Image-only PDF returns no_extractable_text; encrypted/unsupported documents return the actual finite error. Text/unit/frame budgets page the result with a continuation.",
            "inputSchema":["type":"object","additionalProperties":false,"properties":properties,"required":requestKeys.sorted()],
            "outputSchema":["type":"object","required":["schema_version","operation","state"],
                "properties":["schema_version":["const":1],"operation":["const":"read_document"],
                    "state":["enum":["extracted","no_extractable_text","failed"]]],"additionalProperties":true],
            "annotations":["readOnlyHint":true,"destructiveHint":false,"idempotentHint":true,"openWorldHint":true],
            "_meta":["arl/capability":"mio_nas","arl/version":1,"arl/risk":"low","arl/requiresConfirmation":false]]]
    }
    public static func request(tool:String,argumentsJSON:Data)throws->[String:Any] {
        guard tool==name,argumentsJSON.count<=16384,
              var args=try JSONSerialization.jsonObject(with:argumentsJSON) as? [String:Any],
              requestKeys.isSubset(of:Set(args.keys)),Set(args.keys).isSubset(of:requestKeys.union(["unit_offset","text_offset"])),matches(args["source_ref"],"^[A-Za-z0-9_-]{1,96}$"),
              let generation=integer(args["config_generation"]),generation>0,
              matches(args["connection_epoch"],"^[0-9a-f]{32}$"),
              matches(args["object_ref"],"^[0-9a-f]{64}$"),matches(args["revision"],"^[0-9a-f]{64}$"),
              let size=integer(args["size"]),(0...33554432).contains(size),
              let filename=args["name"] as? String,(1...255).contains(filename.utf8.count),
              ![".",".."].contains(filename),!filename.contains("/"),!filename.contains("\\"),
              !filename.unicodeScalars.contains(where:{$0.value<32 || $0.value==127})
        else{throw Fault.invalidRequest}
        for (key, lower) in [("unit_offset",Int64(1)),("text_offset",Int64(0))] {
            if let raw=args[key] {guard let n=integer(raw),n>=lower else {throw Fault.invalidRequest}}
        }
        args["operation"]="read_document";return args
    }
    public static func admit(_ value:[String:Any],request:[String:Any],expectedLocation:[String:Any]?=nil)throws {
        if value["state"] as? String=="failed" {
            guard Set(value.keys)==["schema_version","operation","state","error","automatic_replay"],
                  integer(value["schema_version"])==1,value["operation"] as? String=="read_document",
                  boolean(value["automatic_replay"])==false,let error=value["error"] as? [String:Any],
                  Set(error.keys)==["code"],matches(error["code"],"^[A-Za-z][A-Za-z0-9_]{0,95}$")
            else{throw Fault.invalidReply};return
        }
        let fields:Set<String>=["schema_version","operation","format","file_name","source_size","source_sha256","state","units","text","complete","truncated","stopped_reasons","coverage","downloadable_artifact","source_ref","config_generation","connection_epoch","location","snapshot_consistent","object_ref","revision","entry","unit_offset","text_offset","next_unit_offset","next_text_offset"]
        guard Set(value.keys)==fields,integer(value["schema_version"])==1,
              value["operation"] as? String=="read_document",
              ["source_ref","connection_epoch","object_ref","revision"].allSatisfy({value[$0] as? String==request[$0] as? String}),
              integer(value["config_generation"])==integer(request["config_generation"]),
              integer(value["source_size"])==integer(request["size"]),
              value["file_name"] as? String==request["name"] as? String,
              matches(value["source_sha256"],"^[0-9a-f]{64}$"),
              let format=value["format"] as? String,["pdf","docx","xlsx","pptx"].contains(format),
              (request["name"] as? String).map({URL(fileURLWithPath:$0).pathExtension.lowercased()==format})==true,
              boolean(value["snapshot_consistent"])==false,boolean(value["downloadable_artifact"])==false,
              let location=value["location"] as? [String:Any],Set(location.keys)==["host","port","share","root"],
              let port=integer(location["port"]),(1...65535).contains(port),location["host"] is String,location["share"] is String,
              let root=location["root"] as? String,
              expectedLocation==nil || NSDictionary(dictionary:location).isEqual(to:expectedLocation!),
              let entry=value["entry"] as? [String:Any],entry["kind"] as? String=="file",
              entry["object_ref"] as? String==request["object_ref"] as? String,
              entry["revision"] as? String==request["revision"] as? String,integer(entry["size"])==integer(request["size"]),
              let path=entry["path"] as? String,!path.hasPrefix("/"),!path.contains("\\"),
              !path.split(separator:"/",omittingEmptySubsequences:false).contains(where:{$0=="" || $0=="." || $0==".."}),
              root.isEmpty || path.hasPrefix(root+"/"),
              let units=value["units"] as? [[String:Any]],units.count<=128,
              let text=value["text"] as? String,text.utf8.count<=65536,
              let complete=boolean(value["complete"]),boolean(value["truncated"]) == !complete,
              let reasons=value["stopped_reasons"] as? [String],reasons==Array(Set(reasons)).sorted(),
              Set(reasons).isSubset(of:["text_budget","unit_budget","output_budget","pdf_worker_budget","owner_frame_budget"]),
              complete==reasons.isEmpty,value["coverage"] is String
        else{throw Fault.invalidReply}
        let kind=["pdf":"page","docx":"paragraph","xlsx":"sheet","pptx":"slide"][format]!
        let start=integer(value["unit_offset"]), textStart=integer(value["text_offset"])
        guard start==(integer(request["unit_offset"]) ?? 1),textStart==(integer(request["text_offset"]) ?? 0) else{throw Fault.invalidReply}
        if complete {guard value["next_unit_offset"] is NSNull,value["next_text_offset"] is NSNull else{throw Fault.invalidReply}}
        else {guard let next=integer(value["next_unit_offset"]),let nextText=integer(value["next_text_offset"]),next>start! || next==start! && nextText>textStart! else{throw Fault.invalidReply}}
        var previous:Int64=start!-1
        for unit in units {
            let allowed:Set<String>=format=="xlsx" ? ["kind","index","text","text_offset","name","hidden"]:["kind","index","text","text_offset"]
            guard Set(unit.keys)==allowed,unit["kind"] as? String==kind,
                  let index=integer(unit["index"]),index>previous,unit["text"] is String,let offset=integer(unit["text_offset"]),offset>=0,
                  format != "xlsx" || unit["name"] is String && boolean(unit["hidden"]) != nil
            else{throw Fault.invalidReply}
            previous=index
        }
        guard text==units.map({$0["text"] as! String}).joined(separator:"\n"),
              value["state"] as? String==(units.contains(where:{!($0["text"] as! String).isEmpty}) ? "extracted":"no_extractable_text")
        else{throw Fault.invalidReply}
    }
}
