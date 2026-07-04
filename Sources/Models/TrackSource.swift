import SwiftUI

/// Where a tune's audio physically comes from. Drives the per-row source glyph (Idea #6/#7).
///
/// The server models this two ways: `purchasedFrom` (store id, e.g. 1 = Bandcamp) and audio
/// source *types* (`/audiosource/types`, referenced by `defaultAudioSourceType`). The POC maps
/// both into this small closed set; unknowns fall back to `.unknown` rather than lying.
enum TrackSource: String, Codable, Sendable, CaseIterable {
    case localFile
    case bandcamp
    case youtube
    case spotify
    case soundcloud
    case discogs
    case tidal
    case appleMusic
    case unknown

    /// Best-effort mapping from an audio-source type NAME string (server returns human names
    /// via `/audiosource/types`). Case-insensitive substring match keeps it resilient to
    /// wording changes; real type-id mapping is resolved at runtime from that endpoint.
    static func fromTypeName(_ raw: String?) -> TrackSource {
        guard let s = raw?.lowercased() else { return .unknown }
        if s.contains("local") || s.contains("file") || s.contains("disk") { return .localFile }
        if s.contains("bandcamp") { return .bandcamp }
        if s.contains("youtube") { return .youtube }
        if s.contains("spotify") { return .spotify }
        if s.contains("soundcloud") { return .soundcloud }
        if s.contains("discogs") { return .discogs }
        if s.contains("tidal") { return .tidal }
        if s.contains("apple") { return .appleMusic }
        return .unknown
    }

    var label: String {
        switch self {
        case .localFile: "Local file"
        case .bandcamp: "Bandcamp"
        case .youtube: "YouTube"
        case .spotify: "Spotify"
        case .soundcloud: "SoundCloud"
        case .discogs: "Discogs"
        case .tidal: "TIDAL"
        case .appleMusic: "Apple Music"
        case .unknown: "Unknown source"
        }
    }

    /// SF Symbol used for the compact per-row indicator.
    var symbol: String {
        switch self {
        case .localFile: "internaldrive"
        case .bandcamp: "b.square"
        case .youtube: "play.rectangle"
        case .spotify: "s.circle"
        case .soundcloud: "cloud"
        case .discogs: "record.circle"
        case .tidal: "water.waves"
        case .appleMusic: "music.note"
        case .unknown: "questionmark.circle"
        }
    }

    var tint: Color {
        switch self {
        case .localFile: CratesColor.accent
        case .bandcamp: CratesColor.blue
        case .youtube: CratesColor.red
        case .spotify, .appleMusic: CratesColor.green
        case .soundcloud: CratesColor.gold
        case .discogs, .tidal, .unknown: CratesColor.textSecondary
        }
    }

    /// Whether the phone can play this without the desktop transcoding on the fly. Local files
    /// and store-hosted audio stream fine; streaming-service imports may be unavailable offline.
    var isReliablyStreamable: Bool {
        switch self {
        case .localFile, .bandcamp, .discogs: true
        default: false
        }
    }
}
