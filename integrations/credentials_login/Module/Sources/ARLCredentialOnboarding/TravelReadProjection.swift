import Foundation

struct TravelReadProjectionFailure: Error { let state: TravelReadState; var diagnostic: TravelProviderDiagnostic? = nil }
struct TravelProjectedResponse: Sendable {
    let payload: TravelReadPayload
    let state: TravelReadState
    let diagnostic: TravelProviderDiagnostic?
    let httpStatus: Int
    let responseKind: String
    let omittedAuthenticationFields: [String]
}

/// A business JSON boundary, not a travel interpretation or field whitelist.
struct TravelReadProjection {
    let secret: String
    var additionalSecrets: [String] = []
    private func fail(_ state: TravelReadState = .protocolFailure, diagnostic: TravelProviderDiagnostic? = nil) -> TravelReadProjectionFailure { .init(state: state, diagnostic: diagnostic) }
    private func httpState(_ status: Int) -> TravelReadState? {
        switch status {
        case 200...299: nil
        case 401: .invalidOrExpired
        case 403: .permissionDenied
        case 429: .rateLimited
        case 500...599: .vendorUnavailable
        default: .providerRejected
        }
    }
    private func business(_ root: Any) throws -> (MusicProviderValue, [String]) {
        var omitted = Set<String>()
        let secrets = ([secret] + additionalSecrets).filter { !$0.isEmpty }.flatMap {
            [$0, Data($0.utf8).base64EncodedString(), $0.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $0]
        }
        func knownSecret(_ text: String) -> Bool {
            let decoded = text.removingPercentEncoding ?? text
            return secrets.contains { text.contains($0) || decoded.contains($0) }
        }
        func copy(_ value: Any, context: Bool = false) -> Any {
            if let object = value as? [String: Any] {
                var result: [String: Any] = [:]
                for (key, item) in object {
                    if knownSecret(key) { omitted.insert("known_credential_material"); continue }
                    if ProviderBusinessPolicy.isAuthenticationKey(key, context: context) {
                        let normalized = ProviderBusinessPolicy.normalized(key)
                        omitted.insert(ProviderBusinessPolicy.authenticationKeys.contains(normalized) ? normalized : "authentication_context"); continue
                    }
                    if let text = item as? String, knownSecret(text) || ProviderBusinessPolicy.authenticationURL(text) {
                        omitted.insert(knownSecret(text) ? "known_credential_material" : "authenticated_url"); continue
                    }
                    result[key] = copy(item, context: context || ProviderBusinessPolicy.authenticationContexts.contains(ProviderBusinessPolicy.normalized(key)))
                }
                return result
            }
            if let array = value as? [Any] { return array.map { copy($0, context: context) } }
            if let text = value as? String, knownSecret(text) || ProviderBusinessPolicy.authenticationURL(text) {
                omitted.insert(knownSecret(text) ? "known_credential_material" : "authenticated_url"); return NSNull()
            }
            return value
        }
        let safe = copy(root)
        let data = try JSONSerialization.data(withJSONObject: safe, options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes])
        return (try JSONDecoder().decode(MusicProviderValue.self, from: data), omitted.sorted())
    }
    func parse(_ response: ProbeResponse, request: TravelReadRequest) throws -> TravelReadPayload { try project(response, request: request).payload }
    func project(_ response: ProbeResponse, request: TravelReadRequest) throws -> TravelProjectedResponse {
        guard response.body.count <= TravelReadLimits.providerBytes else { throw fail(.responseTooLarge) }
        let media = response.contentType.split(separator: ";", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces).lowercased()
        let root: Any, state: TravelReadState, diagnostic: TravelProviderDiagnostic?, kind: String
        if request.purpose == .fliggyTravelReadOnly && httpState(response.status) == nil {
            let envelope: [String: Any]
            do { envelope = try FlyAIMCPResponse.envelope(response, requestID: 1, byteLimit: TravelReadLimits.providerBytes) }
            catch let error as FlyAIResponseFailure { throw fail(.protocolFailure, diagnostic: error.diagnostic) }
            root = try FlyAIMCPResponse.business(envelope, byteLimit: TravelReadLimits.providerBytes, requireSuccess: false)
            let structured = (envelope["result"] as? [String: Any])?["structuredContent"] as? [String: Any]
            kind = structured.map { !Set($0.keys).isDisjoint(with: ["status","data","error","code"]) } == true ? "mcp_structured_business_object" : "mcp_text_json_business_object"
            let inner = root as! [String: Any]
            let mcpError = (envelope["result"] as? [String: Any])?["isError"] as? Bool == true
            do {
                try FlyAIMCPResponse.validateBusinessStatus(inner, isError: mcpError)
                state = .succeeded; diagnostic = nil
            } catch let error as FlyAIResponseFailure {
                state = error.state == .protocolFailure ? .providerRejected : .fromConnection(error.state); diagnostic = error.diagnostic
            }
        } else {
            if (media == "application/json" || media?.hasSuffix("+json") == true), let object = try? MusicStrictJSON.value(response.body, limit: TravelReadLimits.providerBytes) { root = object; kind = "provider_json" }
            else if let text = String(data: response.body, encoding: .utf8) { root = text; kind = "provider_text" }
            else { throw fail() }
            if let failure = httpState(response.status) { state = failure; diagnostic = nil }
            else if let object = root as? [String: Any] {
                if request.operation == .bicycling {
                    state = TravelProviderValue.integer(object["errcode"], range: -99999...99999) == 0 ? .succeeded : .providerRejected; diagnostic = nil
                } else if TravelProviderValue.integer(object["status"], range: 0...1) == 1 && TravelProviderValue.integer(object["infocode"], range: 0...99999) == 10000 {
                    state = .succeeded; diagnostic = nil
                } else {
                    let mapped = VendorValidator.parse(response, purpose: .amapMapsWeather)
                    state = mapped.state == .protocolFailure ? .providerRejected : .fromConnection(mapped.state); diagnostic = mapped.diagnostic
                }
            } else { state = .protocolFailure; diagnostic = nil }
        }
        let (payload, omitted) = try business(root)
        return .init(payload: payload, state: state, diagnostic: diagnostic, httpStatus: response.status, responseKind: kind, omittedAuthenticationFields: omitted)
    }
}
