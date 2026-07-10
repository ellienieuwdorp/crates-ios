import Foundation

/// A crate (Crates' unit of organization — a folder/playlist hybrid that can nest). Mirrors the
/// fields of `CratePresentationBean` / `CrateBasicPresentationBean` the POC uses.
struct Crate: Identifiable, Hashable, Sendable, Codable {
    let id: Int64
    var name: String
    var tuneCount: Int?
    var parentID: Int64?
    var hasChildren: Bool
    var kind: Kind
    /// Hidden on the desktop (Archive, Vinyl, …). The importer skips hidden crates outright;
    /// this survives REST decodes so curated lists can honor the desktop's own signal.
    var isHidden: Bool = false
    /// A smart (SEARCH_CRATE) crate's stored query, e.g. `in:"DJ Library" genre:house`.
    /// Live-only: the backup export strips it, so sync fetches it per smart crate.
    var smartQuery: String? = nil

    /// Crates come in flavors. Beyond iconography, kinds now gate curation: folder/watched
    /// crates are the rekordbox file-mirror (never seeded on Home), smart crates materialize
    /// client-side from their query.
    enum Kind: String, Codable, Sendable {
        case crate, playlist, smart, search, history, inbox, root, unknown
        case folder   // typeID 30 — file-system mirror crate (artist/release folders)
        case watched  // typeID 6 — watched-folder root (e.g. music_rekordbox)
        case release  // typeID 2 — a release (album/EP) crate
    }

    enum CodingKeys: String, CodingKey {
        case crateID, crateName, crateObjectID
        case tuneCount, tunesCount, numberOfTunes
        case parentCrateID, parentID
        case hasChildren, hasSubcrates
        case crateType, type
        case hidden
        case crateTypeProperties
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeFlexibleInt64(.crateID) ?? 0
        name = (try c.decodeIfPresent(String.self, forKey: .crateName)) ?? "Untitled Crate"
        tuneCount = try (c.decodeFlexibleInt(.tuneCount)
            ?? c.decodeFlexibleInt(.tunesCount)
            ?? c.decodeFlexibleInt(.numberOfTunes))
        parentID = try (c.decodeFlexibleInt64(.parentCrateID) ?? c.decodeFlexibleInt64(.parentID))
        hasChildren = try (c.decodeIfPresent(Bool.self, forKey: .hasChildren)
            ?? c.decodeIfPresent(Bool.self, forKey: .hasSubcrates)) ?? false
        let rawType = try (c.decodeIfPresent(String.self, forKey: .crateType)
            ?? c.decodeIfPresent(String.self, forKey: .type))
        kind = Crate.parseKind(rawType, name: name)
        isHidden = try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
        smartQuery = try c.decodeIfPresent(String.self, forKey: .crateTypeProperties)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .crateID)
        try c.encode(name, forKey: .crateName)
        try c.encodeIfPresent(tuneCount, forKey: .tuneCount)
        try c.encodeIfPresent(parentID, forKey: .parentCrateID)
        try c.encode(hasChildren, forKey: .hasChildren)
        try c.encode(kind.rawValue, forKey: .crateType)
        try c.encode(isHidden, forKey: .hidden)
        try c.encodeIfPresent(smartQuery, forKey: .crateTypeProperties)
    }

    init(id: Int64, name: String, tuneCount: Int? = nil, parentID: Int64? = nil,
         hasChildren: Bool = false, kind: Kind = .crate,
         isHidden: Bool = false, smartQuery: String? = nil) {
        self.id = id; self.name = name; self.tuneCount = tuneCount
        self.parentID = parentID; self.hasChildren = hasChildren; self.kind = kind
        self.isHidden = isHidden; self.smartQuery = smartQuery
    }

    static func parseKind(_ raw: String?, name: String) -> Kind {
        // Cache round-trip first: we encode kind.rawValue into crateType, so an exact rawValue
        // (including the new folder/watched/release) must decode back to itself.
        if let raw, let exact = Kind(rawValue: raw) { return exact }
        let s = (raw ?? "").lowercased()
        if s.contains("smart") { return .smart }
        if s.contains("search") { return .search }
        if s.contains("history") { return .history }
        if s.contains("playlist") { return .playlist }
        if s.contains("inbox") { return .inbox }
        if s.contains("root") { return .root }
        return .crate
    }

    /// Map a backup `CrateTypeID` to a kind (verified against a real export + live
    /// `/crates/default.crates` join, 2026-07-10). Unknown ids fall back to a name heuristic.
    static func kind(forTypeID id: Int?, name: String) -> Kind {
        switch id {
        case 1: return .root          // Library / Collection / Archive (system roots)
        case 2: return .release       // release (album/EP) crates
        case 6: return .watched       // watched-folder root (music_rekordbox)
        case 7: return .smart         // SEARCH_CRATE — saved-query crates (the genre taxonomy)
        case 21: return .history      // Listening History
        case 30: return .folder       // file-system mirror folders (artist/release dirs)
        case 41: return .playlist     // PlayQueue / Play Queue Mobile
        case 42: return .smart        // Genres
        case 36, 37: return .smart    // date / auto crates
        default: break
        }
        // Names like "Inbox" still resolve by heuristic; everything else is a plain crate.
        let heuristic = parseKind(nil, name: name)
        if name.lowercased().contains("inbox") { return .inbox }
        return heuristic == .crate ? .crate : heuristic
    }

    var symbol: String {
        switch kind {
        case .smart: "wand.and.stars"
        case .search: "magnifyingglass"
        case .history: "clock.arrow.circlepath"
        case .playlist: "music.note.list"
        case .inbox: "tray"
        case .root: "square.stack.3d.up"
        case .folder: "folder"
        case .watched: "folder.badge.gearshape"
        case .release: "opticaldisc"
        case .crate, .unknown: hasChildren ? "folder" : "square.stack"
        }
    }

    /// File-mirror plumbing (the rekordbox watched folder and its 800+ subfolders) — reachable
    /// by browsing, never auto-surfaced (seeds, shelves).
    var isFolderMirror: Bool { kind == .folder || kind == .watched }
}
