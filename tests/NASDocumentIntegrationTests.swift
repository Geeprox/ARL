import Foundation
import ARLCredentialOnboarding

@MainActor @main enum NASDocumentIntegrationTests {
    enum Failure:Error {case assertion(String)}
    static var checks=0
    static func expect(_ c:@autoclosure ()throws->Bool,_ m:String)throws {checks+=1;if try !c(){throw Failure.assertion(m)}}
    static func bytes(_ value:Any)throws->Data{try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys,.withoutEscapingSlashes])}
    static func object(_ value:Data)throws->[String:Any]{try JSONSerialization.jsonObject(with:value) as! [String:Any]}
    static func main()async throws {
        let fixtures=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))) as! [[String:Any]]
        let tool="mio_nas_read_document"
        let catalog=try MioReadOwnerAdapter.respond(["jsonrpc":"2.0","id":1,"method":"tools/list"])
        let tools=(catalog["result"] as! [String:Any])["tools"] as! [[String:Any]]
        try validateMioPublishedDescriptors(tools)
        try expect(true,"actual publication schema validator accepts extended catalogue")
        let names=tools.compactMap{$0["name"] as? String}
        try expect(names.filter{$0==tool}.count==1,"document tool published once through actual registry")
        for name in ["mio_nas_read_text","mio_nas_download","mio_nas_transfer_read"] {
            try expect(names.contains(name),"existing UTF8/raw download tools remain")
        }
        try expect(!names.contains(where:{$0.lowercased().contains("codex") || $0.lowercased().contains("laya")}),"no model execution Mio entry")
        for row in fixtures {
            let args=row["arguments"] as! [String:Any],reply=row["reply"] as! [String:Any]
            let input=try bytes(args),output=try bytes(reply)
            let native=try NASFileRequest(tool:tool,argumentsJSON:input)
            try expect(try bytes(object(native.wireJSON))==bytes(row["wire"]!),"SDK emits exact private-host wire")
            let request=try NASCapability.request(tool:tool,argumentsJSON:input)
            try expect(!request.mayRestoreSavedScope,"document read never reconnects or restores scope")
            var connects=0,calls=0,records=0
            let executor=NASFileExecutor(port:.init(allowed:{true},connectSavedScope:{connects+=1},consume:{name,data in
                calls+=1;try expect(name==tool && data==input,"exact input at original credential consumer");return output
            },record:{name,_,data,_ in records+=1;try expect(name==tool && data==input,"existing journal receives exact input")}))
            let actual=try await executor.execute(tool:tool,argumentsJSON:input,callID:UUID())
            try expect(actual==output && connects==0 && calls==1 && records==2,"executor retains actual host bytes")
            let mcp:[String:Any]=["jsonrpc":"2.0","id":2,"method":"tools/call","params":["name":tool,"arguments":args]]
            let published=try MioReadOwnerAdapter.respond(mcp,ownerCall:{name,data in
                try expect(name==tool && data==input,"actual Mio owner bridge input");return actual
            })
            let result=published["result"] as! [String:Any]
            let failed=reply["state"] as? String=="failed"
            try expect(result["isError"] as? Bool==failed,"finite parser error flag retained")
            try expect(try bytes(result["structuredContent"]!)==output,"no lost parser text, units, provenance or error")
            let text=(result["content"] as! [[String:Any]])[0]["text"] as! String
            try expect(try bytes(object(Data(text.utf8)))==output,"MCP text matches structured content")
            if failed {
                try expect((reply["error"] as? [String:Any])?["code"] as? String=="invalid_pdf","original native parser error")
                continue
            }
            try expect(reply["format"] as? String==row["format"] as? String,"each real format traverses response bridge")
            for field in ["connection_epoch","config_generation","revision","source_size"] {
                var wrong=reply
                if field=="config_generation" {wrong[field]=2}
                else if field=="source_size" {wrong[field]=0}
                else {wrong[field]=String(repeating:"f",count:field=="connection_epoch" ? 32:64)}
                let refused=try MioReadOwnerAdapter.respond(mcp,ownerCall:{_,_ in try bytes(wrong)})
                try expect((refused["result"] as? [String:Any])?["isError"] as? Bool==true,"changed object/fence rejected")
            }
            var malformed=args;malformed["root"]="other"
            do {_=try await executor.execute(tool:tool,argumentsJSON:bytes(malformed),callID:UUID());throw Failure.assertion("root override accepted")}
            catch is Failure {throw Failure.assertion("root override accepted")}
            catch {}
            try expect(calls==1,"malformed target causes zero extra consumer calls")
        }
        print("PASS \(checks) four-format SDK/owner/Mio integration checks; actual Python host/parser DTOs, synthetic SMB only")
    }
}
