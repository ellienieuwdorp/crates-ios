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

    /// First-run defaults so Home is never empty: the top root crates. Runs once per mode —
    /// a user who unpins everything gets an empty grid, not resurrected defaults.
    func seedIfNeeded(with crates: [Crate]) {
        guard ids.isEmpty, !crates.isEmpty, !UserDefaults.standard.bool(forKey: seededKey) else { return }
        ids = crates.prefix(6).map(\.id)
        UserDefaults.standard.set(true, forKey: seededKey)
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
