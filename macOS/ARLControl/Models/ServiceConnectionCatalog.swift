import Foundation

/// Shared native credential metadata; no terminal setup or user-home credential paths.
struct ServiceConnectionEntry: Decodable, Identifiable {
    let id: String
    let name: String
    let symbol: String
    let configuration: String
    let credential_purpose: String?
    let tool_prefixes: [String]
    let official_url: String?
    let reason: String?

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: ServiceCatalogKey.self)
        let required: Set<String> = ["id", "name", "symbol", "configuration", "credential_purpose", "tool_prefixes"]
        let keys = Set(values.allKeys.map(\.stringValue))
        guard required.isSubset(of: keys), keys.isSubset(of: required.union(["official_url", "reason"])) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid native service fields"))
        }
        id = try values.decode(String.self, forKey: .init("id"))
        name = try values.decode(String.self, forKey: .init("name"))
        symbol = try values.decode(String.self, forKey: .init("symbol"))
        configuration = try values.decode(String.self, forKey: .init("configuration"))
        credential_purpose = try values.decodeIfPresent(String.self, forKey: .init("credential_purpose"))
        tool_prefixes = try values.decode([String].self, forKey: .init("tool_prefixes"))
        if keys.contains("official_url") {
            official_url = try values.decode(String.self, forKey: .init("official_url"))
        } else { official_url = nil }
        if keys.contains("reason") {
            reason = try values.decode(String.self, forKey: .init("reason"))
        } else { reason = nil }
    }

    fileprivate var valid: Bool {
        if id == "codex" {
            return configuration == "host_scoped_model" && credential_purpose == nil && tool_prefixes == ["codex."]
                && official_url == nil && Self.validText(name, limit: 120) && Self.validText(symbol, limit: 80)
                && reason.map({ Self.validText($0, limit: 2048) }) == true
        }
        let expected: [String: (purpose: String, prefixes: [String])] = [
            "amap": ("amap.maps-weather", ["mio_maps_"]),
            "fliggy": ("fliggy.travel-readonly", ["mio_flyai_"]),
            "netease": ("netease.music-account", ["netease.", "mio_netease_"])
        ]
        guard let contract = expected[id], configuration == "native_credentials",
              credential_purpose == contract.purpose, tool_prefixes == contract.prefixes,
              Self.validText(name, limit: 120), Self.validText(symbol, limit: 80),
              reason.map({ Self.validText($0, limit: 2048) }) ?? true else { return false }
        if id == "netease" {
            return official_url == "https://github.com/NetEase/skills#ncm-cli-setup" && reason != nil
        }
        return official_url == nil
    }

    private static func validText(_ value: String, limit: Int) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.utf8.count <= limit
            && value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }
}

private struct ServiceCatalogKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(_ value: String) { stringValue = value }
    init?(stringValue: String) { self.init(stringValue) }
    init?(intValue: Int) { return nil }
}

struct ServiceConnectionCatalog: Decodable {
    let schema_version: Int
    let services: [ServiceConnectionEntry]

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: ServiceCatalogKey.self)
        guard Set(values.allKeys.map(\.stringValue)) == ["schema_version", "services"] else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid service catalog fields"))
        }
        schema_version = try values.decode(Int.self, forKey: .init("schema_version"))
        services = try values.decode([ServiceConnectionEntry].self, forKey: .init("services"))
    }

    static func decode(_ data: Data) -> Self? {
        guard data.count <= 16384,
              let value = try? JSONDecoder().decode(Self.self, from: data),
              value.schema_version == 1,
              value.services.map(\.id) == ["amap", "fliggy", "netease", "codex"],
              value.services.allSatisfy(\.valid) else { return nil }
        return value
    }

    static func load(bundle: Bundle = .main) -> Self? {
        guard let url = bundle.url(forResource: "ServiceConnections", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return decode(data)
    }
}
