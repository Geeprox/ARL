import Foundation
private func require(_ ok:Bool,_ label:String)throws {if !ok{throw ReviewFault(label)}}
@main enum MioCatalogNotificationTests {
    static func main() throws {
        let initReply=try MioReadOwnerAdapter.respond(["jsonrpc":"2.0","id":1,"method":"initialize","params":[:]],ownerCall:{_,_ in throw OwnerReadFault.unavailable})
        let initResult=initReply["result"] as! [String:Any]
        try require(((initResult["capabilities"] as! [String:Any])["tools"] as! [String:Any])["listChanged"] as? Bool==true,"listChanged_missing")
        let ping:[String:Any]=["jsonrpc":"2.0","id":2,"method":"tools/call","params":["name":"mio_tunnel_ping","arguments":[:]]]
        let publication=MioCatalogPublicationEvidence()
        let notice=publication.pendingListChanged(request:ping)!
        try require(notice["method"] as? String=="notifications/tools/list_changed" && notice["id"]==nil,"notice_shape")
        publication.recordListChangedSent()
        try require(publication.pendingListChanged(request:ping)==nil,"notice_repeated")
        let listRequest:[String:Any]=["jsonrpc":"2.0","id":3,"method":"tools/list"]
        let list=try MioReadOwnerAdapter.respond(listRequest,ownerCall:{_,_ in throw OwnerReadFault.unavailable})
        let tools=(list["result"] as! [String:Any])["tools"] as! [[String:Any]]
        try require(tools.count==77,"catalog_changed")
        let fresh=MioCatalogPublicationEvidence();fresh.recordSent(request:listRequest,response:list)
        try require(fresh.pendingListChanged(request:ping)==nil,"notice_after_catalog")
        let ordinary=MioCatalogPublicationEvidence()
        try require(ordinary.pendingListChanged(request:listRequest)==nil,"notice_on_wrong_method")
        let request:[String:Any]=["jsonrpc":"2.0","id":"exact-1","method":"tools/call"]
        let notification=try jsonBytes(notice)
        let large=Data(("{\"jsonrpc\":\"2.0\",\"id\":\"exact-1\",\"result\":{\"raw\":9007199254740993,\"text\":\""+String(repeating:"z",count:1_200_000)+"\"}}").utf8)
        var input=[notification,large],output:[Data]=[]
        try forwardMioGatewayReply(request:request,readReply:{input.isEmpty ? nil:input.removeFirst()},writeReply:{output.append($0)})
        try require(output==[notification,large]&&input.isEmpty,"notification_dropped_or_response_changed")
        var nested:Any="leaf"
        for _ in 0..<40{nested=["nested":nested]}
        let deep=try jsonBytes(["jsonrpc":"2.0","id":"exact-1","result":nested])
        input=[deep];output=[]
        try forwardMioGatewayReply(request:request,readReply:{input.isEmpty ? nil:input.removeFirst()},writeReply:{output.append($0)})
        try require(output==[deep],"response_depth_narrowed")
        let bads:[[Data]]=[
            [notification],
            [try jsonBytes(["jsonrpc":"2.0","id":"different","result":[:]])],
            [try jsonBytes(["jsonrpc":"2.0","method":"notifications/unknown"])],
            [try jsonBytes(["jsonrpc":"2.0","method":"notifications/tools/list_changed","id":4])]
        ]
        for bad in bads {
            input=bad;output=[]
            do{try forwardMioGatewayReply(request:request,readReply:{input.isEmpty ? nil:input.removeFirst()},writeReply:{output.append($0)});throw OwnerReadFault.invalid}
            catch is ReviewFault {}
        }
        input=[try jsonBytes(["jsonrpc":"2.0","id":NSNull(),"error":["code":-32600,"message":"Invalid request"]])];output=[]
        try forwardMioGatewayReply(request:request,readReply:{input.isEmpty ? nil:input.removeFirst()},writeReply:{output.append($0)})
        try require(output.count==1,"protocol_error_not_forwarded")
        do{try forwardMioGatewayReply(request:request,readReply:{throw ReviewFault("transport_deadline")},writeReply:{_ in});throw OwnerReadFault.invalid}
        catch let fault as ReviewFault {try require(fault.code=="transport_deadline","deadline_replaced")}
        let report:[String:Any]=["status":"PASS","catalog_count":77,"catalog_sha256":digest(try jsonBytes(tools)),"large_response_bytes":large.count,"bytes_preserved":true,"integer_precision_preserved":true,"deep_response_accepted":true,"notice_once":true,"already_listed_suppresses_notice":true,"malformed_id_or_notice_rejected":true,"truncated_stream_rejected":true,"deadline_preserved":true,"real_network":false,"real_credentials":false]
        try jsonBytes(report).write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
        print(String(decoding:try jsonBytes(report),as:UTF8.self))
    }
}

