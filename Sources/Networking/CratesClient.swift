import Foundation

enum CratesAPIError: Error, LocalizedError {
    case notConfigured
    case badURL
    case unauthorized
    case pairingNotApproved
    case pairingTimeout
    case http(Int)
    case transport(Error)
    case decoding(Error)

    var errorDescription: String? {
        switch self {
        case .notConfigured: "No server configured. Pair with a Crates server first."
        case .badURL: "Could not build a valid request URL."
        case .unauthorized: "The server rejected the connection. Re-pair this device."
        case .pairingNotApproved: "Pairing was declined on the desktop."
        case .pairingTimeout: "Pairing timed out — approve the request on your computer."
        case .http(let code): "Server returned HTTP \(code)."
        case .transport(let e): Self.friendlyTransport(e)
        case .decoding(let e): "Could not read the server's response. \(e.localizedDescription)"
        }
    }

    /// Turn a raw URLError into a short, actionable line for the pairing UI. Falls back to the
    /// system description for anything we don't specifically recognise.
    private static func friendlyTransport(_ error: Error) -> String {
        guard let url = error as? URLError else { return "Network error: \(error.localizedDescription)" }
        switch url.code {
        case .appTransportSecurityRequiresSecureConnection:
            return "This server uses plain HTTP, which iOS blocks by default. If you just updated the app, reinstall it so the new network settings take effect."
        case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
            return "Couldn't reach a Crates server at that address. Check the IP or Tailscale name and that the server is running."
        case .timedOut:
            return "The server didn't respond in time. Make sure it's reachable from your phone (same network or Tailscale connected)."
        case .notConnectedToInternet, .networkConnectionLost:
            return "The network connection dropped. Reconnect and try again."
        default:
            return "Network error: \(url.localizedDescription)"
        }
    }
}

/// Thin async HTTP client for the ~30 endpoints the POC actually uses. Deliberately hand-written
/// rather than generated from the 447-path spec: smaller surface, full control over the loose
/// decoding the API requires. Auth is `Authorization: Bearer <token>` (confirmed against the
/// running server's AuthService).
actor CratesClient {
    private var connection: CratesConnection
    private let session: URLSession
    private let decoder: JSONDecoder

    init(connection: CratesConnection, session: URLSession = .shared) {
        self.connection = connection
        self.session = session
        self.decoder = JSONDecoder()
    }

    func update(connection: CratesConnection) { self.connection = connection }
    var currentConnection: CratesConnection { connection }

    // MARK: - Core request

    func get<T: Decodable>(_ path: String, query: [URLQueryItem] = [], as type: T.Type) async throws -> T {
        let data = try await rawGet(path, query: query)
        do { return try decoder.decode(T.self, from: data) }
        catch { throw CratesAPIError.decoding(error) }
    }

    func rawGet(_ path: String, query: [URLQueryItem] = []) async throws -> Data {
        guard connection.isConfigured else { throw CratesAPIError.notConfigured }
        guard let url = connection.url(path: path, query: query) else { throw CratesAPIError.badURL }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        authorize(&req)
        return try await perform(req)
    }

    func post<T: Decodable>(_ path: String, body: Data?, as type: T.Type,
                            authorized: Bool = true, overrideToken: String? = nil) async throws -> T {
        let data = try await rawPost(path, body: body, authorized: authorized, overrideToken: overrideToken)
        do { return try decoder.decode(T.self, from: data) }
        catch { throw CratesAPIError.decoding(error) }
    }

    @discardableResult
    func rawPost(_ path: String, body: Data?, authorized: Bool = true,
                 overrideToken: String? = nil) async throws -> Data {
        guard let url = connection.url(path: path) else { throw CratesAPIError.badURL }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        if let overrideToken { req.setValue("Bearer \(overrideToken)", forHTTPHeaderField: "Authorization") }
        else if authorized { authorize(&req) }
        return try await perform(req)
    }

    private func authorize(_ req: inout URLRequest) {
        if !connection.token.isEmpty {
            req.setValue("Bearer \(connection.token)", forHTTPHeaderField: "Authorization")
        }
    }

    private func perform(_ req: URLRequest) async throws -> Data {
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: req) }
        catch { throw CratesAPIError.transport(error) }
        guard let http = response as? HTTPURLResponse else { return data }
        switch http.statusCode {
        case 200...299: return data
        case 401, 403: throw CratesAPIError.unauthorized
        // 406/408 are pairing-flow semantics; PairingService maps them itself. On general
        // endpoints they are just HTTP errors.
        default: throw CratesAPIError.http(http.statusCode)
        }
    }

    /// Snapshot of the current connection for building media URLs off-actor (AVURLAsset needs the
    /// auth header attached to the asset). Callers use `connection.streamURL(...)` etc.
    func connectionSnapshot() -> CratesConnection { connection }
}
