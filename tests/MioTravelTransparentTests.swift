import Foundation
@main enum MioTravelTransparentTests {
    static func main() throws {
        let base = try MioReadCatalog.descriptors(); try validateMioBaseDescriptors(base)
        var bad = base; bad[0]["description"] = "changed"
        do { try validateMioBaseDescriptors(bad); preconditionFailure("modified_travel_catalog_accepted") } catch {}
        let list = try MioReadOwnerAdapter.respond(["jsonrpc":"2.0", "id":1, "method":"tools/list"], ownerCall:{ _, _ in throw OwnerReadFault.unavailable })
        try validateMioPublishedDescriptors((list["result"] as! [String: Any])["tools"] as! [[String: Any]])
        let fixture = try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))) as! [String:Any]
        var wireSizes: [Int] = []
        for item in fixture["cases"] as! [[String:Any]] {
            let name = item["tool"] as! String
            var raw = item["result"] as! [String: Any]
            if name == "mio_maps_weather" {
                var nested: [String: Any] = ["leaf":"preserved"]
                for _ in 0..<12 { nested = ["child":nested] }
                var payload = raw["payload"] as! [String: Any]; payload["optional_deep_object"] = nested; raw["payload"] = payload
            }
            let payload = try OwnerReadWire.encode(raw,limit:OwnerReadWire.responseLimit-1024)
            let request = OwnerReadRequest(generation:UUID().uuidString,callID:UUID().uuidString,tool:name,argumentsJSON:Data("{}".utf8))
            let wire = try OwnerReadWire.response(request,payload:payload,error:nil);wireSizes.append(wire.count)
            let restored = try OwnerReadWire.payload(wire,request:request)
            let reply = try MioReadOwnerAdapter.respond(["jsonrpc":"2.0", "id":2, "method":"tools/call", "params":["name":name,"arguments":item["arguments"]!]], ownerCall:{_,_ in restored})
            let result = reply["result"] as! [String:Any], structured = result["structuredContent"] as! [String:Any]
            let text = (result["content"] as! [[String:Any]])[0]["text"] as! String
            let parsed = try OwnerReadJSON.object(Data(text.utf8),limit:OwnerReadWire.responseLimit,maximumDepth:32)
            precondition(NSDictionary(dictionary:parsed).isEqual(to:structured) && NSDictionary(dictionary:raw).isEqual(to:structured),"travel_result_changed")
        }
        var nested: [String: Any] = ["leaf":"value"]
        for _ in 0..<20 { nested = ["child":nested] }
        let inbound = try OwnerReadWire.encode(nested, limit:OwnerReadWire.requestLimit)
        do { _ = try OwnerReadJSON.object(inbound, limit:OwnerReadWire.requestLimit); preconditionFailure("inbound_depth_guard_widened") } catch {}
        let error = try MioReadOwnerAdapter.respond(["jsonrpc":"2.0","id":3,"method":"tools/call","params":["name":"mio_maps_geo","arguments":["address":"Example"]]],ownerCall:{_,_ in throw OwnerReadFault.unconfigured})
        let result = error["result"] as! [String:Any];precondition(result["structuredContent"] != nil && result["isError"] as? Bool == true)
        print(String(decoding:try JSONSerialization.data(withJSONObject:["status":"PASS","actual_catalog_consumer_owner_wire_mio":true,"wire_bytes":wireSizes,"text_equals_structured":true]),as:UTF8.self))
    }
}
