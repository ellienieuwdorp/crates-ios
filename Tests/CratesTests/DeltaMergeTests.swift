import Testing
import Foundation
@testable import CratesIOS

/// Delta-merge semantics (verified against the live server, dogfood round 3 W8):
/// lastSyncDate filters ONLY Tunes/AudioFiles/Covers (inclusive >=); every other table ships
/// full each sync; no tombstones — deletions are implicit in the always-full CrateToTunes.
struct DeltaMergeTests {
    private func tuneRow(_ id: Int64, title: String, modified: String? = nil) -> Backup.TuneRow {
        .init(TuneID: id, TuneTitle: title, TuneName: nil, Artist: "a", Album: nil, Genre: nil,
              TuneLength: nil, DateAdded: nil, DateLastModified: modified, CoverID: nil,
              PlayedCount: nil, DefaultAudioSourceType: 1, PageUrl: nil, TuneDefaultLocation: nil)
    }
    private func audioRow(_ id: Int64, tune: Int64, bpm: String, modified: String? = nil) -> Backup.AudioFileRow {
        .init(AudioFileID: id, TuneID: tune, Bpm: bpm, Key: nil, Codec: "MP3",
              FileType: nil, StorageType: nil, DateModified: modified)
    }
    private func membership(_ tuneIDs: [Int64]) -> [Backup.CrateToTuneRow] {
        tuneIDs.map { .init(CrateID: 1, TuneID: $0, TuneOrderingID: nil, DateModified: nil, PrimaryCrate: nil) }
    }

    @Test func deltaUpsertsChangedRowsAndKeepsUnchanged() {
        let cached: [Int64: Backup.TuneRow] = [1: tuneRow(1, title: "Old Title"), 2: tuneRow(2, title: "Two")]
        let incoming = BackupImporter.Tables(
            tunes: [tuneRow(1, title: "New Title", modified: "2026-07-04 15:00:00")],
            membership: membership([1, 2])
        )
        let merged = BackupImporter.merge(mode: .delta, incoming: incoming,
                                          cachedTunes: cached, cachedAudio: [:])
        #expect(merged.tunes[1]?.TuneTitle == "New Title") // updated
        #expect(merged.tunes[2]?.TuneTitle == "Two")       // untouched survives
    }

    @Test func deltaGCsTunesMissingFromFullMembership() {
        let cached: [Int64: Backup.TuneRow] = [1: tuneRow(1, title: "Keep"), 2: tuneRow(2, title: "Deleted on desktop")]
        let incoming = BackupImporter.Tables(membership: membership([1])) // tune 2 gone
        let merged = BackupImporter.merge(mode: .delta, incoming: incoming,
                                          cachedTunes: cached, cachedAudio: [:])
        #expect(merged.tunes.keys.sorted() == [1])
    }

    @Test func emptyMembershipNeverWipesTheCache() {
        // A truncated/corrupt CrateToTunes must not GC the whole library.
        let cached: [Int64: Backup.TuneRow] = [1: tuneRow(1, title: "One"), 2: tuneRow(2, title: "Two")]
        let incoming = BackupImporter.Tables() // all tables empty
        let merged = BackupImporter.merge(mode: .delta, incoming: incoming,
                                          cachedTunes: cached, cachedAudio: [:])
        #expect(merged.tunes.count == 2)
    }

    @Test func cursorIsMaxStampAcrossFilteredTables() {
        let incoming = BackupImporter.Tables(
            tunes: [tuneRow(1, title: "t", modified: "2026-07-04 14:00:00")],
            audio: [audioRow(9, tune: 1, bpm: "130", modified: "2026-07-04 16:30:00")],
            covers: [Backup.CoverRow(CoverID: 5, DateModified: "2026-07-04 15:00:00")]
        )
        let merged = BackupImporter.merge(mode: .delta, incoming: incoming,
                                          cachedTunes: [:], cachedAudio: [:])
        #expect(merged.cursor == "2026-07-04 16:30:00")
    }

    @Test func emptyDeltaYieldsNilCursor() {
        let merged = BackupImporter.merge(mode: .delta, incoming: .init(),
                                          cachedTunes: [:], cachedAudio: [:])
        #expect(merged.cursor == nil) // caller keeps the previous cursor (monotonic)
    }

    @Test func fullModeReplacesInsteadOfMerging() {
        let cached: [Int64: Backup.TuneRow] = [99: tuneRow(99, title: "Stale")]
        let incoming = BackupImporter.Tables(tunes: [tuneRow(1, title: "Fresh")], membership: membership([1]))
        let merged = BackupImporter.merge(mode: .full, incoming: incoming,
                                          cachedTunes: cached, cachedAudio: [:])
        #expect(merged.tunes.keys.sorted() == [1]) // stale cache discarded
    }

    @Test func audioDeltaMergesIndependentlyOfTunes() {
        // BPM re-analysis arrives as an AudioFiles row with no matching Tunes row.
        let cachedAudio: [Int64: Backup.AudioFileRow] = [9: audioRow(9, tune: 1, bpm: "128")]
        let incoming = BackupImporter.Tables(
            membership: membership([1]),
            audio: [audioRow(9, tune: 1, bpm: "131", modified: "2026-07-04 17:00:00")]
        )
        let merged = BackupImporter.merge(mode: .delta, incoming: incoming,
                                          cachedTunes: [1: tuneRow(1, title: "t")], cachedAudio: cachedAudio)
        #expect(merged.audio[9]?.Bpm == "131")
        // And the rebuilt snapshot picks up the new BPM through the normal join.
        let snap = BackupImporter.buildSnapshot(tunes: Array(merged.tunes.values),
                                                crates: [.init(CrateID: 1, Name: "c", CrateTypeID: nil, Hidden: false, ReleaseID: nil)],
                                                hierarchy: [], membership: incoming.membership,
                                                audio: Array(merged.audio.values), ratings: [])
        #expect(snap.tunesByCrate[1]?.first?.bpm == "131")
    }

    @Test func ratingRemovalAppliesOnRebuild() {
        // Ratings has no delta filter: the full table is re-applied every sync, so a rating
        // absent from it must vanish from the rebuilt tune.
        let tunes = [tuneRow(1, title: "t")]
        let with = BackupImporter.buildSnapshot(tunes: tunes,
                                                crates: [.init(CrateID: 1, Name: "c", CrateTypeID: nil, Hidden: false, ReleaseID: nil)],
                                                hierarchy: [], membership: membership([1]),
                                                audio: [], ratings: [.init(ObjectID: 1, RatingValue: 4)])
        let without = BackupImporter.buildSnapshot(tunes: tunes,
                                                   crates: [.init(CrateID: 1, Name: "c", CrateTypeID: nil, Hidden: false, ReleaseID: nil)],
                                                   hierarchy: [], membership: membership([1]),
                                                   audio: [], ratings: [])
        #expect(with.tunesByCrate[1]?.first?.rating == 4)
        #expect(without.tunesByCrate[1]?.first?.rating == nil)
    }
}
