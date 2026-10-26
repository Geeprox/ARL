import Foundation

@main enum TaobaoDataEnvelopeTests {
    static func main() throws {
        var passed: [String] = []
        func bytes(_ value: [String:Any]) throws -> Data { try OwnerReadWire.encode(value,limit:524288) }
        func wrap(_ value: [String:Any]) throws -> [String:Any] {
            ["content":[["type":"text","text":String(decoding:try bytes(value),as:UTF8.self)]]]
        }
        func check(_ value: Bool,_ label: String) throws {
            guard value else { throw NSError(domain:"TaobaoDataEnvelope",code:1,userInfo:[NSLocalizedDescriptionKey:label]) }
            passed.append(label)
        }
        let products:[[String:Any]]=[["title":"Synthetic product","cookie":"synthetic-private","price":NSNull()]]
        let cases:[(String,[String:Any],TaobaoFault)]=[
            ("success_false",["success":false],.protocolError),
            ("error_object",["error":["code":"UPSTREAM_FAILURE"]],.protocolError),
            ("login_code",["code":"LOGIN_REQUIRED"],.notLoggedIn),
            ("login_error",["error":["code":"NOT_LOGGED_IN"]],.notLoggedIn),
            ("session_expired",["code":"SESSION_EXPIRED"],.notLoggedIn),
            ("is_error",["isError":true],.privacyHeld),
            ("invalid_string_marker",["isError":"false"],.protocolError),
            ("invalid_numeric_marker",["isError":0],.protocolError)]
        for (label,markers,expected) in cases {
            var leaf=markers;leaf["products"]=products
            for extraLayer in [false,true] {
                let data:[String:Any]=extraLayer ? ["success":true,"data":leaf] : leaf
                let raw=try wrap(["success":true,"data":data])
                var rejected:TaobaoFault?
                do { _ = try TaobaoProjection.project(TaobaoProjection.payload(raw),action:"search_products") }
                catch let error as TaobaoFault { rejected=error }
                try check(rejected==expected,label+(extraLayer ? "_nested_data" : "_data"))
            }
        }
        let valid=try wrap(["success":true,"data":["success":true,"isError":false,"products":products]])
        let projected=try TaobaoProjection.project(TaobaoProjection.payload(valid),action:"search_products")
        let text=String(decoding:try bytes(["data":projected]),as:UTF8.self)
        try check(text.contains("Synthetic product") && !text.contains("synthetic-private"),"valid_data_and_private_projection")
        let array=projected as! [[String:Any]]
        try check(array.count==1 && array[0]["price"] is NSNull,"valid_data_unknown_price_preserved")
        var boundary:[String:Any]=["products":products]
        for _ in 0..<3 { boundary=["data":boundary] }
        try check((try TaobaoProjection.payload(wrap(boundary)))["products"] != nil,"four_layers_accepted")
        let tooDeep=try wrap(["data":boundary])
        var depthRejected=false
        do { _ = try TaobaoProjection.payload(tooDeep) } catch let error as TaobaoFault { depthRejected=error == .privacyHeld }
        try check(depthRejected,"five_layers_rejected")
        let outer=try wrap(["isError":true,"data":["success":true,"products":products]])
        var outerRejected=false
        do { _ = try TaobaoProjection.payload(outer) } catch let error as TaobaoFault { outerRejected=error == .privacyHeld }
        try check(outerRejected,"outer_failure_survives_data_success")
        let nestedLogin=try wrap(["isError":true,"data":["error":["code":"LOGIN_REQUIRED"]]])
        var loginClassified=false
        do { _ = try TaobaoProjection.payload(nestedLogin) } catch let error as TaobaoFault { loginClassified=error == .notLoggedIn }
        try check(loginClassified,"login_classification_survives_outer_error")
        let tooLarge=try wrap(["data":["products":products,"padding":String(repeating:"x",count:262144)]])
        var sizeRejected=false
        do { _ = try TaobaoProjection.payload(tooLarge) } catch let error as TaobaoFault { sizeRejected=error == .privacyHeld }
        try check(sizeRejected,"existing_text_byte_limit_preserved")
        print(String(decoding:try bytes(["status":"PASS","checks":passed.count,"passed":passed,
            "real_network_calls":0,"cart_writes":0,"credential_reads":0]),as:UTF8.self))
    }
}
