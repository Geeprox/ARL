import Foundation

actor FixtureTransport {
    func call(_ method: String, _ bytes: Data) throws -> Data {
        let params = try JSONSerialization.jsonObject(with: bytes)
        // Use the actual Core JSONEncoder parameter bytes, wrapped with the
        // existing SDK's exact JSONEncoder string rules and newline. This
        // includes escaped base64 slashes; a Python re-encode is not the proof.
        var frame = Data("{\"protocol\":".utf8)
        frame.append(try JSONEncoder().encode("arl/1"))
        frame.append(Data(",\"app\":\"tisra\",\"method\":".utf8))
        frame.append(try JSONEncoder().encode(method))
        frame.append(Data(",\"params\":".utf8)); frame.append(bytes); frame.append(Data("}\n".utf8))
        guard frame.count <= 16384 else { throw ARLApplicationModelError.incompatible }
        let envelope: [String: Any] = ["method": method, "params": params, "request_frame_bytes": frame.count]
        var line = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
        line.append(10)
        try FileHandle.standardOutput.write(contentsOf: line)
        guard let reply = readLine(), let data = reply.data(using: .utf8) else {
            throw ARLApplicationModelError.incompatible
        }
        return data
    }
}
@main struct ApplicationFixture {
    static func main() async throws {
        let transport = FixtureTransport()
        let session = ARLApplicationModelSession { method, bytes in try await transport.call(method, bytes) }
        let catalog = try await session.connect(version: "0.1.0.6")
        guard catalog.packages.count == 5, catalog.packages.last?.reasons == ["effort_downgraded"] else {
            throw ARLApplicationModelError.incompatible
        }
        guard CommandLine.arguments.count == 2 else { throw ARLApplicationModelError.iconUnavailable }
        // Test-only exact fixture path supplied by Python; production reads only
        // its fixed own bundle resource through ARLApplicationModelClient.
        let source = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let icon = try ARLApplicationIcon(bundleICNSData: source)
        let iconReceipt = try await session.registerIcon(icon)
        let iconBytes = try await transport.call("fixture.iconRead", JSONEncoder().encode(iconReceipt))
        struct IconRead: Decodable { let app_id, sha256, mime_type, png_base64: String; let width, height, bytes: Int }
        let iconRead = try JSONDecoder().decode(IconRead.self, from: iconBytes)
        guard iconRead.app_id == "tisra", iconRead.sha256 == icon.sha256, iconRead.png_base64 == icon.png_base64,
              iconRead.mime_type == "image/png", iconRead.width == 64, iconRead.height == 64, iconRead.bytes == icon.byte_count else {
            throw ARLApplicationModelError.changed
        }
        do {
            _ = try await session.request(task: .exhaustive, requestID: UUID(), requestSHA256: String(repeating: "a", count: 64))
            throw ARLApplicationModelError.incompatible
        } catch ARLApplicationModelError.degradationRequired { }
        try await session.ping()
        let tasks: [ARLApplicationTask] = [.quick, .standard, .research, .deep, .exhaustive]
        for task in tasks {
            let receipt = try await session.request(task: task, requestID: UUID(),
                requestSHA256: String(repeating: "a", count: 64), allowDegradation: true)
            let resultBytes = try await transport.call("fixture.terminal", JSONEncoder().encode(receipt))
            let result = try JSONDecoder().decode(ARLApplicationResult.self, from: resultBytes)
            try result.validate(against: receipt)
        }
        do {
            _ = try await session.request(task: .standard, requestID: UUID(), requestSHA256: String(repeating: "a", count: 64), serviceTier: "fast")
            throw ARLApplicationModelError.incompatible
        } catch ARLApplicationModelError.rejected(let reasons) {
            guard reasons == ["fast_authorization_required"] else { throw ARLApplicationModelError.incompatible }
        }
        try await session.close()
        try FileHandle.standardOutput.write(contentsOf: Data("{\"fixture\":\"PASS\",\"real_inference\":0}\n".utf8))
    }
}
