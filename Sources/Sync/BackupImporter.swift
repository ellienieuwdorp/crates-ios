import Foundation
import ZIPFoundation

/// Unzips a `CratesBackup.zip` and joins its relational JSON tables into a `LibrarySnapshot` the
/// app can browse. Runs off the main actor (parsing tens of thousands of rows).
///
/// Join plan (verified against a real export):
///   Tunes ⨝ AudioFiles(bpm/key/codec) ⨝ Ratings → enriched Tune
///   Crates + CrateToCrates(hierarchy) → crate tree
///   CrateToTunes(ordering, per-crate date) → ordered tunes per crate
enum BackupImporter {
    struct Progress: Sendable { var stage: String; var fraction: Double }

    static func importBackup(zipURL: URL,
                             progress: @Sendable (Progress) -> Void = { _ in }) throws -> LibrarySnapshot {
        let fm = FileManager.default
        // Unique per call so overlapping imports can never read each other's half-written files.
        let dir = fm.temporaryDirectory.appendingPathComponent("crates-backup-\(UUID().uuidString)")
        try? fm.removeItem(at: dir)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        progress(.init(stage: "Unpacking", fraction: 0.1))
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

        progress(.init(stage: "Reading library", fraction: 0.35))
        let tuneRows = rows("Tunes.json", Backup.TuneRow.self)
        let crateRows = rows("Crates.json", Backup.CrateRow.self)
        let hierarchy = rows("CrateToCrates.json", Backup.CrateToCrateRow.self)
        let membership = rows("CrateToTunes.json", Backup.CrateToTuneRow.self)
        let audioFiles = rows("AudioFiles.json", Backup.AudioFileRow.self)
        let ratings = rows("Ratings.json", Backup.RatingRow.self)

        progress(.init(stage: "Building library", fraction: 0.6))

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
                pageURL: r.PageUrl
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

        progress(.init(stage: "Done", fraction: 1.0))
        return LibrarySnapshot(
            rootCrates: rootCrates,
            childrenByCrate: childrenByCrate,
            tunesByCrate: tunesByCrate,
            allCratesByID: crateByID,
            allTunes: tunesByID.values.sorted {
                $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending
            },
            tuneCount: tunesByID.count
        )
    }
}
