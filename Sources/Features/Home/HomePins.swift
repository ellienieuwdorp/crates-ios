import Foundation
import Observation

/// User-pinned Home hotlinks (dogfood round 3, W7). Pins are the grid's contract: stable,
/// user-owned thumb targets — usage data may *suggest* pins later but never reorders them.
/// Demo and paired modes keep separate pin sets so switching never shows dangling IDs.
@MainActor
@Observable
final class HomePins {
    private var key = "home.pins"
    private var seededKey: String { key + ".seeded" }
    private(set) var ids: [Int64] = []

    func configure(demo: Bool) {
        key = demo ? "home.pins.demo" : "home.pins"
        ids = (UserDefaults.standard.array(forKey: key) as? [NSNumber])?.map(\.int64Value) ?? []
    }

    private var seededV2Key: String { key + ".seeded.v2" }

    /// First-run defaults so Home is never empty. Runs once per mode — a user who unpins
    /// everything gets an empty grid, not resurrected defaults.
    ///
    /// v2 (2026-07-10, home-browse-redesign): candidates come from
    /// `LibraryStore.seedCandidates()` (genre smart crates → Collection children → live roots)
    /// instead of the first 6 roots — the old seed pinned Inbox/empty iTunes/hidden Archive,
    /// the exact "tiles that don't exist" complaint. Migration: an existing pin set still
    /// identical to the old default is replaced once; anything the user touched is kept.
    func seedIfNeeded(candidates: [Crate], oldDefault: [Crate]) {
        guard !UserDefaults.standard.bool(forKey: seededV2Key), !candidates.isEmpty else { return }
        let untouchedV1 = !ids.isEmpty && Set(ids) == Set(oldDefault.prefix(6).map(\.id))
        if ids.isEmpty {
            guard !UserDefaults.standard.bool(forKey: seededKey) else { return } // deliberate empty grid
        } else if !untouchedV1 {
            UserDefaults.standard.set(true, forKey: seededV2Key) // customized — never touch
            return
        }
        ids = candidates.map(\.id)
        UserDefaults.standard.set(true, forKey: seededKey)
        UserDefaults.standard.set(true, forKey: seededV2Key)
        persist()
    }

    func isPinned(_ id: Int64) -> Bool { ids.contains(id) }

    /// Appends at the END: the grid is bottom-anchored, so the end of the array is the slot
    /// closest to the thumb.
    func pin(_ id: Int64) {
        guard !ids.contains(id) else { return }
        ids.append(id)
        persist()
    }

    func unpin(_ id: Int64) {
        ids.removeAll { $0 == id }
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(ids.map(NSNumber.init(value:)), forKey: key)
    }
}
