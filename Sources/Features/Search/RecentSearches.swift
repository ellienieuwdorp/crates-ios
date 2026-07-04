import Foundation
import Observation

/// MRU list of committed search queries (dogfood round 3, item 9). Queries — not results —
/// because results go stale as the library re-syncs while re-running a query is a free local
/// scan. Plain string array in UserDefaults; capped at 10.
@MainActor
@Observable
final class RecentSearches {
    private static let key = "search.recentQueries"
    private static let cap = 10

    private(set) var queries: [String] = UserDefaults.standard.stringArray(forKey: key) ?? []

    /// Record a committed query (Search key or result tap — never per keystroke).
    /// Most recent first, case-insensitive dedupe.
    func record(_ raw: String) {
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        queries.removeAll { $0.caseInsensitiveCompare(q) == .orderedSame }
        queries.insert(q, at: 0)
        if queries.count > Self.cap { queries.removeLast(queries.count - Self.cap) }
        persist()
    }

    func remove(at offsets: IndexSet) {
        queries.remove(atOffsets: offsets)
        persist()
    }

    func clear() {
        queries = []
        persist()
    }

    private func persist() { UserDefaults.standard.set(queries, forKey: Self.key) }
}
