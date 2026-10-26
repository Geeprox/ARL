import Foundation

/// The user's spelling is retained separately from the normalized endpoint.
public struct NASAddressInput: Equatable, Sendable {
    public let original: String
    public let host: String
    public let port: Int

    public init(_ input: String, port: Int = 445) throws {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard input.utf8.count <= 512, !value.isEmpty,
              !input.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { throw ARLNASFault.invalidConfiguration }
        let host: String, effectivePort: Int
        if value.contains("://") {
            guard let url = URLComponents(string: value), url.scheme?.lowercased() == "smb",
                  url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
                  url.percentEncodedPath.isEmpty || url.percentEncodedPath == "/",
                  !value.contains("%"), let name = url.host else { throw ARLNASFault.invalidConfiguration }
            host = name; effectivePort = url.port ?? port
        } else { host = value; effectivePort = port }
        guard (1...253).contains(host.utf8.count),
              host.range(of: "^[A-Za-z0-9][A-Za-z0-9.-]*$", options: .regularExpression) != nil,
              (1...65535).contains(effectivePort) else { throw ARLNASFault.invalidConfiguration }
        original = input; self.host = host; self.port = effectivePort
    }
}
