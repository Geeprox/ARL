import Foundation

struct MessagesProductReplyV2: Sendable {
    let core: MessagesProductReply
    let authority: MessagesNativeAuthorityV2?
    static func decode(_ raw: Data, for request: OnboardingRequest) throws -> Self {
        var root = try MessagesJSON.decode(raw).value
        guard MessagesNativeIO.integer(root["schema_version"]) == 2 else { throw MessagesTransportFault("protocol_upgrade_required") }
        var authority: MessagesNativeAuthorityV2?
        if let value = root.removeValue(forKey: "authority") {
            let bytes = try JSONSerialization.data(withJSONObject: value)
            let decoded = try JSONDecoder().decode(MessagesNativeAuthorityV2.self, from: bytes)
            try decoded.validate(value); authority = decoded
        }
        root["schema_version"] = 1
        let core = try MessagesProductReply.decode(MessagesJSON(root).data, for: request)
        guard !core.ok || authority != nil else { throw MessagesTransportFault("invalid_response") }
        return Self(core: core, authority: authority)
    }
}
