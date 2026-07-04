import Foundation

/// Typed wrappers over the specific Crates endpoints the POC calls. Keeps endpoint strings and
/// their loose response shapes in one place. Everything here is best-effort: the API returns
/// arrays of loosely-typed beans, so we decode into an array of `JSONValue`-ish dictionaries where
/// the strict models can't be trusted, then map.
struct LibraryAPI {
    let client: CratesClient

    /// Root/default crates — the top of the browse tree and Home-tab material.
    func defaultCrates() async throws -> [Crate] {
        try await client.get("crates/default.crates", as: [Crate].self)
    }

    /// Recently-used crates — good default Home hotlinks.
    func recentCrates() async throws -> [Crate] {
        try await client.get("crates/recent.crates", as: [Crate].self)
    }

    /// Children of a crate (subcrates) — powers the browse hierarchy.
    func children(of crateID: Int64) async throws -> [Crate] {
        try await client.get("crates/\(crateID)/children", as: [Crate].self)
    }

    /// Ordered tunes in a crate. NOTE: server returns the *full* ordered list (no pagination) —
    /// the cache layer is what keeps this cheap on repeat opens.
    func tunes(inCrate crateID: Int64) async throws -> [Tune] {
        try await client.get("tunes/crates/\(crateID)", as: [Tune].self)
    }

    /// Basic tune search.
    func searchTunes(_ query: String) async throws -> [Tune] {
        try await client.get("search/tunes/basic",
                             query: [URLQueryItem(name: "query", value: query)],
                             as: [Tune].self)
    }

    /// Available audio-source types, for resolving `defaultAudioSourceType` → TrackSource.
    func audioSourceTypes() async throws -> [AudioSourceType] {
        try await client.get("audiosource/types", as: [AudioSourceType].self)
    }

    /// Liveness check.
    func ping() async throws {
        _ = try await client.rawGet("backend/ping")
    }
}

struct AudioSourceType: Decodable, Sendable, Identifiable {
    let id: Int64
    let name: String
    enum CodingKeys: String, CodingKey { case typeID, typeName }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeFlexibleInt64(.typeID) ?? 0
        name = (try c.decodeIfPresent(String.self, forKey: .typeName)) ?? "Unknown"
    }
}
