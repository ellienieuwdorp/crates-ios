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

    /// Crates come in flavors; the POC only needs to distinguish a few for iconography.
    enum Kind: String, Codable, Sendable {
        case crate, playlist, smart, search, history, inbox, root, unknown
    }

    enum CodingKeys: String, CodingKey {
        case crateID, crateName, crateObjectID
        case tuneCount, tunesCount, numberOfTunes
        case parentCrateID, parentID
        case hasChildren, hasSubcrates
        case crateType, type
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
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .crateID)
        try c.encode(name, forKey: .crateName)
        try c.encodeIfPresent(tuneCount, forKey: .tuneCount)
        try c.encodeIfPresent(parentID, forKey: .parentCrateID)
        try c.encode(hasChildren, forKey: .hasChildren)
        try c.encode(kind.rawValue, forKey: .crateType)
    }

    init(id: Int64, name: String, tuneCount: Int? = nil, parentID: Int64? = nil,
         hasChildren: Bool = false, kind: Kind = .crate) {
        self.id = id; self.name = name; self.tuneCount = tuneCount
        self.parentID = parentID; self.hasChildren = hasChildren; self.kind = kind
    }

    static func parseKind(_ raw: String?, name: String) -> Kind {
        let s = (raw ?? "").lowercased()
        if s.contains("smart") { return .smart }
        if s.contains("search") { return .search }
        if s.contains("history") { return .history }
        if s.contains("playlist") { return .playlist }
        if s.contains("inbox") { return .inbox }
        if s.contains("root") { return .root }
        return .crate
    }

    /// Map a backup `CrateTypeID` to a kind (verified against real export type ids). Unknown ids
    /// fall back to a name heuristic.
    static func kind(forTypeID id: Int?, name: String) -> Kind {
        switch id {
        case 1: return .root          // Library / Collection / Archive (system roots)
        case 21: return .history      // Listening History
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
        case .crate, .unknown: hasChildren ? "folder" : "square.stack"
        }
    }
}
