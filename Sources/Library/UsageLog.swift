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

@MainActor
@Observable
final class UsageLog {
    private(set) var byCrate: [Int64: CrateUsage] = [:]

    func hydrate() async {
        if byCrate.isEmpty,
           let cached: [Int64: CrateUsage] = await DiskCache.shared.load("usage_log_v1", as: [Int64: CrateUsage].self) {
            byCrate = cached
        }
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
