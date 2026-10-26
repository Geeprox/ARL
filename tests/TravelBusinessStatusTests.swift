import Foundation

private func rpc(_ inner: [String: Any], isError: Bool = false) -> [String: Any] {
    ["jsonrpc":"2.0", "id":1, "result":["isError":isError, "structuredContent":inner]]
}
@main enum TravelBusinessStatusTests {
    static func main() throws {
        let request = try TravelReadRequest(toolName:"mio_flyai_search_hotel", argumentsJSON:Data("{\"dest_name\":\"Example city\"}".utf8))
        let projection = TravelReadProjection(secret:"SYNTHETIC-CREDENTIAL-NOT-REAL")
        func check(_ inner: [String: Any], expected: TravelReadState, isError: Bool = false) throws {
            let envelope = rpc(inner, isError:isError)
            let result = try projection.project(.init(status:200, contentType:"application/json", body:try JSONSerialization.data(withJSONObject:envelope)), request:request)
            precondition(result.state == expected, "explicit_business_state_mismatch")
            let restored = try JSONSerialization.jsonObject(with:JSONEncoder().encode(result.payload)) as! [String:Any]
            precondition(NSDictionary(dictionary:restored).isEqual(to:inner), "business_response_changed")
        }
        let success: [String:Any] = ["status":0, "error":NSNull(), "data":["itemList":[]]]
        try check(success, expected:.succeeded)
        _ = try FlyAIMCPResponse.business(rpc(success))
        // An explicit success does not impose the credential probe's old DTO.
        try check(["status":0, "error":NSNull(), "data":["futureShape":["entries":[]]]], expected:.succeeded)
        let errors: [(String, ConnectionState, TravelReadState)] = [
            ("UNAUTHORIZED", .invalidOrExpired, .invalidOrExpired),
            ("QUOTA_EXCEEDED", .quotaExceeded, .quotaExceeded),
            ("SERVICE_UNAVAILABLE", .vendorUnavailable, .vendorUnavailable)
        ]
        for (code, connectionState, readState) in errors {
            let inner: [String:Any] = ["status":0, "code":code, "data":["itemList":[]]]
            try check(inner, expected:readState)
            do { _ = try FlyAIMCPResponse.business(rpc(inner)); preconditionFailure("known_error_accepted") }
            catch let error as FlyAIResponseFailure { precondition(error.state == connectionState) }
        }
        // Preserve the existing classifier's error/code/success/isError/status precedence.
        try check(["status":0, "code":"UNAUTHORIZED", "error":["code":"FORBIDDEN"], "data":["itemList":[]]], expected:.permissionDenied)
        try check(["status":0, "success":false, "data":["itemList":[]]], expected:.providerRejected)
        try check(["status":0, "data":["itemList":[]]], expected:.providerRejected, isError:true)
        try check(["status":429, "data":["itemList":[]]], expected:.rateLimited)
        print("{\"status\":\"PASS\",\"null_error_success\":true,\"known_error_codes\":3,\"existing_status_precedence\":true,\"evolving_data_shape_preserved\":true,\"raw_payload_unchanged\":true,\"real_provider_calls\":0,\"real_credentials_read\":false}")
    }
}
