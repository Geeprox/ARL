import Foundation

/// Actual native adapter/resource checks. Injected owner must never be entered
/// by metadata or by any rejected resource request; no provider/TCC/network.
@main enum MioNASWidgetTests {
    static func main() throws {
        var ownerCalls = 0
        let owner: (String,Data)throws->Data = { _,_ in
            ownerCalls += 1
            throw OwnerReadFault.unavailable
        }
        func response(_ method:String,_ params:[String:Any]?=nil)throws->[String:Any] {
            var request:[String:Any] = ["jsonrpc":"2.0","id":1,"method":method]
            if let params { request["params"] = params }
            return try MioReadOwnerAdapter.respond(request,ownerCall:owner)
        }
        func result(_ method:String,_ params:[String:Any]?=nil)throws->[String:Any] {
            let value = try response(method,params)
            precondition(value["error"] == nil)
            return value["result"] as! [String:Any]
        }
        var checks=0
        let initialized=try result("initialize",["protocolVersion":"2025-06-18","capabilities":[:],"clientInfo":["name":"synthetic-widget-check","version":"1"]])
        let capabilities=initialized["capabilities"] as! [String:Any]
        precondition(capabilities["resources"] is [String:Any])
        precondition((capabilities["tools"] as? [String:Any])?["listChanged"] as? Bool == true)
        checks += 1

        let listing=try result("resources/list")
        let resources=listing["resources"] as! [[String:Any]]
        precondition(resources.count==1)
        precondition(resources[0]["uri"] as? String==NASDownloadWidget.uri)
        precondition(resources[0]["mimeType"] as? String=="text/html;profile=mcp-app")
        checks += 1

        let loaded=try result("resources/read",["uri":NASDownloadWidget.uri])
        let contents=loaded["contents"] as! [[String:Any]]
        precondition(contents.count==1 && contents[0]["uri"] as? String==NASDownloadWidget.uri)
        precondition(contents[0]["mimeType"] as? String==NASDownloadWidget.mimeType)
        let html=contents[0]["text"] as! String
        precondition(html==NASDownloadWidget.html)
        precondition(html.contains("ui/initialize") && html.contains("ui/notifications/initialized"))
        precondition(html.contains("platform.uploadFile(file, {library:false})"))
        precondition(html.contains("platform.getFileDownloadUrl({fileId:this.fileId})"))
        precondition(!html.contains("<script src=") && !html.contains("http://localhost"))
        let resourceMeta=contents[0]["_meta"] as! [String:Any]
        let csp=(resourceMeta["ui"] as! [String:Any])["csp"] as! [String:Any]
        precondition((csp["connectDomains"] as? [String])==[] && (csp["resourceDomains"] as? [String])==[])
        checks += 1

        let tools=(try result("tools/list"))["tools"] as! [[String:Any]]
        try validateMioPublishedDescriptors(tools)
        precondition(tools.contains{$0["name"] as? String=="mio_nas_read_document"})
        let download=tools.first{$0["name"] as? String=="mio_nas_download"}!
        let downloadMeta=download["_meta"] as! [String:Any]
        precondition((downloadMeta["ui"] as? [String:Any])?["resourceUri"] as? String==NASDownloadWidget.uri)
        precondition(downloadMeta["openai/outputTemplate"] as? String==NASDownloadWidget.uri)
        let transfer=tools.first{$0["name"] as? String=="mio_nas_transfer_read"}!
        let transferMeta=transfer["_meta"] as! [String:Any]
        precondition((transferMeta["ui"] as? [String:Any])?["visibility"] as? [String]==["model","app"])
        precondition(transferMeta["openai/widgetAccessible"] as? Bool==true)
        let input=transfer["inputSchema"] as! [String:Any]
        precondition((input["properties"] as! [String:Any])["root"]==nil)
        precondition((input["properties"] as! [String:Any])["file_id"]==nil)
        checks += 1

        let invalids:[(String,[String:Any])] = [
            ("resources/list",["cursor":"unknown"]),
            ("resources/read",[:]),
            ("resources/read",["uri":"ui://arl/unknown.html"]),
            ("resources/read",["uri":NASDownloadWidget.uri+"?path=/tmp/private"]),
            ("resources/read",["uri":"file:///tmp/private"]),
            ("resources/read",["uri":"https://example.invalid/private"]),
            ("resources/read",["uri":NASDownloadWidget.uri,"path":"/tmp/private"]),
            ("resources/read",["uri":NASDownloadWidget.uri,"approved":true]),
            ("resources/read",["uri":NASDownloadWidget.uri,"_meta":true])
        ]
        for (method,params) in invalids {
            let error=(try response(method,params))["error"] as! [String:Any]
            precondition(error["code"] as? Int == -32602)
            precondition(ownerCalls==0)
            checks += 1
        }
        // Reserved metadata is inert and never becomes a path/grant/owner call.
        _=try result("resources/read",["uri":NASDownloadWidget.uri,"_meta":["approved":true,"owner":"untrusted"]])
        precondition(ownerCalls==0)
        checks += 1
        let bytes=try JSONSerialization.data(withJSONObject:["status":"PASS","checks":checks,"owner_calls":ownerCalls,"provider_calls":0,"real_platform_uploads":0],options:[.sortedKeys])
        print(String(decoding:bytes,as:UTF8.self))
    }
}
