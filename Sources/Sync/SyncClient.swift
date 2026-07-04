import Foundation

/// Downloads the library from the server the way the real mobile app does: a single bulk
/// `GET /sync/export.backup` returning `CratesBackup.zip` (application/octet-stream). This is how
/// the client sidesteps the API's total lack of pagination — the whole library arrives at once.
///
///   • initial sync:      lastSyncDate = nil          → full library
///   • incremental sync:  lastSyncDate = "yyyy-MM-dd HH:mm:ss" → delta only
///
/// The POC requests `includeImageFiles=false` so the download is JSON-only (~megabytes, not the
/// ~120 MB full export); cover art loads on demand from the unauthenticated `/covers/byCoverID`.
actor SyncClient {
    private let connection: CratesConnection
    private let session: URLSession

    init(connection: CratesConnection, session: URLSession = .shared) {
        self.connection = connection
        self.session = session
    }

    /// Download the backup zip to a temp file and return its URL.
    ///
    /// `sinceCursor` is an OPAQUE string in the server's own time frame ("yyyy-MM-dd HH:mm:ss",
    /// server-local wall clock) — always the lexicographic-max stamp from a previous payload,
    /// never a device-clock Date (device TZ ≠ server TZ corrupts the cursor silently). An
    /// invalid cursor gets HTTP 400 with a JSON body: surfaced as CratesAPIError.http(400),
    /// caller falls back to a full sync.
    func downloadBackup(includeImages: Bool = false,
                        sinceCursor: String? = nil) async throws -> URL {
        var query = [URLQueryItem(name: "includeImageFiles", value: includeImages ? "true" : "false")]
        if let sinceCursor {
            query.append(URLQueryItem(name: "lastSyncDate", value: sinceCursor))
        }
        guard let url = connection.url(path: "sync/export.backup", query: query) else {
            throw CratesAPIError.badURL
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 300 // large export; server also spends time zipping
        if !connection.token.isEmpty {
            req.setValue("Bearer \(connection.token)", forHTTPHeaderField: "Authorization")
        }

        let tempURL: URL, response: URLResponse
        do { (tempURL, response) = try await session.download(for: req) }
        catch { throw CratesAPIError.transport(error) }

        if let http = response as? HTTPURLResponse {
            switch http.statusCode {
            case 200...299: break
            case 401, 403: throw CratesAPIError.unauthorized
            default: throw CratesAPIError.http(http.statusCode)
            }
        }
        // Move to a stable name (URLSession's temp file is deleted when this scope returns).
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("CratesBackup-\(UInt64(bitPattern: Int64(tempURL.hashValue))).zip")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tempURL, to: dest)
        return dest
    }
}
