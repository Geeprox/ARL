import Foundation
import ARLCredentialOnboarding

@MainActor @main enum NASReaderIntegrationTests {
    enum Failure:Error {case assertion(String)}
    static var checks=0
    static func expect(_ c:@autoclosure ()throws->Bool,_ m:String)throws {checks+=1;if try !c(){throw Failure.assertion(m)}}
    static func bytes(_ value:Any)throws->Data{try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys,.withoutEscapingSlashes])}
    static func object(_ value:Data)throws->[String:Any]{try JSONSerialization.jsonObject(with:value) as! [String:Any]}
    static func main()async throws {
        let fixtures=try object(Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1])))
        for tool in NASFileReaderContract.names.sorted() {
            let row=fixtures[tool] as! [String:Any],args=row["arguments"] as! [String:Any],reply=row["reply"] as! [String:Any]
            let input=try bytes(args),output=try bytes(reply)
            let native=try NASFileRequest(tool:tool,argumentsJSON:input)
            try expect(try bytes(object(native.wireJSON))==bytes(row["wire"]!),"SDK emits exact host wire")
            let expected=try NASCapability.request(tool:tool,argumentsJSON:input)
            try expect(!expected.mayRestoreSavedScope,"new reads never restore scope")
            var connects=0,calls=0,records=0
            let executor=NASFileExecutor(port:.init(allowed:{true},connectSavedScope:{connects+=1},consume:{name,data in
                calls+=1;try expect(name==tool && data==input,"exact request at original consumer");return output
            },record:{name,_,data,_ in records+=1;try expect(name==tool && data==input,"exact request enters existing journal port")}))
            let actual=try await executor.execute(tool:tool,argumentsJSON:input,callID:UUID())
            try expect(actual==output && connects==0 && calls==1 && records==2,"owner executor preserves full Python host bytes, no reconnect")
            let mcp:[String:Any]=["jsonrpc":"2.0","id":1,"method":"tools/call","params":["name":tool,"arguments":args]]
            let published=try MioReadOwnerAdapter.respond(mcp,ownerCall:{name,data in try expect(name==tool && data==input,"original owner IPC request");return actual})
            let result=published["result"] as! [String:Any]
            try expect(result["isError"] as? Bool==false,"real shared Mio admission accepts exact frozen host DTO")
            let structured=result["structuredContent"] as! [String:Any]
            try expect(try bytes(structured)==output,"no lost fields/bytes/text/partial reasons")
            let text=(result["content"] as! [[String:Any]])[0]["text"] as! String
            try expect(try bytes(object(Data(text.utf8)))==output,"matching MCP text representation")
            for field in ["connection_epoch","config_generation"] {
                var wrong=reply;if field=="connection_epoch" {wrong[field]=String(repeating:"f",count:32)} else {wrong[field]=2}
                let refused=try MioReadOwnerAdapter.respond(mcp,ownerCall:{_,_ in try bytes(wrong)})
                try expect((refused["result"] as? [String:Any])?["isError"] as? Bool==true,"wrong live scope rejected")
            }
            var malformed=args;malformed["root"]="other";var effects=0
            do {_=try await executor.execute(tool:tool,argumentsJSON:bytes(malformed),callID:UUID());throw Failure.assertion("root override accepted")}
            catch is Failure {throw Failure.assertion("root override accepted")}
            catch {effects=calls}
            try expect(effects==1,"invalid target causes zero additional consumer calls")
            if tool=="mio_nas_read_text" {
                try expect(reply["text"] as? String==fixtures["expected_text"] as? String,"strict UTF8 body from actual manager read")
                try expect(OwnerReadWire.falseBoolean(reply["downloadable_artifact"]),"no invented attachment")
            } else {try expect(OwnerReadWire.trueBoolean(reply["recursive"]) && OwnerReadWire.trueBoolean(reply["enumeration_complete"]),"actual recursive filename scan")}
        }
        print("PASS \(checks) SDK/owner/Mio actual frozen Python DTO checks; no live NAS")
    }
}
