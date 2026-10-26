import Foundation
private enum CutoverFailure:Error {case assertion(String)}
@MainActor @main enum MioPublicationCutoverTests {
    static var checks=0
    static func check(_ ok:Bool,_ name:String)throws {if !ok{throw CutoverFailure.assertion(name)};checks+=1}
    static func main()throws {
        var ownerCalls=0
        let deny:(String,Data)throws->Data={_,_ in ownerCalls+=1;throw OwnerReadFault.unavailable}
        let response=try MioReadOwnerAdapter.respond(["jsonrpc":"2.0","id":1,"method":"tools/list","params":[:]],ownerCall:deny)
        let tools=(response["result"] as! [String:Any])["tools"] as! [[String:Any]]
        try check(ownerCalls==0,"catalog does not contact owner")
        try validateMioPublishedDescriptors(tools)
        try check(tools.count==29,"preserved20 music4 reminders2 NAS3")
        try check(!tools.contains{($0["name"] as? String ?? "").contains("taobao")},"no Taobao descriptor")
        try check(try jsonBytes(Array(tools.prefix(20)))==jsonBytes(MioReadCatalog.descriptors()),"base20 unchanged")
        for name in ["mio_taobao_status","mio_taobao_search","mio_taobao_cart_add","taobao.search","codex.text"] {
            let reply=try MioReadOwnerAdapter.respond(["jsonrpc":"2.0","id":2,"method":"tools/call","params":["name":name,"arguments":[:]]],ownerCall:deny)
            try check((reply["result"] as? [String:Any])?["isError"] as? Bool == true,"retired/unpublished tool rejected")
        }
        try check(ownerCalls==0,"unpublished tools never enter owner")
        var forged=tools;forged.append(["name":"mio_taobao_search","inputSchema":["type":"object"]])
        do {try validateMioPublishedDescriptors(forged);throw CutoverFailure.assertion("forged published catalog admitted")}
        catch is ReviewFault {checks+=1}
        print("{\"status\":\"PASS\",\"checks\":\(checks),\"owner_calls\":0,\"private_data_read\":false}")
    }
}
