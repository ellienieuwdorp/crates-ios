import Foundation

/// Resolves a Bandcamp tune's preview stream client-side — the SAME mechanism the desktop
/// server uses internally for waveform/BPM analysis (`BandcampUtils.extractStreamUrl`): fetch
/// the track page, parse the `data-tralbum` JSON attribute, take `trackinfo[0].file["mp3-128"]`.
/// Verified live 2026-07-04: the resulting bcbits.com URL serves Range-capable audio/mpeg that
/// AVPlayer plays directly (see docs/research/reports/online-source-preview-feasibility.md).
///
/// Stream URLs are signed and time-limited — cached briefly, re-resolved on expiry/failure.
/// Personal-build feature: this file must be excluded from any App Store target (guideline
/// 5.2.3 names these services; see the feasibility report).
actor BandcampResolver {
    static let shared = BandcampResolver()

    enum ResolveError: Error {
        case noPage, fetchFailed, notStreamable
    }

    private struct Resolution {
        let url: URL
        let resolvedAt: Date
    }

    private var cache: [Int64: Resolution] = [:]
    private var inFlight: [Int64: Task<URL, Error>] = [:]
    /// Short TTL: the signed URLs expire server-side on an undocumented clock.
    private static let ttl: TimeInterval = 20 * 60

    /// Own ephemeral session: keeps Bandcamp's tracking cookies out of the app-wide jar and
    /// makes the isolation from server (bearer) traffic structural, not incidental.
    private nonisolated let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        return URLSession(configuration: config)
    }()

    /// True when the tune can even attempt a preview: a Bandcamp tune whose page is an HTTPS
    /// bandcamp.com URL. The host lock (mirrored in resolve + the stream parse) fails closed so
    /// a compromised/MITM'd server can't turn synced pageURLs into a blind LAN-GET primitive.
    nonisolated static func canResolve(_ tune: Tune) -> Bool {
        tune.source == .bandcamp && tune.pageURL.flatMap(URL.init).map(isBandcampPage) == true
    }

    /// HTTPS + host is bandcamp.com or *.bandcamp.com. (Artist custom domains won't preview —
    /// acceptable; an explicit allowlist can come later.)
    nonisolated static func isBandcampPage(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return host == "bandcamp.com" || host.hasSuffix(".bandcamp.com")
    }

    /// HTTPS + the bcbits.com CDN that genuine tralbum data always points at.
    nonisolated static func isBcbitsStream(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return host == "bcbits.com" || host.hasSuffix(".bcbits.com")
    }

    func resolve(_ tune: Tune) async throws -> URL {
        if let hit = cache[tune.id], Date().timeIntervalSince(hit.resolvedAt) < Self.ttl {
            return hit.url
        }
        if let running = inFlight[tune.id] { return try await running.value }
        guard let pageString = tune.pageURL, let page = URL(string: pageString),
              Self.isBandcampPage(page) else { throw ResolveError.noPage } // host-locked, fail closed

        let session = self.session
        let task = Task<URL, Error> {
            var request = URLRequest(url: page)
            // Bandcamp serves the tralbum data to normal browsers; identify as mobile Safari.
            request.setValue(
                "Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1",
                forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 15
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let html = String(data: data, encoding: .utf8) else {
                throw ResolveError.fetchFailed
            }
            guard let url = Self.extractStreamURL(fromHTML: html) else {
                throw ResolveError.notStreamable // artist disabled streaming, or markup changed
            }
            return url
        }
        inFlight[tune.id] = task
        defer { inFlight[tune.id] = nil }
        let url = try await task.value
        cache[tune.id] = Resolution(url: url, resolvedAt: Date())
        return url
    }

    /// Drop a cached URL (playback failed — likely an expired signature).
    func invalidate(_ tuneID: Int64) {
        cache[tuneID] = nil
    }

    // MARK: - Parsing (pure, unit-tested)

    /// `data-tralbum="…&quot;-escaped JSON…"` → `trackinfo[].file["mp3-128"]`.
    nonisolated static func extractStreamURL(fromHTML html: String) -> URL? {
        guard let attribute = firstAttribute("data-tralbum", in: html) else { return nil }
        let json = decodeHTMLEntities(attribute)
        guard let data = json.data(using: .utf8),
              let tralbum = try? JSONDecoder().decode(Tralbum.self, from: data),
              let file = tralbum.trackinfo?.compactMap({ $0.file?.mp3_128 }).first
        else { return nil }
        let absolute = file.hasPrefix("//") ? "https:" + file : file
        // Host-lock the stream too: a crafted/MITM'd tralbum must not aim AVPlayer at a LAN host.
        guard let url = URL(string: absolute), isBcbitsStream(url) else { return nil }
        return url
    }

    struct Tralbum: Decodable {
        struct TrackInfo: Decodable {
            struct File: Decodable {
                let mp3_128: String?
                enum CodingKeys: String, CodingKey { case mp3_128 = "mp3-128" }
            }
            let file: File?
        }
        let trackinfo: [TrackInfo]?
    }

    nonisolated static func firstAttribute(_ name: String, in html: String) -> String? {
        guard let start = html.range(of: "\(name)=\"") else { return nil }
        let rest = html[start.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }

    /// Minimal entity decode for HTML-attribute-embedded JSON. `&amp;` must decode LAST or
    /// double-encoded entities (&amp;quot;) corrupt the payload.
    nonisolated static func decodeHTMLEntities(_ s: String) -> String {
        s.replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}

extension Tune {
    /// Playable via the client-side Bandcamp preview even without server audio. Host-locked so
    /// a poisoned synced row can't even light up the Preview UI.
    var hasPreviewSource: Bool {
        BandcampResolver.canResolve(self)
    }
}
