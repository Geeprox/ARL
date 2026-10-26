import Foundation
import Darwin

let mioCalendarName="mio_calendar_create_v1"
let mioSubject="mio_private_adapter"
func jsonBytes(_ value:Any)throws->Data{try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys,.withoutEscapingSlashes])}
// Admit only the exact preserved travel14 catalog, optionally followed by the
// six reviewed music/status descriptors. Counts alone confer no admission.
func validateMioBaseDescriptors(_ tools:[[String:Any]])throws {
    let names=tools.compactMap{$0["name"] as? String}
    guard [14,20].contains(tools.count),names.count==tools.count,
          Set(names).count==tools.count,!names.contains(mioCalendarName),
          digest(try jsonBytes(Array(tools.prefix(14))))=="27a13fea4e9273a7c128853f1fe9eee3c10dc34a8d84edddf33f645845d06f2a"
    else{throw ReviewFault("legacy_schema_changed")}
    if tools.count==20 {
        guard digest(try jsonBytes(Array(tools.suffix(6))))=="f5b7a32cb7d77ae41b839385f8a03cd068705fe6e4896e0d27bf2a9327778ad6"
        else{throw ReviewFault("legacy_schema_changed")}
    }
}
// New capabilities append after the exact legacy twenty, and each descriptor
// must reconstruct from the same narrow registry policy used by the owner.
func validateMioPublishedDescriptors(_ published: [[String: Any]]) throws {
    var tools = published
    if tools.last?["name"] as? String == MioAttachmentInspection.name {
        guard let descriptor = tools.last, try jsonBytes(descriptor) == jsonBytes(MioAttachmentInspection.descriptor)
        else { throw ReviewFault("capability_schema_changed") }
        tools.removeLast()
    }
    guard !tools.contains(where: { $0["name"] as? String == MioAttachmentInspection.name })
    else { throw ReviewFault("capability_schema_changed") }
    if let last=tools.last?["name"] as? String,NASCapability.names.contains(last) {
        let count=NASCapability.descriptors.count
        guard tools.count>=count,try jsonBytes(Array(tools.suffix(count)))==jsonBytes(NASCapability.descriptors)
        else{throw ReviewFault("capability_schema_changed")}
        tools.removeLast(count)
    }
    guard !tools.contains(where:{NASCapability.names.contains($0["name"] as? String ?? "")})
    else{throw ReviewFault("capability_schema_changed")}
    if let name=tools.last?["name"] as? String,AppleProductCapability.names.contains(name) {
        let count=AppleProductCapability.descriptors.count
        guard tools.count>=count,try jsonBytes(Array(tools.suffix(count)))==jsonBytes(AppleProductCapability.descriptors) else{throw ReviewFault("capability_schema_changed")}
        tools.removeLast(count)
    }
    guard !tools.contains(where:{AppleProductCapability.names.contains($0["name"] as? String ?? "")}) else{throw ReviewFault("capability_schema_changed")}
    if tools.last?["name"] as? String == AppleCapability.reminderStatus {
        guard tools.count >= 2,
              try jsonBytes(Array(tools.suffix(2))) == jsonBytes(AppleCapability.descriptors)
        else { throw ReviewFault("capability_schema_changed") }
        tools.removeLast(2)
    }
    guard !tools.contains(where:{ AppleCapability.names.contains($0["name"] as? String ?? "") })
    else { throw ReviewFault("capability_schema_changed") }
    if tools.last?["name"] as? String == OwnerReadWire.musicAggregate {
        guard let descriptor = tools.last,
              try jsonBytes(descriptor) == jsonBytes(OwnerReadWire.musicAggregateDescriptor)
        else { throw ReviewFault("capability_schema_changed") }
        tools.removeLast()
    }
    if tools.last?["name"] as? String == OwnerReadWire.musicReconcile {
        guard let descriptor = tools.last,
              try jsonBytes(descriptor) == jsonBytes(OwnerReadWire.musicReconcileDescriptor)
        else { throw ReviewFault("capability_schema_changed") }
        tools.removeLast()
    }
    if tools.last?["name"] as? String == OwnerReadWire.musicCurrentCloudAppend {
        guard let descriptor = tools.last,
              try jsonBytes(descriptor) == jsonBytes(OwnerReadWire.musicCurrentCloudAppendDescriptor)
        else { throw ReviewFault("capability_schema_changed") }
        tools.removeLast()
    }
    if tools.last?["name"] as? String == OwnerReadWire.musicAppendRecovery {
        guard let descriptor = tools.last,
              try jsonBytes(descriptor) == jsonBytes(OwnerReadWire.musicAppendRecoveryDescriptor)
        else { throw ReviewFault("capability_schema_changed") }
        tools.removeLast()
    }
    if tools.last?["name"] as? String == MusicPlaylistCoverCapability.name {
        guard let descriptor = tools.last,
              try jsonBytes(descriptor) == jsonBytes(MusicPlaylistCoverCapability.descriptor)
        else { throw ReviewFault("capability_schema_changed") }
        tools.removeLast()
    }
    if tools.last?["name"] as? String == "mio_flyai_search_poi" {
        let additions = MioReadCatalog.flyAIAdditionDescriptors
        guard additions.count == 4, tools.count >= 4,
              try jsonBytes(Array(tools.suffix(4))) == jsonBytes(additions)
        else { throw ReviewFault("capability_schema_changed") }
        tools.removeLast(4)
    }
    if tools.last?["name"] as? String == "mio_netease_playlist_update_desc" {
        let additions = OwnerReadWire.musicMetadataDescriptors
        guard additions.count == 2, tools.count >= 2, try jsonBytes(Array(tools.suffix(2))) == jsonBytes(additions)
        else { throw ReviewFault("capability_schema_changed") }
        tools.removeLast(2)
    }
    if tools.last?["name"] as? String == "mio_netease_playlist_remove_songs" {
        let additions = OwnerReadWire.musicBatchDescriptors
        guard additions.count == 4, tools.count >= 4, try jsonBytes(Array(tools.suffix(4))) == jsonBytes(additions) else { throw ReviewFault("capability_schema_changed") }
        tools.removeLast(4)
    }
    if tools.last?["name"] as? String == "mio_netease_playlist_get_tags" {
        let additions=OwnerReadWire.musicLibraryDescriptors
        guard additions.count==10,tools.count>=10,try jsonBytes(Array(tools.suffix(10)))==jsonBytes(additions)
        else {throw ReviewFault("capability_schema_changed")}
        tools.removeLast(10)
    }
    if [14, 20].contains(tools.count) { try validateMioBaseDescriptors(tools); return }
    throw ReviewFault("capability_schema_changed")
}
// No caller/target identifier/approval/command/path accepted from the tool call.
final class MioCalendarConsumer {
    let engine:AppleApprovalEngine;let effects:AppleEffects;let policy:()->ReviewPolicy?
    init(engine:AppleApprovalEngine,effects:AppleEffects,policy:@escaping()->ReviewPolicy?){self.engine=engine;self.effects=effects;self.policy=policy}
    // Retired: Calendar business now executes only in the authenticated main
    // ARL owner through CalendarBusinessHandler. Sealed v1 grants and receipts
    // stay intact; neither catalog nor direct calls can resume that old effect.
    var descriptor:[String:Any]? { nil }
    func call(_ arguments:[String:Any],caller:AuthenticatedCaller,cancelled:()->Bool={false})throws->[String:Any] {
        throw ReviewFault("calendar_v1_retired")
    }
    func respond(_ request:[String:Any],caller:AuthenticatedCaller,legacy:([String:Any])throws->[String:Any],cancelled:()->Bool={false})throws->[String:Any] {
        guard let method=request["method"] as? String else{throw ReviewFault("invalid_arguments")}
        let params=request["params"] as? [String:Any] ?? [:]
        if method=="tools/call",params["name"] as? String==mioCalendarName {
            guard Set(params.keys)==Set(["name","arguments"]),let arguments=params["arguments"] as? [String:Any] else{throw ReviewFault("invalid_arguments")}
            do {
                let receipt=try call(arguments,caller:caller,cancelled:cancelled)
                return ["jsonrpc":"2.0","id":request["id"] ?? NSNull(),"result":["content":[["type":"text","text":String(decoding:try jsonBytes(receipt),as:UTF8.self)]]]]
            } catch let fault as ReviewFault {
                // Finite codes only, no title, Apple metadata, paths or exception text.
                return ["jsonrpc":"2.0","id":request["id"] ?? NSNull(),"result":["isError":true,"content":[["type":"text","text":String(decoding:try jsonBytes(["code":fault.code,"replay":"never_automatic"]),as:UTF8.self)]]]]
            }
        }
        var response=try legacy(request)
        if method=="tools/list" {
            guard var result=response["result"] as? [String:Any],var tools=result["tools"] as? [[String:Any]]
            else{throw ReviewFault("legacy_schema_changed")}
            try validateMioPublishedDescriptors(tools)
            if let descriptor{tools.append(descriptor)}
            result["tools"]=tools;response["result"]=result
        }
        return response
    }
}
