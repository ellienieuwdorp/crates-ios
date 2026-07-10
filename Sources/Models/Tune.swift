import Foundation

/// A track. Mirrors the fields of the server's `TunePresentationBeanImpl` that the POC actually
/// uses. The server sends most numeric-ish fields as strings (bpm, length, year…), so we decode
/// leniently and expose typed conveniences.
struct Tune: Identifiable, Hashable, Sendable, Codable {
    let id: Int64
    var title: String
    var artist: String
    var album: String
    var genre: String?
    var lengthSeconds: Double?
    var bpm: String?
    var key: String?
    var rating: Int?
    var coverID: Int64?
    var dateAdded: Date?
    var source: TrackSource
    var pageURL: String?
    /// Whether the SERVER can stream this tune (an AudioFiles row with a codec exists).
    /// nil = unknown (stale pre-round-4 cache) — treat unknown as playable, never dim on a guess.
    var hasServerAudio: Bool?
    /// Play count as last synced/reported. nil = unknown (stale cache) — treated as 0 when a
    /// play is counted. The server's update endpoint sets ABSOLUTE values, so this local value
    /// is the base for `current + 1` play reports (see PlaySync).
    var playedCount: Int?
    /// Locally observed last-listen moment; the backup export carries no such column, so this
    /// only ever comes from on-device plays (or the REST bean).
    var lastListenDate: Date?
    /// The server bean's objectID — rides along on attribute writes (desktop parity).
    var objectID: String?

    /// Honest playability: unplayable only when we know the server has no audio for it.
    /// (A local download would still play — callers overlay that separately.)
    var knownUnstreamable: Bool { hasServerAudio == false }

    /// Display title falling back to filename-ish server fields when tags are empty.
    var displayTitle: String { title.isEmpty ? "Untitled" : title }
    var displayArtist: String { artist.isEmpty ? "Unknown Artist" : artist }

    enum CodingKeys: String, CodingKey {
        case id = "tuneID"
        case tuneTitle, tuneName, artist, album, genre
        case tuneLength, bpm, tuneKey, rating, coverID
        case dateAdded, pageUrl
        case purchasedFrom
        case defaultAudioSourceType
        case playedCount, lastListenDate, objectID
    }

    /// Symmetric representation for the local disk cache. The server-shaped decoder is lossy by
    /// nature (it derives typed fields from loose strings), so round-tripping through the server
    /// keys would strip length/dates/source on every cold start. The cache encodes this instead.
    private struct CachedTune: Codable {
        var v: Int = 1 // cache-shape marker + future migration hook
        var id: Int64; var title: String; var artist: String; var album: String
        var genre: String?; var lengthSeconds: Double?; var bpm: String?; var key: String?
        var rating: Int?; var coverID: Int64?; var dateAdded: Date?
        var source: TrackSource; var pageURL: String?
        var hasServerAudio: Bool? = nil // v1 caches lack it → decodes nil (unknown)
        var playedCount: Int? = nil     // pre-play-sync caches lack these three → nil (unknown)
        var lastListenDate: Date? = nil
        var objectID: String? = nil
    }

    init(from decoder: Decoder) throws {
        // Cache shape first (exact typed fields), then the loose server shape.
        if let cached = try? decoder.singleValueContainer().decode(CachedTune.self) {
            id = cached.id; title = cached.title; artist = cached.artist; album = cached.album
            genre = cached.genre; lengthSeconds = cached.lengthSeconds; bpm = cached.bpm
            key = cached.key; rating = cached.rating; coverID = cached.coverID
            dateAdded = cached.dateAdded; source = cached.source; pageURL = cached.pageURL
            hasServerAudio = cached.hasServerAudio
            playedCount = cached.playedCount; lastListenDate = cached.lastListenDate
            objectID = cached.objectID
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeFlexibleInt64(.id) ?? 0
        let t = try c.decodeIfPresent(String.self, forKey: .tuneTitle)
        let n = try c.decodeIfPresent(String.self, forKey: .tuneName)
        title = (t?.isEmpty == false ? t : n) ?? ""
        artist = (try c.decodeIfPresent(String.self, forKey: .artist)) ?? ""
        album = (try c.decodeIfPresent(String.self, forKey: .album)) ?? ""
        genre = try c.decodeIfPresent(String.self, forKey: .genre)
        lengthSeconds = Tune.parseLength(try c.decodeIfPresent(String.self, forKey: .tuneLength))
        bpm = try c.decodeIfPresent(String.self, forKey: .bpm)
        key = try c.decodeIfPresent(String.self, forKey: .tuneKey)
        rating = try c.decodeFlexibleInt(.rating)
        coverID = try c.decodeFlexibleInt64(.coverID)
        dateAdded = Tune.parseDate(try c.decodeIfPresent(String.self, forKey: .dateAdded))
        pageURL = try c.decodeIfPresent(String.self, forKey: .pageUrl)
        // Source: `purchasedFrom` store id is the strongest signal (1 = Bandcamp per spec);
        // real POC resolves `defaultAudioSourceType` against /audiosource/types at runtime.
        let purchased = try c.decodeFlexibleInt(.purchasedFrom)
        source = Tune.sourceFromStoreID(purchased)
        hasServerAudio = nil // REST shape carries no AudioFiles join
        playedCount = try c.decodeFlexibleInt(.playedCount)
        lastListenDate = ServerDate.parse(try c.decodeIfPresent(String.self, forKey: .lastListenDate))
        objectID = try c.decodeIfPresent(String.self, forKey: .objectID)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(CachedTune(
            id: id, title: title, artist: artist, album: album, genre: genre,
            lengthSeconds: lengthSeconds, bpm: bpm, key: key, rating: rating,
            coverID: coverID, dateAdded: dateAdded, source: source, pageURL: pageURL,
            hasServerAudio: hasServerAudio, playedCount: playedCount,
            lastListenDate: lastListenDate, objectID: objectID))
    }

    /// Direct memberwise init for previews / tests / cache reconstruction.
    init(id: Int64, title: String, artist: String, album: String = "",
         genre: String? = nil, lengthSeconds: Double? = nil, bpm: String? = nil,
         key: String? = nil, rating: Int? = nil, coverID: Int64? = nil,
         dateAdded: Date? = nil, source: TrackSource = .unknown, pageURL: String? = nil,
         hasServerAudio: Bool? = nil, playedCount: Int? = nil,
         lastListenDate: Date? = nil, objectID: String? = nil) {
        self.id = id; self.title = title; self.artist = artist; self.album = album
        self.genre = genre; self.lengthSeconds = lengthSeconds; self.bpm = bpm; self.key = key
        self.rating = rating; self.coverID = coverID; self.dateAdded = dateAdded
        self.source = source; self.pageURL = pageURL; self.hasServerAudio = hasServerAudio
        self.playedCount = playedCount; self.lastListenDate = lastListenDate
        self.objectID = objectID
    }

    static func sourceFromStoreID(_ id: Int?) -> TrackSource {
        switch id {
        case 1: .bandcamp
        default: .unknown
        }
    }

    static func parseLength(_ raw: String?) -> Double? {
        guard let raw, !raw.isEmpty else { return nil }
        if let d = Double(raw) { return d > 10_000 ? d / 1000 : d } // ms vs s heuristic
        // mm:ss / hh:mm:ss
        let parts = raw.split(separator: ":").compactMap { Double($0) }
        guard !parts.isEmpty else { return nil }
        return parts.reduce(0) { $0 * 60 + $1 }
    }

    static func parseDate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        if let ms = Double(raw) { return Date(timeIntervalSince1970: ms > 3_000_000_000 ? ms / 1000 : ms) }
        return ISO8601DateFormatter().date(from: raw)
    }
}

extension Tune {
    var lengthLabel: String {
        guard let s = lengthSeconds, s > 0 else { return "--:--" }
        let total = Int(s.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
