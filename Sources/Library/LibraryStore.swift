import Foundation
import Observation

/// Freshness state for any cached collection, so the UI can show a subtle "updating…" hint
/// without ever blocking on the network.
enum LoadState: Sendable, Equatable {
    case idle
    case revalidating   // showing cached data, fetching fresh in the background
    case live           // last fetch succeeded
    case failed(String) // showing cached data, last fetch failed
}

/// The cache-first library store. Every read returns cached data instantly and triggers a
/// background revalidation (stale-while-revalidate). In-flight refreshes are de-duplicated so
/// rapid navigation doesn't stampede the server. Disk-backed for instant cold start.
///
/// This is intentionally the *only* thing views talk to for library data — they never call the
/// network directly, which is what makes "the cache is the app" hold everywhere.
@MainActor
@Observable
final class LibraryStore {
    private(set) var rootCrates: [Crate] = []
    private(set) var recentCrates: [Crate] = []
    private(set) var tunesByCrate: [Int64: [Tune]] = [:]
    private(set) var childrenByCrate: [Int64: [Crate]] = [:]

    private(set) var rootState: LoadState = .idle
    private(set) var crateState: [Int64: LoadState] = [:]

    private var api: LibraryAPI?
    private var inFlight: Set<String> = []
    /// When true, demo data is authoritative and there is no server.
    private(set) var isDemoBacked = false
    /// When true, the library came from a bulk backup sync (the real onboarding path). That backup
    /// is the source of truth; per-crate REST revalidation is skipped (its list shapes aren't
    /// verified) — freshness comes from re-syncing the backup instead.
    private(set) var isSnapshotBacked = false

    /// Per-crate REST revalidation is suppressed whenever the library is authoritative offline.
    private var revalidationSuppressed: Bool { isDemoBacked || isSnapshotBacked }

    func attach(client: CratesClient) {
        api = LibraryAPI(client: client)
        isDemoBacked = false
    }

    // MARK: - Local search (the whole library is on-device; search never touches the network)

    private(set) var allTunes: [Tune] = []
    private var searchKeys: [(all: String, title: String, artist: String)] = []

    /// Install the flat library used by search and rebuild the folded-key index
    /// (~2k tunes → a few ms, fine on the main actor).
    func setAllTunes(_ tunes: [Tune]) {
        allTunes = tunes
        smartTunesCache = [:] // corpus changed → smart crates re-materialize lazily
        searchKeys = tunes.map {
            (all: Self.fold("\($0.title) \($0.artist) \($0.album)"),
             title: Self.fold($0.displayTitle),
             artist: Self.fold($0.displayArtist))
        }
    }

    /// Ranked, case/diacritic-insensitive token-AND search: every query token must appear
    /// somewhere; title-prefix beats title-contains beats artist-prefix. Results cap at 200.
    func searchTunes(_ query: String) -> [Tune] {
        let tokens = Self.fold(query).split(separator: " ").map(String.init)
        guard !tokens.isEmpty else { return [] }
        var scored: [(score: Int, index: Int)] = []
        for (i, key) in searchKeys.enumerated() {
            guard tokens.allSatisfy({ key.all.contains($0) }) else { continue }
            let first = tokens[0]
            let score: Int = key.title.hasPrefix(first) ? 3
                : key.title.contains(first) ? 2
                : key.artist.hasPrefix(first) ? 1 : 0
            scored.append((score, i))
        }
        return scored
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }
            .prefix(200)
            .map { allTunes[$0.index] }
    }

    private static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).lowercased()
    }

    // MARK: - Crate finder (the tree's problem is depth, not breadth — jump straight to a crate)

    struct CrateIndexEntry: Codable, Sendable, Identifiable {
        var crate: Crate
        /// Ancestor breadcrumb, e.g. "Collection › Techno" — empty for roots.
        var path: String
        /// First 4 distinct subtree cover IDs (Home mosaic tiles). Optional so pre-round-4
        /// cached indexes still decode; refreshed by the next sync.
        var previewCoverIDs: [Int64]? = nil
        var id: Int64 { crate.id }
    }

    private(set) var crateByID: [Int64: Crate] = [:]
    private(set) var crateIndex: [CrateIndexEntry] = []
    private var crateKeys: [String] = []
    private var previewCoversByCrate: [Int64: [Int64]] = [:]

    func crate(byID id: Int64) -> Crate? { crateByID[id] }
    /// Mosaic covers for a crate tile (empty = symbol fallback).
    func previewCoverIDs(for crateID: Int64) -> [Int64] { previewCoversByCrate[crateID] ?? [] }

    private func setCrateIndex(_ entries: [CrateIndexEntry]) {
        crateIndex = entries
        crateByID = Dictionary(entries.map { ($0.crate.id, $0.crate) }, uniquingKeysWith: { a, _ in a })
        crateKeys = entries.map { Self.fold("\($0.crate.name) \($0.path)") }
        previewCoversByCrate = Dictionary(
            entries.compactMap { e in e.previewCoverIDs.map { (e.crate.id, $0) } },
            uniquingKeysWith: { a, _ in a })
    }

    /// Token-AND crate search over name+path, name-prefix ranked first. Cap 50.
    func searchCrates(_ query: String) -> [CrateIndexEntry] {
        let tokens = Self.fold(query).split(separator: " ").map(String.init)
        guard !tokens.isEmpty else { return [] }
        var scored: [(score: Int, index: Int)] = []
        for (i, key) in crateKeys.enumerated() {
            guard tokens.allSatisfy({ key.contains($0) }) else { continue }
            let nameKey = Self.fold(crateIndex[i].crate.name)
            scored.append((nameKey.hasPrefix(tokens[0]) ? 1 : 0, i))
        }
        return scored
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }
            .prefix(50)
            .map { crateIndex[$0.index] }
    }

    /// Flatten the tree into breadcrumbed entries (BFS from roots; orphans get an empty path).
    private static func buildCrateIndex(roots: [Crate],
                                        children: [Int64: [Crate]],
                                        all: [Int64: Crate],
                                        previews: [Int64: [Int64]] = [:]) -> [CrateIndexEntry] {
        var entries: [CrateIndexEntry] = []
        var visited = Set<Int64>()
        var queue: [(Crate, String)] = roots.map { ($0, "") }
        while !queue.isEmpty {
            let (crate, path) = queue.removeFirst()
            guard visited.insert(crate.id).inserted else { continue }
            entries.append(CrateIndexEntry(crate: crate, path: path, previewCoverIDs: previews[crate.id]))
            let childPath = path.isEmpty ? crate.name : "\(path) › \(crate.name)"
            for child in children[crate.id] ?? [] { queue.append((child, childPath)) }
        }
        for (id, crate) in all where !visited.contains(id) {
            entries.append(CrateIndexEntry(crate: crate, path: "", previewCoverIDs: previews[id]))
        }
        return entries
    }

    /// Every tune in this crate AND its subtree, deduped by id, crate-order preserved per level.
    /// Async: unhydrated crates load from disk on the way down (cold start).
    func deepTunes(of crateID: Int64) async -> [Tune] {
        var result: [Tune] = []
        var seenTunes = Set<Int64>()
        var visited = Set<Int64>()
        var queue = [crateID]
        while !queue.isEmpty {
            let id = queue.removeFirst()
            guard visited.insert(id).inserted else { continue }
            var ts = tunesByCrate[id]
            if ts == nil, let cached: [Tune] = await DiskCache.shared.load("tunes_\(id)", as: [Tune].self) {
                tunesByCrate[id] = cached
                ts = cached
            }
            if (ts?.isEmpty ?? true), let crate = crateByID[id], crate.kind == .smart {
                ts = materializedSmartTunes(for: crate) // backup ships no smart memberships
            }
            for t in ts ?? [] where seenTunes.insert(t.id).inserted { result.append(t) }
            queue.append(contentsOf: (childrenByCrate[id] ?? []).map(\.id))
        }
        return result
    }

    /// Inject representative data for demo mode (no server). Marks everything `.live` so the UI
    /// looks settled rather than perpetually "updating".
    func loadDemoData(_ crates: [Crate], tunesByCrate: [Int64: [Tune]]) {
        isDemoBacked = true
        isSnapshotBacked = false
        rootCrates = crates
        recentCrates = Array(crates.prefix(4))
        self.tunesByCrate = tunesByCrate
        rootState = .live
        for id in tunesByCrate.keys { crateState[id] = .live }
        // Demo search corpus: dedupe the per-crate lists by id.
        var seen = Set<Int64>()
        setAllTunes(tunesByCrate.values.flatMap { $0 }.filter { seen.insert($0.id).inserted })
        var demoPreviews: [Int64: [Int64]] = [:]
        for (crateID, ts) in tunesByCrate {
            let covers = ts.prefix(8).compactMap(\.coverID)
            if !covers.isEmpty { demoPreviews[crateID] = Array(covers.prefix(4)) }
        }
        setCrateIndex(Self.buildCrateIndex(roots: crates, children: childrenByCrate,
                                           all: Dictionary(crates.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }),
                                           previews: demoPreviews))
    }

    /// Populate the whole library from a synced backup snapshot (the real onboarding path) and
    /// persist each piece to disk so subsequent cold starts are instant and offline-capable.
    func loadSnapshot(_ snapshot: LibrarySnapshot) {
        isDemoBacked = false
        isSnapshotBacked = true
        rootCrates = snapshot.rootCrates
        childrenByCrate = snapshot.childrenByCrate
        tunesByCrate = snapshot.tunesByCrate
        recentCrates = Array(snapshot.rootCrates.prefix(6))
        rootState = .live
        for id in snapshot.tunesByCrate.keys { crateState[id] = .live }

        setAllTunes(snapshot.allTunes)
        setCrateIndex(Self.buildCrateIndex(roots: snapshot.rootCrates,
                                           children: snapshot.childrenByCrate,
                                           all: snapshot.allCratesByID,
                                           previews: snapshot.previewCoverIDsByCrate))

        // Persist snapshot pieces so the next launch renders from disk before any network call.
        let roots = snapshot.rootCrates, recents = recentCrates
        let children = snapshot.childrenByCrate, tunes = snapshot.tunesByCrate
        let all = snapshot.allTunes, index = crateIndex
        Task.detached {
            await DiskCache.shared.save(roots, key: "root_crates")
            await DiskCache.shared.save(recents, key: "recent_crates")
            await DiskCache.shared.save(all, key: "all_tunes")
            await DiskCache.shared.save(index, key: "crate_index")
            await DiskCache.shared.save(children, key: "children_map")
            for (id, kids) in children { await DiskCache.shared.save(kids, key: "children_\(id)") }
            for (id, ts) in tunes { await DiskCache.shared.save(ts, key: "tunes_\(id)") }
        }
    }

    /// Load persisted snapshots so the first render is populated before any network call.
    func hydrateFromDisk() async {
        if let c: [Crate] = await DiskCache.shared.load("root_crates", as: [Crate].self) {
            rootCrates = c
        }
        if let r: [Crate] = await DiskCache.shared.load("recent_crates", as: [Crate].self) {
            recentCrates = r
        }
        if let all: [Tune] = await DiskCache.shared.load("all_tunes", as: [Tune].self) {
            setAllTunes(all)
        }
        if let index: [CrateIndexEntry] = await DiskCache.shared.load("crate_index", as: [CrateIndexEntry].self) {
            setCrateIndex(index)
        }
        if let children: [Int64: [Crate]] = await DiskCache.shared.load("children_map", as: [Int64: [Crate]].self) {
            childrenByCrate = children
        }
    }

    /// Mark the (disk-hydrated) library as backup-backed on a paired relaunch, so per-crate REST
    /// revalidation stays suppressed and freshness comes from re-syncing the backup.
    func markSnapshotBacked() {
        isSnapshotBacked = true
        if !rootCrates.isEmpty { rootState = .live }
    }

    // MARK: - Reads (cache-first)

    @discardableResult
    func refreshRoot() -> Task<Void, Never>? {
        revalidate(key: "root", state: { self.rootState = $0 }) { [weak self] in
            guard let api = self?.api else { return }
            async let roots = api.defaultCrates()
            async let recents = try? api.recentCrates()
            let (r, rec) = try await (roots, recents)
            await MainActor.run {
                self?.rootCrates = r
                if let rec { self?.recentCrates = rec }
            }
            await DiskCache.shared.save(r, key: "root_crates")
            if let rec { await DiskCache.shared.save(rec, key: "recent_crates") }
        }
    }

    func tunes(in crateID: Int64) -> [Tune] {
        // Smart crates ship ZERO memberships in the backup — materialize from their stored
        // query instead (cached after first computation; invalidated on library reload).
        if let cached = tunesByCrate[crateID], !cached.isEmpty { return cached }
        if let crate = crateByID[crateID], crate.kind == .smart {
            return materializedSmartTunes(for: crate)
        }
        return tunesByCrate[crateID] ?? []
    }
    func children(of crateID: Int64) -> [Crate] { childrenByCrate[crateID] ?? [] }
    func state(for crateID: Int64) -> LoadState { crateState[crateID] ?? .idle }

    // MARK: - Smart crates (client-side materialization; see docs/design/home-browse-redesign.md)

    private var smartTunesCache: [Int64: [Tune]] = [:]

    /// True when this smart crate has a query we can't evaluate locally — the UI shows an
    /// honest "computed on the desktop" state instead of a silently-empty list.
    func smartCrateUnsupported(_ crate: Crate) -> Bool {
        guard crate.kind == .smart else { return false }
        guard let q = crate.smartQuery, !q.isEmpty else { return true } // definition not fetched (offline before first sync)
        return SmartQuery.parse(q) == nil
    }

    private func materializedSmartTunes(for crate: Crate) -> [Tune] {
        if let hit = smartTunesCache[crate.id] { return hit }
        guard let raw = crate.smartQuery, let query = SmartQuery.parse(raw) else { return [] }
        // Newest first: a genre crate is a listening feed, and dateAdded is the only ordering
        // the query itself doesn't define.
        let result = allTunes.filter { query.matches($0) }
            .sorted { ($0.dateAdded ?? .distantPast) > ($1.dateAdded ?? .distantPast) }
        smartTunesCache[crate.id] = result
        return result
    }

    /// Fetch smart-crate definitions (their stored queries) — live-only data the backup strips.
    /// Runs after every sync; results are folded into the crate index and persisted with it.
    func hydrateSmartQueries() async {
        guard let api, !isDemoBacked else { return }
        let smartIDs = crateIndex.filter { $0.crate.kind == .smart && $0.crate.smartQuery == nil }
            .map(\.crate.id)
        guard !smartIDs.isEmpty else { return }
        var queries: [Int64: String] = [:]
        for id in smartIDs {
            guard let details = try? await api.crateDetails(id) else { continue }
            queries[id] = details.smartQuery ?? "" // "" = fetched, has no query (still unsupported)
        }
        guard !queries.isEmpty else { return }
        applySmartQueries(queries)
        let index = crateIndex
        Task.detached { await DiskCache.shared.save(index, key: "crate_index") }
    }

    /// Testable seam: fold fetched queries into every crate-bearing structure.
    func applySmartQueries(_ queries: [Int64: String]) {
        func patch(_ c: inout Crate) {
            if let q = queries[c.id] { c.smartQuery = q }
        }
        var entries = crateIndex
        for i in entries.indices { patch(&entries[i].crate) }
        setCrateIndex(entries)
        for i in rootCrates.indices { patch(&rootCrates[i]) }
        for key in childrenByCrate.keys {
            for i in (childrenByCrate[key] ?? []).indices { patch(&childrenByCrate[key]![i]) }
        }
        smartTunesCache = [:]
    }

    /// Test seam: install crates into the index (smart-crate materialization reads crateByID).
    func applySmartQueriesForTesting(crates: [Crate]) {
        setCrateIndex(crates.map { CrateIndexEntry(crate: $0, path: "") })
        smartTunesCache = [:]
    }

    // MARK: - Curation (Home seeds, Browse roots) — the honesty rules

    /// True when auto-surfacing this crate anywhere would be dishonest or useless: hidden,
    /// system plumbing, the file mirror, or (for non-smart crates) verifiably empty.
    private func isSurfaceable(_ crate: Crate) -> Bool {
        if crate.isHidden || crate.isFolderMirror { return false }
        if crate.kind == .playlist || crate.kind == .history || crate.kind == .search { return false }
        if crate.kind == .smart { return !tunes(in: crate.id).isEmpty }
        return (crate.tuneCount ?? 0) > 0 || crate.hasChildren
    }

    /// Home pin seeds, in priority order (see design doc): the user's own hand-built listening
    /// taxonomy first (DJ Library's smart crates, only those that materialize non-empty), then
    /// Collection's curated children, then surfaceable roots.
    func seedCandidates(limit: Int = 6) -> [Crate] {
        var out: [Crate] = []
        var seen = Set<Int64>()
        func add(_ crates: [Crate]) {
            for c in crates where out.count < limit {
                guard isSurfaceable(c), seen.insert(c.id).inserted else { continue }
                out.append(c)
            }
        }
        if let djLibrary = crateIndex.first(where: { $0.crate.kind == .root && $0.crate.name == "DJ Library" })?.crate {
            add(children(of: djLibrary.id))
        }
        if let collection = rootOrChild(named: "Collection") {
            add(children(of: collection.id))
        }
        add(rootCrates)
        return out
    }

    private func rootOrChild(named name: String) -> Crate? {
        crateIndex.first { $0.crate.name == name && $0.crate.kind == .root }?.crate
    }

    /// Browse's root list: the desktop's own signals, honored — no hidden crates, no verifiably
    /// dead roots. (`Library` root keeps its place even with 0 direct tunes via hasChildren.)
    var browseRoots: [Crate] {
        rootCrates.filter { !$0.isHidden && (($0.tuneCount ?? 0) > 0 || $0.hasChildren) }
    }

    // MARK: - Facets (Artists / Genres) — derived from the synced corpus, deduped

    struct Facet: Identifiable, Sendable, Equatable {
        var name: String
        var tuneCount: Int
        var id: String { name.lowercased() }
    }

    /// A–Z artists with tune counts, case-insensitively deduped (first spelling wins — the
    /// desktop's own Artists shelf shows literal duplicates; ours must not).
    func artistFacets() -> [Facet] {
        var counts: [String: (display: String, count: Int)] = [:]
        for t in allTunes {
            let display = t.displayArtist
            let key = display.lowercased()
            counts[key, default: (display, 0)].count += 1
        }
        return counts.values
            .map { Facet(name: $0.display, tuneCount: $0.count) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Genres by tune count (desc) from the genre join + legacy tag, deduped like artists.
    func genreFacets() -> [Facet] {
        var counts: [String: (display: String, count: Int)] = [:]
        for t in allTunes {
            var names = t.genres
            if names.isEmpty, let g = t.genre, !g.isEmpty { names = [g] }
            var seen = Set<String>()
            for n in names {
                let key = n.lowercased()
                guard seen.insert(key).inserted else { continue }
                counts[key, default: (n, 0)].count += 1
            }
        }
        return counts.values
            .map { Facet(name: $0.display, tuneCount: $0.count) }
            .sorted { $0.tuneCount != $1.tuneCount ? $0.tuneCount > $1.tuneCount
                    : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func tunes(byArtist name: String) -> [Tune] {
        let key = name.lowercased()
        return allTunes.filter { $0.displayArtist.lowercased() == key }
    }

    func tunes(byGenre name: String) -> [Tune] {
        let key = name.lowercased()
        return allTunes.filter { t in
            t.genres.contains { $0.lowercased() == key } || t.genre?.lowercased() == key
        }
    }

    // MARK: - Home shelves (each renders ONLY when non-empty — the honesty rule)

    /// Playable-now filter for listening shelves: server audio, or a Bandcamp page we can
    /// preview. Unknown (nil) stays in — never hide on a guess.
    private func shelfPlayable(_ t: Tune) -> Bool {
        !t.knownUnstreamable || (t.source == .bandcamp && t.pageURL != nil)
    }

    /// "What's new since I synced": newest first by dateAdded.
    func recentlyAddedTunes(limit: Int = 20) -> [Tune] {
        allTunes.filter { shelfPlayable($0) && $0.dateAdded != nil }
            .sorted { $0.dateAdded! > $1.dateAdded! }
            .prefix(limit).map { $0 }
    }

    /// The desktop's best idea, stolen: rated tunes you haven't played on THIS device recently,
    /// best-rated first. `recentlyPlayedIDs` comes from the local usage log.
    func forgottenFavorites(excluding recentlyPlayedIDs: Set<Int64>, limit: Int = 20) -> [Tune] {
        allTunes.filter { shelfPlayable($0) && ($0.rating ?? 0) > 0 && !recentlyPlayedIDs.contains($0.id) }
            .sorted { ($0.rating ?? 0) != ($1.rating ?? 0) ? ($0.rating ?? 0) > ($1.rating ?? 0)
                    : ($0.dateAdded ?? .distantPast) < ($1.dateAdded ?? .distantPast) }
            .prefix(limit).map { $0 }
    }

    /// Tunes for the local recently-played shelf, newest first, in log order.
    func tunes(byIDs ids: [Int64]) -> [Tune] {
        let byID = Dictionary(allTunes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return ids.compactMap { byID[$0] }
    }

    /// Open a crate: serve cached tunes immediately (caller reads `tunes(in:)`), revalidate behind.
    @discardableResult
    func refreshTunes(in crateID: Int64) -> Task<Void, Never>? {
        // Warm from disk if we have nothing in memory yet.
        if tunesByCrate[crateID] == nil {
            Task { [weak self] in
                if let cached: [Tune] = await DiskCache.shared.load("tunes_\(crateID)", as: [Tune].self) {
                    await MainActor.run { if self?.tunesByCrate[crateID] == nil { self?.tunesByCrate[crateID] = cached } }
                }
            }
        }
        return revalidate(key: "tunes_\(crateID)", state: { self.crateState[crateID] = $0 }) { [weak self] in
            guard let api = self?.api else { return }
            let fresh = try await api.tunes(inCrate: crateID)
            await MainActor.run { self?.tunesByCrate[crateID] = fresh }
            await DiskCache.shared.save(fresh, key: "tunes_\(crateID)")
        }
    }

    @discardableResult
    func refreshChildren(of crateID: Int64) -> Task<Void, Never>? {
        // Warm from disk so the crate hierarchy survives cold start / offline (same as tunes).
        if childrenByCrate[crateID] == nil {
            Task { [weak self] in
                if let cached: [Crate] = await DiskCache.shared.load("children_\(crateID)", as: [Crate].self) {
                    await MainActor.run { if self?.childrenByCrate[crateID] == nil { self?.childrenByCrate[crateID] = cached } }
                }
            }
        }
        return revalidate(key: "children_\(crateID)", state: { _ in }) { [weak self] in
            guard let api = self?.api else { return }
            let fresh = try await api.children(of: crateID)
            await MainActor.run { self?.childrenByCrate[crateID] = fresh }
            await DiskCache.shared.save(fresh, key: "children_\(crateID)")
        }
    }

    // MARK: - Revalidation engine

    /// Runs `work` unless an identical refresh is already in flight. Updates `state` through the
    /// revalidating → live/failed lifecycle. Never throws to the caller; failures leave cached
    /// data on screen and surface as `.failed`.
    ///
    /// Results are discarded if demo mode takes over mid-flight — otherwise an in-flight network
    /// failure lands *after* `loadDemoData` and stamps `.failed` over authoritative demo state.
    /// Returns the refresh Task so pull-to-refresh can await actual completion.
    @discardableResult
    private func revalidate(key: String,
                            state: @escaping (LoadState) -> Void,
                            work: @escaping () async throws -> Void) -> Task<Void, Never>? {
        guard !revalidationSuppressed else { return nil }
        guard !inFlight.contains(key) else { return nil }
        inFlight.insert(key)
        state(.revalidating)
        return Task { [weak self] in
            defer { self?.inFlight.remove(key) }
            do {
                try await work()
                guard self?.revalidationSuppressed == false else { return }
                state(.live)
            } catch {
                guard self?.revalidationSuppressed == false else { return }
                state(.failed((error as? CratesAPIError)?.errorDescription ?? "\(error)"))
            }
        }
    }
}
