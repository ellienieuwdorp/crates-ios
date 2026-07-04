import Foundation

/// Row shapes for the `CratesBackup.zip` JSON tables the POC imports. Verified against a real
/// 1.15.3 export (2026-07-04). The backup is a full relational dump — one JSON array per table —
/// so we decode the handful of tables needed to reconstruct the browse tree, then join them.
///
/// Only the columns we use are declared; the decoder ignores the rest.
enum Backup {
    // TuneRow/AudioFileRow are Codable (not just Decodable): delta sync persists them as raw
    // caches (DiskCache "raw_tunes"/"raw_audio") and upserts delta rows into them by PK —
    // lastSyncDate only filters these tables server-side (verified live, dogfood round 3 W8).
    struct TuneRow: Codable {
        let TuneID: Int64
        let TuneTitle: String?
        let TuneName: String?
        let Artist: String?
        let Album: String?
        let Genre: String?
        let TuneLength: String?          // seconds, but the server sends it as a STRING ("431")
        let DateAdded: String?
        let DateLastModified: String?    // the server's delta filter column for this table
        let CoverID: Int64?
        let PlayedCount: Int?
        let DefaultAudioSourceType: Int? // 1 = local file, 5 = bandcamp (from /audiosource/types)
        let PageUrl: String?
        let TuneDefaultLocation: String?
    }

    struct CrateRow: Decodable {
        let CrateID: Int64
        let Name: String?
        let CrateTypeID: Int?
        let Hidden: Bool?
        let ReleaseID: Int64?
    }

    struct CrateToCrateRow: Decodable {
        let ParentCrateID: Int64?
        let ChildCrateID: Int64?
        let CrateOrderingID: Int?
    }

    struct CrateToTuneRow: Decodable {
        let CrateID: Int64
        let TuneID: Int64
        let TuneOrderingID: Int?
        let DateModified: String?   // per-membership timestamp = "date added to THIS crate"
        let PrimaryCrate: Bool?
    }

    struct AudioFileRow: Codable {
        let AudioFileID: Int64?     // PK for delta upserts
        let TuneID: Int64?
        let Bpm: String?
        let Key: String?
        let Codec: String?
        let FileType: String?
        let StorageType: String?    // LOCAL_STORAGE etc.
        let DateModified: String?   // the server's delta filter column for this table
    }

    struct RatingRow: Decodable {
        let ObjectID: Int64?
        let RatingValue: Int?
    }

    /// Only for the delta cursor (and future artwork-cache eviction) — Covers is the third
    /// lastSyncDate-filtered table.
    struct CoverRow: Decodable {
        let CoverID: Int64?
        let DateModified: String?
    }

    /// The audio-source type ids seen in real data. Full set is resolvable at runtime from
    /// `/audiosource/types`; these cover the common cases for the source badge.
    static func source(forTypeID id: Int?, location: String?) -> TrackSource {
        switch id {
        case 1: return .localFile
        case 5: return .bandcamp
        default: break
        }
        // Fall back to sniffing the location URL.
        let loc = (location ?? "").lowercased()
        if loc.hasPrefix("/") || loc.hasPrefix("file:") { return .localFile }
        if loc.contains("bandcamp") { return .bandcamp }
        if loc.contains("youtube") || loc.contains("youtu.be") { return .youtube }
        if loc.contains("soundcloud") { return .soundcloud }
        if loc.contains("spotify") { return .spotify }
        return .unknown
    }
}

/// Wraps a row so a single malformed element decodes to `nil` instead of throwing and killing the
/// whole array — the server's export is loosely typed and occasionally inconsistent.
struct FailableRow<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}

/// The assembled, app-ready result of importing a backup: the crate tree plus tunes-per-crate,
/// ready to hand to `LibraryStore`.
struct LibrarySnapshot: Sendable {
    var rootCrates: [Crate]                 // top-level (no parent)
    var childrenByCrate: [Int64: [Crate]]   // parent → ordered children
    var tunesByCrate: [Int64: [Tune]]       // crate → ordered tunes
    var allCratesByID: [Int64: Crate]
    /// Every imported tune, title-sorted — the local search corpus. A flat collection is
    /// required: tunesByCrate is only lazily hydrated after cold start, so scanning it would
    /// silently search nothing.
    var allTunes: [Tune]
    /// First 4 distinct cover IDs per crate (own tunes, then subtree BFS) — feeds the Home
    /// mosaic tiles. Computed at import (off-main) and persisted with the crate index so tiles
    /// render from cold start.
    var previewCoverIDsByCrate: [Int64: [Int64]] = [:]
    var tuneCount: Int
}
