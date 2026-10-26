import Foundation
import CryptoKit
import CoreFoundation

protocol CredentialValidator: Sendable { func validate(_ secret: CredentialInput, purpose: CredentialPurpose, deadline: ContinuousClock.Instant) async -> ConnectionTestResult }
extension CredentialValidator {
    func validate(_ secret: CredentialInput, purpose: CredentialPurpose) async -> ConnectionTestResult {
        await validate(secret, purpose: purpose, deadline: ContinuousClock.now.advanced(by: .seconds(10)))
    }
}
public struct FlyAIGatewayProfile: Sendable, CustomStringConvertible, CustomReflectable {
    public var description: String { "FlyAIGatewayProfile(<redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
    public static let profileIdentifier = "flyai-cli-1.0.16-mcp-v7-native-compatibility"
    public static let sourceBundleSHA256 = "194a66eb84094f3d8ee20fac0a2d6cae10a405cd59ac100b7e7880ebc97297da"
    let signingSecret: Data
    let approvedContext: String
    let clientTag: String
    init(signingSecret: Data, approvedContext: String, clientTag: String) throws {
        guard !signingSecret.isEmpty, signingSecret.count <= 2048, !approvedContext.isEmpty, approvedContext.utf8.count <= 8192,
              !clientTag.isEmpty, clientTag.utf8.count <= 128,
              !approvedContext.contains("\r"), !approvedContext.contains("\n"), !clientTag.contains("\r"), !clientTag.contains("\n") else { throw CredentialError.invalidInput }
        self.signingSecret = signingSecret
        self.approvedContext = approvedContext; self.clientTag = clientTag
    }
    /// Fully specified source-derived transport candidate. Native vendor acceptance is tested, never asserted by this factory.
    public static func officialCLI116Compatibility() throws -> FlyAIGatewayProfile {
        try .init(signingSecret: FlyAIProtocolMaterial.signingBytes,
                  approvedContext: FlyAIClientContext.encode(FlyAIClientContext.plaintext(), signingMaterial: FlyAIProtocolMaterial.signingBytes),
                  clientTag: FlyAIProtocolMaterial.clientTag)
    }
}
struct VendorValidator: CredentialValidator {
    let transport: any ProbeTransport
    let flyAIProfile: FlyAIGatewayProfile?
    var validationPurposes: Set<CredentialPurpose> = Set(CredentialPurpose.allCases)
    func validate(_ secret: CredentialInput, purpose: CredentialPurpose, deadline: ContinuousClock.Instant) async -> ConnectionTestResult {
        defer { secret.clear() }
        guard purpose.isTravel else { return .init(.setupRequired) }
        guard secret.purpose == purpose else { return .init(.permissionDenied) }
        guard validationPurposes.contains(purpose) else { return .init(.setupRequired) }
        if purpose == .fliggyTravelReadOnly && flyAIProfile == nil { return .init(.setupRequired) }
        do {
            if purpose == .fliggyTravelReadOnly {
                // Preserve key length, prefix and character classes so a syntax-only rejection is not our evidence.
                guard let control = try negativeControl(secret, purpose: purpose) else { return .init(.credentialUnconfirmed) }
                defer { control.clear() }
                let rejected = try await transport.send(bounded(makeRequest(control, purpose: purpose), deadline: deadline))
                try Task.checkCancellation()
                let negative = Self.parse(rejected, purpose: purpose)
                guard negative.state == .invalidOrExpired || negative.state == .permissionDenied else {
                    return .init([ConnectionState.rateLimited, .vendorUnavailable, .quotaExceeded].contains(negative.state) ? negative.state : .credentialUnconfirmed,
                                 httpStatus: rejected.status, diagnostic: negative.diagnostic ?? .negativeControlNotRejected)
                }
            }
            try Task.checkCancellation()
            let probe = try bounded(makeRequest(secret, purpose: purpose), deadline: deadline)
            let response = try await transport.send(probe)
            try Task.checkCancellation()
            let parsed = Self.parse(response, purpose: purpose)
            if purpose == .fliggyTravelReadOnly, parsed.state == .verified {
                return .init(.verified, at: parsed.checkedAt, evidence: .flyaiDifferentialReadOnlyResponse, httpStatus: parsed.httpStatus)
            }
            return parsed
        } catch is CancellationError { return .init(.cancelled) }
        catch let failure as FlyAIResponseFailure { return .init(failure.state, diagnostic: failure.diagnostic) }
        catch let failure as TransportFailure {
            switch failure {
            case .network: return .init(.networkUnavailable)
            case .timeout: return .init(.timedOut)
            case .cancelled: return .init(.cancelled)
            case .responseLimit, .redirect, .protocolFailure: return .init(.protocolFailure)
            }
        } catch { return .init(.setupRequired) }
    }
    private func negativeControl(_ secret: CredentialInput, purpose: CredentialPurpose) throws -> CredentialInput? {
        var original = try secret.copyBytes(for: purpose)
        defer { original.resetBytes(in: 0..<original.count) }
        var bytes = Array(original)
        defer { for index in bytes.indices { bytes[index] = 0 } }
        let positions = bytes.indices.filter { (48...57).contains(bytes[$0]) || (65...90).contains(bytes[$0]) || (97...122).contains(bytes[$0]) }
        guard positions.count >= 4 else { return nil }
        let prefixEnd = bytes.firstIndex(where: { $0 == 45 || $0 == 95 }) ?? min(4, bytes.count - 1)
        let mutable = positions.filter { $0 > prefixEnd }
        guard mutable.count >= 2 else { return nil }
        let randomness = Array(UUID().uuidString.replacingOccurrences(of: "-", with: "").utf8)
        for (offset, index) in mutable.suffix(16).enumerated() {
            let old = bytes[index]
            let base: UInt8 = (48...57).contains(old) ? 48 : (65...90).contains(old) ? 65 : 97
            let span: UInt8 = base == 48 ? 10 : 26
            var replacement = base + randomness[offset] % span
            if replacement == old { replacement = base + (replacement - base + 1) % span }
            bytes[index] = replacement
        }
        return try CredentialInput(purpose: purpose, data: Data(bytes))
    }
    private func bounded(_ probe: ProbeRequest, deadline: ContinuousClock.Instant) throws -> ProbeRequest {
        let remaining = ContinuousClock.now.duration(to: deadline).components
        let seconds = Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18
        guard seconds > 0 else { throw TransportFailure.timeout }
        var bounded = probe; bounded.remainingSeconds = min(10, seconds); return bounded
    }
    func makeRequest(_ input: CredentialInput, purpose: CredentialPurpose) throws -> ProbeRequest {
        guard purpose.isTravel else { throw CredentialError.wrongPurpose }
        guard let key = String(data: try input.copyBytes(for: purpose), encoding: .utf8) else { throw CredentialError.invalidInput }
        if purpose == .amapMapsWeather {
            var components = URLComponents(string: "https://restapi.amap.com/v3/weather/weatherInfo")!
            components.queryItems = [.init(name: "key", value: key), .init(name: "city", value: "110101"), .init(name: "extensions", value: "base"), .init(name: "output", value: "JSON")]
            var r = URLRequest(url: components.url!); r.httpMethod = "GET"; r.setValue("application/json", forHTTPHeaderField: "Accept")
            return .init(purpose: purpose, request: r)
        }
        guard let profile = flyAIProfile else { throw CredentialError.deploymentNotApproved }
        return try Self.flyAIRequest(key: key, profile: profile, tool: .credentialProbe, arguments: ["query": "杭州景点"])
    }
    static func flyAIRequest(key: String, profile: FlyAIGatewayProfile, tool: FlyAIReadTool, arguments: [String: Any]) throws -> ProbeRequest {
        try flyAIRequest(key: key, profile: profile, tool: tool, argumentsJSON: JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys]))
    }
    static func flyAIRequest(key: String, profile: FlyAIGatewayProfile, tool: FlyAIReadTool, argumentsJSON: Data) throws -> ProbeRequest {
        _ = try MusicStrictJSON.object(argumentsJSON, limit: 16384)
        // Known protocol bytes plus already encoded arguments preserve numeric values.
        let prefix = Data("{\"id\":1,\"jsonrpc\":\"2.0\",\"method\":\"tools/call\",\"params\":{\"arguments\":".utf8)
        let suffix = Data(",\"name\":\"\(tool.rawValue)\"}}".utf8)
        let body = prefix + argumentsJSON + suffix
        var r = URLRequest(url: URL(string: "https://flyai.open.fliggy.com/mcp")!); r.httpMethod = "POST"; r.httpBody = body
        let authorization = "Bearer " + key
        let timestamp = String(Int64(Date().timeIntervalSince1970 * 1000))
        let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let hash: (Data) -> String = { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
        let canonical = ["POST", "/mcp", timestamp, nonce, hash(body), hash(Data(authorization.utf8))].joined(separator: "\n")
        let signature = Data(HMAC<SHA256>.authenticationCode(for: Data(canonical.utf8), using: SymmetricKey(data: profile.signingSecret)))
            .base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        for (name, value) in ["Authorization": authorization, "Content-Type": "application/json", "Accept": "application/json, text/event-stream", "User-Agent": FlyAIClientContext.userAgent, "x-ff-ctx": profile.approvedContext, "x-ttid": profile.clientTag, "x-flyai-sign-ver": "7", "x-flyai-sign-alg": "hmac-sha256", "x-flyai-ts": timestamp, "x-flyai-nonce": nonce, "x-flyai-sign": signature] { r.setValue(value, forHTTPHeaderField: name) }
        return .init(purpose: .fliggyTravelReadOnly, request: r)
    }
    static func parse(_ response: ProbeResponse, purpose: CredentialPurpose) -> ConnectionTestResult {
        let s = response.status
        switch s {
        case 401: return .init(.invalidOrExpired, expiry: .rejectedInvalidOrExpired, httpStatus: s)
        case 403: return .init(.permissionDenied, httpStatus: s)
        case 429: return .init(.rateLimited, httpStatus: s)
        case 500...599: return .init(.vendorUnavailable, httpStatus: s)
        default: guard s == 200 else { return .init(.protocolFailure, httpStatus: s) }
        }
        guard response.body.count <= 65536 else { return .init(.protocolFailure, httpStatus: s) }
        if purpose == .fliggyTravelReadOnly {
            do {
                _ = try FlyAIMCPResponse.business(FlyAIMCPResponse.envelope(response, requestID: 1))
                return .init(.verified, evidence: .flyaiReadOnlyResponse, httpStatus: s)
            } catch let failure as FlyAIResponseFailure {
                return .init(failure.state, expiry: failure.state == .invalidOrExpired ? .rejectedInvalidOrExpired : .unknown,
                             httpStatus: s, diagnostic: failure.diagnostic)
            } catch { return .init(.protocolFailure, httpStatus: s, diagnostic: .malformedMCPResponse) }
        }
        let mediaType = response.contentType.split(separator: ";", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces).lowercased()
        guard purpose == .amapMapsWeather, mediaType == "application/json",
              let object = try? MusicStrictJSON.object(response.body, limit: 65536),
              let code = TravelProviderValue.integer(object["infocode"], range: 0...99999),
              let status = TravelProviderValue.integer(object["status"], range: 0...1) else {
            return .init(.protocolFailure, httpStatus: s, diagnostic: .unrecognizedProviderCode)
        }
        if code == 10000, status == 1, let lives = object["lives"] as? [[String: Any]],
           lives.contains(where: { $0["adcode"] as? String == "110101" }) {
            return .init(.verified, evidence: .amapWeatherResponse, httpStatus: s)
        }
        guard status == 0 else { return .init(.protocolFailure, httpStatus: s, diagnostic: .unrecognizedProviderCode) }
        switch code {
        case 10001, 10013: return .init(.invalidOrExpired, expiry: .rejectedInvalidOrExpired, httpStatus: s)
        case 10041, 40002: return .init(.serviceExpired, expiry: .vendorReportedServiceExpired, httpStatus: s)
        case 10002, 10005, 10006, 10007, 10008, 10009, 10012, 10026: return .init(.permissionDenied, httpStatus: s)
        case 10003, 10010, 10044, 10045, 40000, 40003: return .init(.quotaExceeded, httpStatus: s)
        case 10004, 10014, 10015, 10019, 10020, 10021, 10029: return .init(.rateLimited, httpStatus: s)
        case 10016, 10017: return .init(.vendorUnavailable, httpStatus: s)
        default: return .init(.protocolFailure, httpStatus: s, diagnostic: .unrecognizedProviderCode)
        }
    }
}

/// Source-local normalization of consumed provider fields; never identity ids.
enum TravelProviderValue {
    static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return nil }
            return number.doubleValue
        }
        guard let text = value as? String, text.utf8.count <= 64,
              TravelReadRequest.matches(text, "^-?(0|[1-9][0-9]*)(\\.[0-9]+)?$"),
              let number = Double(text), number.isFinite else { return nil }
        return number
    }
    static func integer(_ value: Any?, range: ClosedRange<Int>) -> Int? {
        if let text = value as? String {
            guard text.utf8.count <= 7, TravelReadRequest.matches(text, "^-?(0|[1-9][0-9]*)$"),
                  let value = Int(text), range.contains(value) else { return nil }
            return value
        }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue.rounded(.towardZero) == number.doubleValue,
              number.doubleValue >= Double(range.lowerBound), number.doubleValue <= Double(range.upperBound) else { return nil }
        let integer = Int(number.doubleValue)
        guard number.decimalValue == Decimal(integer) else { return nil }
        return integer
    }
}
struct FlyAIResponseFailure: Error, Sendable {
    let state: ConnectionState
    var diagnostic: TravelProviderDiagnostic? = nil
}

/// Shared bounded MCP parser for probe, typed read and streamed HTTP completion.
/// Validates matching protocol frames and business representations; output authentication filtering remains at the read boundary.
enum FlyAIMCPResponse {
    private static func fail(_ diagnostic: TravelProviderDiagnostic = .malformedMCPResponse) -> FlyAIResponseFailure {
        .init(state: .protocolFailure, diagnostic: diagnostic)
    }
    static func matchesRequestID(_ value: Any?, expected: Int) -> Bool {
        guard let id = value as? NSNumber, CFGetTypeID(id) != CFBooleanGetTypeID(), id.doubleValue.isFinite else { return false }
        return id.doubleValue == Double(expected) && id.decimalValue == Decimal(expected)
    }
    private static func checked(_ root: [String: Any], requestID: Int, notifications: Bool) throws -> Bool {
        guard let version = root["jsonrpc"] as? String else { throw fail() }
        guard version == "2.0" else { throw fail(.unsupportedProtocolVersion) }
        if root["id"] == nil, notifications, root["method"] is String,
           root["result"] == nil, root["error"] == nil { return false }
        guard matchesRequestID(root["id"], expected: requestID) else { throw fail(.requestIDMismatch) }
        guard (root["result"] != nil) != (root["error"] != nil) else { throw fail(.ambiguousMCPResult) }
        return true
    }
    static func matchingFrame(_ body: Data, requestID: Int, complete: Bool, byteLimit: Int = 65536) throws -> Data? {
        guard body.count <= byteLimit else { throw fail() }
        // Parse complete byte frames first: an unused trailing partial UTF8
        // notification must not delay an already complete matching result.
        var normalized: [UInt8] = []
        for byte in body {
            if byte == 10, normalized.last == 13 { normalized.removeLast() }
            normalized.append(byte)
        }
        let data = Data(normalized), delimiter = Data([10, 10])
        var events: [Data] = [], start = data.startIndex
        while let separator = data.range(of: delimiter, in: start..<data.endIndex) {
            events.append(data.subdata(in: start..<separator.lowerBound)); start = separator.upperBound
            guard events.count <= 64 else { throw fail() }
        }
        if complete, start < data.endIndex { events.append(data.subdata(in: start..<data.endIndex)) }
        guard events.count <= 64 else { throw fail() }
        var matched: Data?
        for event in events {
            guard let text = String(data: event, encoding: .utf8) else { throw fail() }
            let lines = text.components(separatedBy: "\n").filter { $0.hasPrefix("data:") }.map { line in
                let value = String(line.dropFirst(5)); return value.hasPrefix(" ") ? String(value.dropFirst()) : value
            }
            guard !lines.isEmpty else { continue }
            let eventData = Data(lines.joined(separator: "\n").utf8)
            let root: [String: Any]
            do { root = try MusicStrictJSON.object(eventData, limit: byteLimit) }
            catch { throw fail() }
            guard try checked(root, requestID: requestID, notifications: true) else { continue }
            guard matched == nil else { throw fail(.ambiguousMCPResult) }
            // Preserve checked wire bytes; numeric canonicalization can grow them.
            matched = eventData
        }
        return matched
    }
    static func envelope(_ response: ProbeResponse, requestID: Int, byteLimit: Int = 65536) throws -> [String: Any] {
        guard response.body.count <= byteLimit else { throw fail() }
        let mediaType = response.contentType.split(separator: ";", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces).lowercased()
        let data: Data
        if mediaType == "application/json" { data = response.body }
        else if mediaType == "text/event-stream", let matched = try matchingFrame(response.body, requestID: requestID, complete: true, byteLimit: byteLimit) { data = matched }
        else { throw fail() }
        let root: [String: Any]
        do { root = try MusicStrictJSON.object(data, limit: byteLimit) } catch { throw fail() }
        guard try checked(root, requestID: requestID, notifications: false) else { throw fail() }
        return root
    }
    // Exact structured error semantics only. Do not infer authentication from
    // arbitrary message text, generic failure, timeout or an unknown code.
    private static func knownCode(_ value: Any?) -> FlyAIResponseFailure? {
        switch value as? String {
        case "UNAUTHORIZED", "INVALID_API_KEY", "AUTHENTICATION_FAILED": return .init(state: .invalidOrExpired)
        case "FORBIDDEN", "PERMISSION_DENIED": return .init(state: .permissionDenied)
        case "RATE_LIMITED": return .init(state: .rateLimited)
        case "QUOTA_EXCEEDED": return .init(state: .quotaExceeded)
        case "SERVICE_UNAVAILABLE": return .init(state: .vendorUnavailable)
        case "UNSUPPORTED_SIGN_VERSION": return fail(.unsupportedSignVersion)
        case "UNSUPPORTED_TOOL": return fail(.unsupportedReadToolContract)
        default: break
        }
        return nil
    }
    private static func rejection(_ object: [String: Any], rpc: Bool = false) -> FlyAIResponseFailure {
        if let known = knownCode(object["code"]) { return known }
        guard let code = TravelProviderValue.integer(object[rpc ? "code" : "status"], range: -99999...99999) else { return fail(.unrecognizedProviderCode) }
        if rpc && (code == -32601 || code == -32602) { return fail(.unsupportedReadToolContract) }
        switch code {
        case 401: return .init(state: .invalidOrExpired)
        case 403: return .init(state: .permissionDenied)
        case 429: return .init(state: .rateLimited)
        case 500...599: return .init(state: .vendorUnavailable)
        default: return fail(.unrecognizedProviderCode)
        }
    }
    /// Compare only fields consumed by business acceptance. Top-level display
    /// or extension metadata is not business evidence; data/error remain exact.
    private static func businessSignature(_ object: [String: Any]) throws -> Data {
        var consumed: [String: Any] = [:]
        if let status = object["status"] {
            guard let status = TravelProviderValue.integer(status, range: -99999...99999) else { throw fail(.unrecognizedProviderCode) }
            consumed["status"] = status
        }
        if let data = object["data"] { consumed["data"] = data }
        for key in ["error", "code", "success"] {
            guard let value = object[key], !(value is NSNull) else { continue }
            if key == "code", let code = TravelProviderValue.integer(value, range: -99999...99999) { consumed[key] = code }
            else { consumed[key] = value }
        }
        return try JSONSerialization.data(withJSONObject: consumed, options: [.sortedKeys])
    }
    static func business(_ root: [String: Any], byteLimit: Int = 65536, requireSuccess: Bool = true) throws -> [String: Any] {
        _ = try checked(root, requestID: 1, notifications: false)
        if let error = root["error"] {
            guard let error = error as? [String: Any] else { throw fail() }
            if !requireSuccess { return ["error": error] }
            throw rejection(error, rpc: true)
        }
        guard let result = root["result"] as? [String: Any] else { throw fail() }
        var isError = false
        if let value = result["isError"], !(value is NSNull) {
            guard let flag = value as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID() else { throw fail() }
            isError = flag.boolValue
        }
        var candidates: [[String: Any]] = []
        func add(_ object: [String: Any]) {
            if object["status"] != nil || object["data"] != nil || object["error"] != nil || object["code"] != nil { candidates.append(object) }
        }
        if let value = result["structuredContent"], !(value is NSNull) {
            guard let object = value as? [String: Any] else { throw fail(.unsupportedReadToolContract) }
            add(object)
        }
        if let value = result["content"], !(value is NSNull) {
            guard let blocks = value as? [[String: Any]] else { throw fail() }
            for block in blocks {
                guard let type = block["type"] as? String else { throw fail() }
                if type != "text" {
                    guard ["image", "audio", "resource", "resource_link"].contains(type) else { throw fail() }
                    continue // Display data is neither fetched nor projected.
                }
                guard let text = block["text"] as? String, text.utf8.count <= byteLimit else { throw fail() }
                guard text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") else { continue }
                guard let object = try? MusicStrictJSON.object(Data(text.utf8), limit: byteLimit) else { throw fail() }
                add(object)
            }
        }
        guard let inner = candidates.first else { throw fail(.unsupportedReadToolContract) }
        let canonical = try businessSignature(inner)
        for candidate in candidates.dropFirst() {
            guard try businessSignature(candidate) == canonical else { throw fail(.ambiguousMCPResult) }
        }
        if !requireSuccess { return inner }
        try validateBusinessStatus(inner, isError: isError)
        guard let data = inner["data"] as? [String: Any], data["itemList"] is [Any] else { throw fail(.unsupportedReadToolContract) }
        return inner
    }
    /// Shared explicit business status semantics. Credential probes retain their
    /// data-shape check; transparent reads preserve evolving business fields.
    static func validateBusinessStatus(_ inner: [String: Any], isError: Bool = false) throws {
        if let error = inner["error"], !(error is NSNull) {
            guard let error = error as? [String: Any] else { throw fail() }; throw rejection(error, rpc: true)
        }
        if let known = knownCode(inner["code"]) { throw known }
        if let value = inner["success"], !(value is NSNull) {
            guard let flag = value as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID() else { throw fail() }
            guard flag.boolValue else { throw rejection(inner) }
        }
        guard !isError, TravelProviderValue.integer(inner["status"], range: -99999...99999) == 0 else { throw rejection(inner) }
    }
}
