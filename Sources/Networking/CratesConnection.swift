import Foundation

/// Immutable description of how to reach a Crates server: base URL + the bearer token obtained
/// through pairing. Persisted (token in Keychain in a real build; UserDefaults here for the POC).
struct CratesConnection: Sendable, Equatable, Codable {
    /// e.g. http://192.168.1.42:54735
    var host: String
    var port: Int
    /// Bearer token from the pairing handshake. Empty until paired.
    var token: String

    static let defaultPort = 54735
    static let apiRoot = "resources"

    var baseURL: URL? {
        var comps = URLComponents()
        comps.scheme = "http" // LAN plain-HTTP; ATS NSAllowsLocalNetworking covers this.
        comps.host = host
        comps.port = port
        comps.path = "/\(Self.apiRoot)"
        return comps.url
    }

    var isConfigured: Bool { !host.isEmpty && !token.isEmpty }

    func url(path: String, query: [URLQueryItem] = []) -> URL? {
        guard !host.isEmpty,
              var comps = baseURL.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) })
        else { return nil }
        comps.path = "/\(Self.apiRoot)/" + path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !query.isEmpty { comps.queryItems = query }
        return comps.url
    }

    // MARK: - Media URLs (value-type, so the MainActor player can build them without an actor hop)

    func streamURL(tuneID: Int64) -> URL? { url(path: "stream/\(tuneID)") }

    func coverURL(coverID: Int64, size: Int? = nil) -> URL? {
        let q = size.map { [URLQueryItem(name: "size", value: String($0))] } ?? []
        return url(path: "covers/byCoverID/\(coverID)", query: q)
    }

    /// Header AVURLAsset / image loaders attach for authenticated media.
    var authHeader: [String: String] {
        token.isEmpty ? [:] : ["Authorization": "Bearer \(token)"]
    }
}
