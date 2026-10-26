import Foundation
import Darwin
import CryptoKit

enum TestFailure: Error { case failed(String) }
@MainActor @main enum MioAttachmentInspectionTests {
    static var checks = 0
    static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        checks += 1; if try !condition() { throw TestFailure.failed(message) }
    }
    static func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]) }
    static func main() throws {
        let args=CommandLine.arguments
        let python=URL(fileURLWithPath:args[1]),fixture=args[2],expected=args[3]
        let body=Data("ARL attachment inspection offline receipt: no user files, NAS or network.\n".utf8)
        let sha=SHA256.hash(data:body).map{String(format:"%02x",$0)}.joined()
        let operation="12345678-1234-4234-8234-123456789abc"
        let input:[String:Any] = ["operation_id":operation,"file":["file_id":"file_synthetic",
            "download_url":"https://files.oaiusercontent.com/file_synthetic?sig=DO_NOT_RECORD",
            "file_name":"synthetic.txt","mime_type":"text/plain"]]
        func request(_ value:[String:Any]) -> [String:Any] {
            ["jsonrpc":"2.0","id":7,"method":"tools/call","params":["name":MioAttachmentInspection.name,"arguments":value]]
        }
        func result(_ reply:[String:Any]) throws -> [String:Any] {
            guard let value=reply["result"] as? [String:Any] else {throw TestFailure.failed("missing MCP result")};return value
        }
        func execute(_ mode:String,_ bytes:Data,_ seconds:Double=5,_ cancelled:()->Bool={false}) throws -> Data {
            try MioAttachmentInspection.run(bytes,command:.init(executable:python,arguments:["-I","-B",fixture,mode]),seconds:seconds,cancelled:cancelled)
        }
        let descriptor=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:expected)))
        try expect(try json(MioAttachmentInspection.descriptor)==json(descriptor),"Python canonical descriptor preserved")
        let list=try MioReadOwnerAdapter.respond(["jsonrpc":"2.0","id":1,"method":"tools/list"])
        let tools=(list["result"] as! [String:Any])["tools"] as! [[String:Any]]
        try expect(tools.count==84,"81 preserved plus three reviewed new tools")
        try expect(tools.last?["name"] as? String==MioAttachmentInspection.name,"inspector appended")
        let baseline=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:args[4]))) as! [[String:Any]]
        let additions=NASFileReaderContract.names.union([MioAttachmentInspection.name])
        let preserved=tools.filter{!additions.contains($0["name"] as? String ?? "")}
        try expect(try json(preserved)==json(baseline),"all original81 descriptors byte-equivalent as JSON")
        try validateMioPublishedDescriptors(tools)
        try validateMioPublishedDescriptors(Array(tools.dropLast()))
        var edited=tools;var changed=edited.last!;changed["_meta"]=["openai/fileParams":[]];edited[edited.count-1]=changed
        do {try validateMioPublishedDescriptors(edited);throw TestFailure.failed("changed metadata admitted")}
        catch is ReviewFault {checks+=1}
        var ownerCalls=0,workerCalls=0
        let success=try MioReadOwnerAdapter.respond(request(input),ownerCall:{_,_ in ownerCalls+=1;throw OwnerReadFault.invalid},attachmentCall:{bytes in workerCalls+=1;return try execute("ok",bytes)})
        let value=try result(success),receipt=value["structuredContent"] as! [String:Any]
        try expect(value["isError"] as? Bool==false,"actual Swift->stdin worker->HTTP parser->MCP succeeds")
        try expect(ownerCalls==0 && workerCalls==1,"one ephemeral worker, no owner/business journal")
        try expect(receipt["sha256"] as? String==sha && (receipt["size"] as? NSNumber)?.intValue==body.count,"exact synthetic attachment byte hash/size")
        try expect(OwnerReadWire.falseBoolean(receipt["stored"]) && OwnerReadWire.falseBoolean(receipt["nas_write_performed"]),"no NAS/write/retention claim")
        let text=(value["content"] as! [[String:Any]])[0]["text"] as! String
        try expect(try json(JSONSerialization.jsonObject(with:Data(text.utf8)))==json(receipt),"text and structured exactly equal")
        try expect(!String(decoding:try json(success),as:UTF8.self).contains("DO_NOT_RECORD"),"signed URL absent in MCP receipt")
        let closed=try result(MioReadOwnerAdapter.respond(request(input)))
        try expect(closed["isError"] as? Bool==true,"no default execution without host injection")
        let cancelled=try result(MioReadOwnerAdapter.respond(request(input),cancelled:{true},attachmentCall:{_ in workerCalls+=1;return Data()}))
        try expect(cancelled["isError"] as? Bool==true && workerCalls==1,"cancel before worker means zero effect")
        for malformed in [["file":input["file"]!], ["operation_id":operation], ["operation_id":operation,"file":input["file"]!,"approval":true]] as [[String:Any]] {
            let reply=try result(MioReadOwnerAdapter.respond(request(malformed),attachmentCall:{_ in workerCalls+=1;return Data()}))
            try expect(reply["isError"] as? Bool==true && workerCalls==1,"malformed request no worker")
        }
        for (field,bad) in [("operation_id","00000000-0000-4000-8000-000000000000" as Any),("sha256",sha+"\n"),("size",true),("stored",true),("file_id","file_other")] {
            var wrong=receipt;wrong[field]=bad
            let reply=try result(MioReadOwnerAdapter.respond(request(input),attachmentCall:{_ in try json(["ok":true,"result":wrong])}))
            try expect(reply["isError"] as? Bool==true,"wrong operation/hash/size/retention/file rejected")
        }
        var extra=receipt;extra["download_url"]="DO_NOT_RECORD"
        let extraReply=try MioReadOwnerAdapter.respond(request(input),attachmentCall:{_ in try json(["ok":true,"result":extra])})
        try expect(!String(decoding:try json(extraReply),as:UTF8.self).contains("DO_NOT_RECORD"),"unknown URL output never forwarded")
        var raw=try json(input);raw.append(10)
        for mode in ["oversize","nonzero"] {
            do {_=try execute(mode,raw);throw TestFailure.failed("bad child accepted")}
            catch is OwnerReadFault {checks+=1}
        }
        let start=OwnerReadSocket.now
        do {_=try execute("hang",raw,0.15);throw TestFailure.failed("watchdog missed")}
        catch OwnerReadFault.deadline {checks+=1}
        try expect(OwnerReadSocket.now-start<3,"outer deadline bounds DNS-like blocked worker and cleanup")
        let cancelledAt=OwnerReadSocket.now+0.08
        do {_=try execute("hang",raw,5,{OwnerReadSocket.now>cancelledAt});throw TestFailure.failed("cancellation missed")}
        catch OwnerReadFault.cancelled {checks+=1}
        print("PASS \(checks) actual Mio/worker synthetic checks; no live network, NAS or provider")
    }
}
