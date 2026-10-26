import Foundation

// Pending native admission: compile with MusicLoginURL.swift and
// ServiceConnectionCatalog.swift only. This fixture performs no network/Keychain/UI work.
@main
struct ServiceCredentialUIContractFixtures {
    enum Failure: Error { case rejectedExpectedURL, acceptedUnsafeURL, catalogContract }

    static func main() throws {
        for raw in ["https://music.163.com/login?codekey=synthetic",
                    "https://music.163.com:443/login?codekey=synthetic",
                    "https://sub.music.163.com/login?codekey=synthetic"] {
            guard let url = URL(string: raw), MusicLoginURL.validated(url) != nil else {
                throw Failure.rejectedExpectedURL
            }
        }
        for raw in ["http://music.163.com/login", "file:///tmp/synthetic",
                    "javascript:alert(1)", "https://music.163.com.evil.invalid/login",
                    "https://evilmusic.163.com/login", "https://music.163.com@evil.invalid/login",
                    "https://user@music.163.com/login", "https://user:pass@music.163.com/login",
                    "https://music.163.com:8443/login", "https://music.163.com./login",
                    "https://music.163.com/login?codekey=" + String(repeating: "x", count: 4096)] {
            if let url = URL(string: raw), MusicLoginURL.validated(url) != nil {
                throw Failure.acceptedUnsafeURL
            }
        }
        let raw = """
        {"schema_version":1,"services":[
          {"id":"amap","name":"高德地图","symbol":"map","configuration":"native_credentials","credential_purpose":"amap.maps-weather","tool_prefixes":["mio_maps_"]},
          {"id":"fliggy","name":"飞猪","symbol":"airplane","configuration":"native_credentials","credential_purpose":"fliggy.travel-readonly","tool_prefixes":["mio_flyai_"]},
          {"id":"netease","name":"网易云音乐","symbol":"music.note","configuration":"native_credentials","credential_purpose":"netease.music-account","tool_prefixes":["netease.","mio_netease_"],"official_url":"https://github.com/NetEase/skills#ncm-cli-setup","reason":"合成目录测试"}
        ]}
        """
        let data = Data(raw.utf8)
        guard let valid = ServiceConnectionCatalog.decode(data), valid.services.count == 3,
              valid.services[2].credential_purpose == "netease.music-account" else { throw Failure.catalogContract }
        let original = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        for (key, value) in [("configuration", "official_cli"),
                             ("credential_purpose", "amap.maps-weather"),
                             ("configure_command", "ncm-cli configure"),
                             ("official_url", "https://evil.invalid/setup"),
                             ("reason", "") ] {
            var changed = original
            var rows = changed["services"] as! [[String: Any]]
            rows[2][key] = value
            changed["services"] = rows
            guard ServiceConnectionCatalog.decode(try JSONSerialization.data(withJSONObject: changed)) == nil else {
                throw Failure.catalogContract
            }
        }
        guard ServiceConnectionCatalog.decode(Data(repeating: 32, count: 16385)) == nil else {
            throw Failure.catalogContract
        }
        print("URL and native catalog contract fixture passed")
    }
}
