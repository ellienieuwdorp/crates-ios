import Foundation
import ZIPFoundation

/// Unzips a `CratesBackup.zip` and joins its relational JSON tables into a `LibrarySnapshot` the
/// app can browse. Runs off the main actor (parsing tens of thousands of rows).
///
/// Join plan (verified against a real export):
///   Tunes ⨝ AudioFiles(bpm/key/codec) ⨝ Ratings → enriched Tune
///   Crates + CrateToCrates(hierarchy) → crate tree
///   CrateToTunes(ordering, per-crate date) → ordered tunes per crate
///
/// Delta semantics (verified against the LIVE server, dogfood round 3 W8): `lastSyncDate`
/// filters ONLY Tunes/AudioFiles/Covers (inclusive >=, empty arrays when unchanged); every
/// other table ships FULL on every request, and there are no tombstones — so the merge upserts
/// the filtered tables into raw caches by PK, treats the full tables as replacements, and GCs
/// tunes that vanished from the always-full CrateToTunes.
enum BackupImporter {
    struct Progress: Sendable { var stage: String; var fraction: Double }

    enum SyncMode: Sendable { case full, delta }

    /// Everything a sync produces: the browsable snapshot plus the raw caches and cursor the
    /// NEXT delta needs.
    struct MergeResult: Sendable {
        var snapshot: LibrarySnapshot
        var rawTunes: [Int64: Backup.TuneRow]
        var rawAudio: [Int64: Backup.AudioFileRow]
        /// Lexicographic max of every DateLastModified/DateModified stamp seen in the payload's
        /// filtered tables — the server's own clock, never the device's. Nil if none appeared.
        var newCursor: String?
        /// Covers rows in a DELTA payload passed the server's since-cursor filter — each is a
        /// changed cover the art cache must drop. Empty on full sync BY CONSTRUCTION: a full
        /// payload ships the entire Covers table and would wipe the whole ~112MB cache.
        var changedCoverIDs: [Int64] = []
    }

    /// The decoded backup tables. Internal so merge logic is unit-testable without zips.
    struct Tables: Sendable {
        var tunes: [Backup.TuneRow] = []
        var crates: [Backup.CrateRow] = []
        var hierarchy: [Backup.CrateToCrateRow] = []
        var membership: [Backup.CrateToTuneRow] = []
        var audio: [Backup.AudioFileRow] = []
        var ratings: [Backup.RatingRow] = []
        var covers: [Backup.CoverRow] = []
    }

    /// Compatibility entry point: full import, raw caches discarded (existing tests + callers
    /// that only want the snapshot).
    static func importBackup(zipURL: URL,
                             progress: @Sendable (Progress) -> Void = { _ in }) throws -> LibrarySnapshot {
        try importBackup(zipURL: zipURL, mode: .full, cachedTunes: [:], cachedAudio: [:], progress: progress).snapshot
    }

    static func importBackup(zipURL: URL,
                             mode: SyncMode,
                             cachedTunes: [Int64: Backup.TuneRow],
                             cachedAudio: [Int64: Backup.AudioFileRow],
                             progress: @Sendable (Progress) -> Void = { _ in }) throws -> MergeResult {
        progress(.init(stage: "Unpacking", fraction: 0.1))
        let tables = try decodeTables(zipURL: zipURL)

        progress(.init(stage: "Building library", fraction: 0.6))
        let merged = merge(mode: mode, incoming: tables, cachedTunes: cachedTunes, cachedAudio: cachedAudio)
        let snapshot = buildSnapshot(tunes: Array(merged.tunes.values),
                                     crates: tables.crates,
                                     hierarchy: tables.hierarchy,
                                     membership: tables.membership,
                                     audio: Array(merged.audio.values),
                                     ratings: tables.ratings)

        progress(.init(stage: "Done", fraction: 1.0))
        return MergeResult(snapshot: snapshot,
                           rawTunes: merged.tunes,
                           rawAudio: merged.audio,
                           newCursor: merged.cursor,
                           changedCoverIDs: mode == .delta ? tables.covers.compactMap(\.CoverID) : [])
    }

    // MARK: - Decode

    static func decodeTables(zipURL: URL) throws -> Tables {
        let fm = FileManager.default
        // Unique per call so overlapping imports can never read each other's half-written files.
        let dir = fm.temporaryDirectory.appendingPathComponent("crates-backup-\(UUID().uuidString)")
        try? fm.removeItem(at: dir)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        try fm.unzipItem(at: zipURL, to: dir)

        // Resilient per-row decode: the server's JSON is loosely typed (numbers as strings, fields
        // that come and go), so one malformed row must not wipe an entire table.
        func rows<T: Decodable>(_ name: String, _ type: T.Type) -> [T] {
            let url = dir.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url) else { return [] }
            let dec = JSONDecoder()
            if let strict = try? dec.decode([T].self, from: data) { return strict }
            // Fall back to element-wise decoding, skipping rows that fail.
            guard let wrapped = try? dec.decode([FailableRow<T>].self, from: data) else { return [] }
            return wrapped.compactMap(\.value)
        }

        return Tables(
            tunes: rows("Tunes.json", Backup.TuneRow.self),
            crates: rows("Crates.json", Backup.CrateRow.self),
            hierarchy: rows("CrateToCrates.json", Backup.CrateToCrateRow.self),
            membership: rows("CrateToTunes.json", Backup.CrateToTuneRow.self),
            audio: rows("AudioFiles.json", Backup.AudioFileRow.self),
            ratings: rows("Ratings.json", Backup.RatingRow.self),
            covers: rows("Covers.json", Backup.CoverRow.self)
        )
    }

    // MARK: - Merge (unit-tested without zips)

    /// Upsert the delta-filtered tables into the raw caches by PK, GC tunes that vanished from
    /// the always-full CrateToTunes, and compute the next cursor from the payload's own stamps.
    static func merge(mode: SyncMode,
                      incoming: Tables,
                      cachedTunes: [Int64: Backup.TuneRow],
                      cachedAudio: [Int64: Backup.AudioFileRow])
        -> (tunes: [Int64: Backup.TuneRow], audio: [Int64: Backup.AudioFileRow], cursor: String?) {
        var tunes = (mode == .full) ? [:] : cachedTunes
        var audio = (mode == .full) ? [:] : cachedAudio
        for r in incoming.tunes { tunes[r.TuneID] = r }                       // idempotent upsert
        for r in incoming.audio { if let id = r.AudioFileID { audio[id] = r } else if let t = r.TuneID { audio[-t] = r } }

        if mode == .delta {
            // Deletions have no tombstones; a tune that left the library disappears from the
            // always-full CrateToTunes. Guard: an empty/corrupt membership table must never
            // wipe the cache.
            let live = Set(incoming.membership.map(\.TuneID))
            if !live.isEmpty {
                tunes = tunes.filter { live.contains($0.key) }
                audio = audio.filter { row in row.value.TuneID.map(live.contains) ?? true }
            }
        }

        // Cursor: server-frame stamps only (device clock and TZ are unusable — stamps are
        // server-local wall time). Lexicographic max works because the format is sortable.
        let stamps = incoming.tunes.compactMap(\.DateLastModified)
            + incoming.audio.compactMap(\.DateModified)
            + incoming.covers.compactMap(\.DateModified)
        return (tunes, audio, stamps.max())
    }

    // MARK: - Join

    static func buildSnapshot(tunes tuneRows: [Backup.TuneRow],
                              crates crateRows: [Backup.CrateRow],
                              hierarchy: [Backup.CrateToCrateRow],
                              membership: [Backup.CrateToTuneRow],
                              audio audioFiles: [Backup.AudioFileRow],
                              ratings: [Backup.RatingRow]) -> LibrarySnapshot {
        // Side tables keyed by tune.
        let audioByTune = Dictionary(audioFiles.compactMap { r in r.TuneID.map { ($0, r) } },
                                     uniquingKeysWith: { a, _ in a })
        let ratingByTune = Dictionary(ratings.compactMap { r in r.ObjectID.map { ($0, r.RatingValue) } },
                                      uniquingKeysWith: { a, _ in a })

        // Enriched tunes by id.
        var tunesByID: [Int64: Tune] = [:]
        tunesByID.reserveCapacity(tuneRows.count)
        for r in tuneRows {
            let audio = audioByTune[r.TuneID]
            let title = (r.TuneTitle?.isEmpty == false ? r.TuneTitle : r.TuneName) ?? ""
            tunesByID[r.TuneID] = Tune(
                id: r.TuneID,
                title: title,
                artist: r.Artist ?? "",
                album: r.Album ?? "",
                genre: r.Genre,
                lengthSeconds: Tune.parseLength(r.TuneLength),
                bpm: audio?.Bpm,
                key: audio?.Key,
                rating: ratingByTune[r.TuneID] ?? nil,
                coverID: r.CoverID,
                dateAdded: Tune.parseDate(r.DateAdded),
                source: Backup.source(forTypeID: r.DefaultAudioSourceType, location: r.TuneDefaultLocation),
                pageURL: r.PageUrl,
                // The server refuses to stream tunes without a codec ("Codec of the tune is
                // null") — mark them so rows can be honest up front instead of tap → error.
                hasServerAudio: audio?.Codec != nil
            )
        }

        // Crate objects (skip hidden).
        var crateByID: [Int64: Crate] = [:]
        for r in crateRows where !(r.Hidden ?? false) {
            crateByID[r.CrateID] = Crate(
                id: r.CrateID,
                name: r.Name ?? "Untitled Crate",
                tuneCount: nil,
                parentID: nil,
                hasChildren: false,
                kind: Crate.kind(forTypeID: r.CrateTypeID, name: r.Name ?? "")
            )
        }

        // Hierarchy: children per parent (ordered), and which crates have a parent.
        var childIDsByParent: [Int64: [(Int64, Int)]] = [:]
        var hasParent = Set<Int64>()
        for h in hierarchy {
            guard let p = h.ParentCrateID, let c = h.ChildCrateID else { continue }
            childIDsByParent[p, default: []].append((c, h.CrateOrderingID ?? 0))
            hasParent.insert(c)
        }
        for (p, kids) in childIDsByParent {
            guard crateByID[p] != nil else { continue }
            let hasVisibleChild = kids.contains { crateByID[$0.0] != nil }
            crateByID[p]?.hasChildren = hasVisibleChild
        }
        var childrenByCrate: [Int64: [Crate]] = [:]
        for (p, kids) in childIDsByParent {
            childrenByCrate[p] = kids.sorted { $0.1 < $1.1 }.compactMap { crateByID[$0.0] }
        }

        // Membership: ordered tunes per crate (by TuneOrderingID); tune count per crate.
        var tuneRefsByCrate: [Int64: [(Int64, Int)]] = [:]
        for m in membership {
            tuneRefsByCrate[m.CrateID, default: []].append((m.TuneID, m.TuneOrderingID ?? 0))
        }
        var tunesByCrate: [Int64: [Tune]] = [:]
        for (crateID, refs) in tuneRefsByCrate {
            let ordered = refs.sorted { $0.1 < $1.1 }.compactMap { tunesByID[$0.0] }
            tunesByCrate[crateID] = ordered
            crateByID[crateID]?.tuneCount = ordered.count
        }

        // Roots = crates with no parent that still exist.
        let rootCrates = crateByID.values
            .filter { !hasParent.contains($0.id) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        // Mosaic previews: first 4 distinct covers per crate — own tunes first, then a bounded
        // BFS into the subtree (container crates like "Collection" hold no direct tunes).
        var previewCoverIDsByCrate: [Int64: [Int64]] = [:]
        for crateID in crateByID.keys {
            var covers: [Int64] = []
            var seenCovers = Set<Int64>()
            var visited = Set<Int64>()
            var queue = [crateID]
            var hops = 0
            while !queue.isEmpty, covers.count < 4, hops < 64 { // bound: deep trees stay cheap
                let id = queue.removeFirst()
                hops += 1
                guard visited.insert(id).inserted else { continue }
                for tune in tunesByCrate[id] ?? [] {
                    if let c = tune.coverID, seenCovers.insert(c).inserted {
                        covers.append(c)
                        if covers.count == 4 { break }
                    }
                }
                queue.append(contentsOf: (childIDsByParent[id] ?? []).sorted { $0.1 < $1.1 }.map(\.0))
            }
            if !covers.isEmpty { previewCoverIDsByCrate[crateID] = covers }
        }

        return LibrarySnapshot(
            rootCrates: rootCrates,
            childrenByCrate: childrenByCrate,
            tunesByCrate: tunesByCrate,
            allCratesByID: crateByID,
            allTunes: tunesByID.values.sorted {
                $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending
            },
            previewCoverIDsByCrate: previewCoverIDsByCrate,
            tuneCount: tunesByID.count
        )
    }
}
