import Foundation
@main enum MusicBusinessInfoTests {
    static func main() throws {
        let fixture=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))) as! [String:Any]
        let raw=fixture["read"] as! [String:Any],request=MusicReadRequest.search(keyword:"Sample")
        let decoded=try MusicReadProtocol.decode(raw,for:request),song=decoded.payload!.songs![0],info=song.metadata.businessInfo!
        precondition(info.durationRaw==243487 && info.durationUnit==nil && info.recordingEdition==nil)
        precondition(info.album?.id != nil && info.artists?[0].id==nil)
        precondition(info.unknownReasons["artists[0].id"]=="upstream_null")
        precondition(info.originCoverCategory=="original_performer" && info.legacyRecordingVersionSemantics=="origin_cover_classification")
        let encoded=try JSONSerialization.jsonObject(with:JSONEncoder().encode(song)) as! [String:Any]
        let output=(encoded["metadata"] as! [String:Any])["business_info"] as! [String:Any]
        let original=(((raw["payload"] as! [String:Any])["songs"] as! [[String:Any]])[0]["metadata"] as! [String:Any])["business_info"] as! [String:Any]
        precondition(NSDictionary(dictionary:output).isEqual(to:original),"native_business_projection_changed")
        let inputRow = ((raw["payload"] as! [String: Any])["songs"] as! [[String: Any]])[0]
        precondition(NSDictionary(dictionary: encoded["provider_record"] as! [String: Any]).isEqual(to: inputRow["provider_record"] as! [String: Any]), "raw_provider_json_changed")
        var badRecord = raw, badPayload = badRecord["payload"] as! [String: Any], badRows = badPayload["songs"] as! [[String: Any]], record = badRows[0]["provider_record"] as! [String: Any]
        record["fields"] = ["extra": ["accessToken": "DO_NOT_LEAK"]]; badRows[0]["provider_record"] = record; badPayload["songs"] = badRows; badRecord["payload"] = badPayload
        do { _ = try MusicReadProtocol.decode(badRecord, for: request); preconditionFailure("nested_auth_field_accepted") } catch {}
        var maximal=raw,p=raw["payload"] as! [String:Any];p["songs"]=[fixture["worst"]!];maximal["payload"]=p
        let high=try MusicReadProtocol.decode(maximal,for:request);precondition(high.payload!.songs![0].metadata.businessInfo!.unknownReasons.count>70)
        let failure=try MusicReadProtocol.decode(fixture["failure"] as! [String:Any],for:request,correlationID:UUID(uuidString:"00000000-0000-4000-8000-000000000002"))
        precondition(failure.failure?.reason == .providerResourceMissing && failure.failure?.providerStatus?.classification=="resource_missing")
        func rejected(_ change:([String:Any])->[String:Any]) {
            var bad=raw,payload=bad["payload"] as! [String:Any],rows=payload["songs"] as! [[String:Any]],meta=rows[0]["metadata"] as! [String:Any]
            meta["business_info"]=change(original);rows[0]["metadata"]=meta;payload["songs"]=rows;bad["payload"]=payload
            do {_=try MusicReadProtocol.decode(bad,for:request);preconditionFailure("invalid_business_accepted")}catch{}
        }
        rejected{var r=$0;r["accessToken"]="DO_NOT_LEAK";return r}
        rejected{var r=$0;r["duration_unit"]="milliseconds";return r}
        rejected{var r=$0;r["recording_edition"]="1932 original";return r}
        rejected{var r=$0;r["provider_flags"]=["accessToken":"DO_NOT_LEAK"];return r}
        rejected{var r=$0;r["unknown_reasons"]=["duration_unit":"unit_unconfirmed","recording_edition":"not_requested","token":"DO_NOT_LEAK"];return r}
        var legacy=raw,payload=legacy["payload"] as! [String:Any],rows=payload["songs"] as! [[String:Any]],meta=rows[0]["metadata"] as! [String:Any]
        meta.removeValue(forKey:"business_info");rows[0]["metadata"]=meta;payload["songs"]=rows;legacy["payload"]=payload
        let old=try MusicReadProtocol.decode(legacy,for:request)
        precondition(old.payload!.songs![0].metadata.businessInfo==nil)
        print("{\"status\":\"PASS\",\"business_roundtrip_unchanged\":true,\"legacy_accepted\":true,\"unsupported_semantics_rejected\":true}")
    }
}
