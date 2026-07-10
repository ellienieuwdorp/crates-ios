import Foundation
import Observation

/// Per-crate usage counters, purely local (dogfood round 3, W7). Two signals: opens (browsing)
/// and plays (commitment). Powers the Home recents row today and "suggested pins" later —
/// never auto-reordering of the pinned grid (stable thumb targets are the point of pins).
struct CrateUsage: Codable, Sendable {
    var opens = 0
    var plays = 0
    var lastOpened: Date? = nil
    var lastPlayed: Date? = nil
    var lastTouched: Date { max(lastOpened ?? .distantPast, lastPlayed ?? .distantPast) }
}

/// One tune-level play event (newest kept first in the log).
struct TunePlay: Codable, Sendable, Equatable {
    var tuneID: Int64
    var playedAt: Date
}

@MainActor
@Observable
final class UsageLog {
    private(set) var byCrate: [Int64: CrateUsage] = [:]
    /// Tune-level plays, newest first, deduped by tune (a tune moves to the front on replay).
    /// This is the phone's truthful "Recently Played" — local by design; the desktop's
    /// crate-level equivalent provably surfaces junk (see desktop-workflow report).
    private(set) var recentTunes: [TunePlay] = []
    private static let recentTunesCap = 50

    func hydrate() async {
        if byCrate.isEmpty,
           let cached: [Int64: CrateUsage] = await DiskCache.shared.load("usage_log_v1", as: [Int64: CrateUsage].self) {
            byCrate = cached
        }
        if recentTunes.isEmpty,
           let cached: [TunePlay] = await DiskCache.shared.load("recent_tunes_v1", as: [TunePlay].self) {
            recentTunes = cached
        }
    }

    func recordTunePlay(_ tuneID: Int64) {
        recentTunes.removeAll { $0.tuneID == tuneID }
        recentTunes.insert(TunePlay(tuneID: tuneID, playedAt: Date()), at: 0)
        if recentTunes.count > Self.recentTunesCap {
            recentTunes.removeLast(recentTunes.count - Self.recentTunesCap)
        }
        let snapshot = recentTunes
        Task.detached { await DiskCache.shared.save(snapshot, key: "recent_tunes_v1") }
    }

    /// Newest-first tune ids for the Home shelf.
    func recentTuneIDs(limit: Int = 20) -> [Int64] {
        recentTunes.prefix(limit).map(\.tuneID)
    }

    /// Tunes played on this device within `days` — the "don't call it forgotten" exclusion set.
    func tuneIDsPlayed(withinDays days: Int) -> Set<Int64> {
        let cutoff = Date().addingTimeInterval(-Double(days) * 24 * 3600)
        return Set(recentTunes.lazy.filter { $0.playedAt > cutoff }.map(\.tuneID))
    }

    func recordOpen(_ crateID: Int64) {
        byCrate[crateID, default: CrateUsage()].opens += 1
        byCrate[crateID]?.lastOpened = Date()
        persist()
    }

    func recordPlay(_ crateID: Int64) {
        byCrate[crateID, default: CrateUsage()].plays += 1
        byCrate[crateID]?.lastPlayed = Date()
        persist()
    }

    /// Most-recently-touched crates, newest first.
    func recentCrateIDs(limit: Int = 8) -> [Int64] {
        byCrate.sorted { $0.value.lastTouched > $1.value.lastTouched }
            .prefix(limit)
            .map(\.key)
    }

    private func persist() {
        // Prune entries idle for 90+ days so the log stays a small dictionary forever.
        let cutoff = Date().addingTimeInterval(-90 * 24 * 3600)
        byCrate = byCrate.filter { $0.value.lastTouched > cutoff }
        let snapshot = byCrate
        Task.detached { await DiskCache.shared.save(snapshot, key: "usage_log_v1") }
    }
}
