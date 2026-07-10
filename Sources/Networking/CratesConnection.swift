import Foundation

/// Immutable description of how to reach a Crates server: base URL + the bearer token obtained
/// through pairing. Persisted with the non-secret host/port in UserDefaults and the token in the
/// Keychain (split + reassembled in `AppModel`); the in-memory value always carries both.
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
        comps.scheme = "http" // Server is plain-HTTP (LAN or Tailscale); ATS is relaxed in Info.plist.
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

    /// `?size=` accepts ONLY "thumb" (100×100, best-effort — silently returns the original
    /// when no pre-generated thumbnail exists) and "original". Integer sizes are rejected with
    /// HTTP 400 (verified live 2026-07-04) — the OpenAPI spec is wrong here, as it was about auth.
    enum CoverSize: String, Sendable { case original, thumb }

    func coverURL(coverID: Int64, size: CoverSize? = nil) -> URL? {
        let q = size.map { [URLQueryItem(name: "size", value: $0.rawValue)] } ?? []
        return url(path: "covers/byCoverID/\(coverID)", query: q)
    }

    /// Header AVURLAsset / image loaders attach for authenticated media.
    var authHeader: [String: String] {
        token.isEmpty ? [:] : ["Authorization": "Bearer \(token)"]
    }
}
