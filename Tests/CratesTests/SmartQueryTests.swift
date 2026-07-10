import Testing
import Foundation
@testable import CratesIOS

/// SmartQuery parses and evaluates the exact grammar of the real library's 13 smart-crate
/// queries (fetched live 2026-07-10, recorded in docs/design/home-browse-redesign.md).
struct SmartQueryTests {

    private func tune(_ id: Int64, genres: [String], legacy: String? = nil) -> Tune {
        Tune(id: id, title: "T\(id)", artist: "A", genre: legacy, genres: genres)
    }

    // MARK: - Parsing (every real query shape must parse; unsupported fields must not)

    @Test func parsesEveryRealQueryShape() {
        let real = [
            "in:\"DJ Library\" genre:jazz",
            "in:\"DJ Library\" (genre:funk OR genre:soul)",
            "in:\"DJ Library\" genre:dub !genre:house !genre:techno",
            "in:\"DJ Library\" genre:\"hip hop\"",
            "in:\"DJ Library\" genre:dnb OR genre:drum*bass",
        ]
        for q in real {
            #expect(SmartQuery.parse(q) != nil, "should parse: \(q)")
        }
    }

    @Test func rejectsUnsupportedFields() {
        #expect(SmartQuery.parse("bpm:120-130") == nil)
        #expect(SmartQuery.parse("in:\"DJ Library\" rating:>80") == nil)
        #expect(SmartQuery.parse("artist:four*tet") == nil)
        #expect(SmartQuery.parse("") == nil)
        #expect(SmartQuery.parse("justaword") == nil)
    }

    // MARK: - Matching semantics (verified against the live server's substring behavior)

    @Test func substringMatchesLikeTheServer() throws {
        let q = try #require(SmartQuery.parse("genre:house"))
        #expect(q.matches(tune(1, genres: ["House"])))
        #expect(q.matches(tune(2, genres: ["Acid House"])))     // server: genre:house → 218 incl. these
        #expect(q.matches(tune(3, genres: ["tech house"])))
        #expect(!q.matches(tune(4, genres: ["Techno"])))
        #expect(!q.matches(tune(5, genres: [])))
    }

    @Test func separatorFoldingMatchesHyphenatedGenres() throws {
        let q = try #require(SmartQuery.parse("genre:\"hip hop\""))
        #expect(q.matches(tune(1, genres: ["Hip-Hop"])))
        #expect(q.matches(tune(2, genres: ["hip hop"])))
        #expect(!q.matches(tune(3, genres: ["trip hop"])))
    }

    @Test func negationExcludes() throws {
        let q = try #require(SmartQuery.parse("genre:dub !genre:house !genre:techno"))
        #expect(q.matches(tune(1, genres: ["Dub"])))
        #expect(q.matches(tune(2, genres: ["Dubstep"])))          // substring: dub ⊂ dubstep
        #expect(!q.matches(tune(3, genres: ["Dub Techno"])))      // excluded by !techno
        #expect(!q.matches(tune(4, genres: ["dub", "acid house"]))) // excluded by !house
    }

    @Test func orGroupsMatchAnyOption() throws {
        let q = try #require(SmartQuery.parse("(genre:funk OR genre:soul)"))
        #expect(q.matches(tune(1, genres: ["Funk"])))
        #expect(q.matches(tune(2, genres: ["Northern Soul"])))
        #expect(!q.matches(tune(3, genres: ["Disco"])))
    }

    @Test func topLevelOrWithWildcard() throws {
        let q = try #require(SmartQuery.parse("genre:dnb OR genre:drum*bass"))
        #expect(q.matches(tune(1, genres: ["DnB"])))
        #expect(q.matches(tune(2, genres: ["Drum and Bass"])))    // drum*bass wildcard
        #expect(q.matches(tune(3, genres: ["drum'n'bass"])))
        #expect(!q.matches(tune(4, genres: ["bass"])))            // wildcard needs the drum prefix
    }

    @Test func legacySingleGenreStringCounts() throws {
        // The server's search matches the tune's Genre field too, not just the join.
        let q = try #require(SmartQuery.parse("genre:footwork"))
        #expect(q.matches(tune(1, genres: [], legacy: "Footwork")))
    }

    @Test func inScopeIsIgnoredNotFatal() throws {
        let q = try #require(SmartQuery.parse("in:\"DJ Library\" genre:jazz"))
        // Scope is ignored: any jazz tune matches regardless of crate membership.
        #expect(q.matches(tune(1, genres: ["Jazz"])))
        #expect(!q.matches(tune(2, genres: ["House"])))
    }
}

/// Curation + facet rules from the redesign (LibraryStore is MainActor-bound).
@MainActor
struct CurationTests {

    private func store(tunes: [Tune]) -> LibraryStore {
        let s = LibraryStore()
        s.setAllTunes(tunes)
        return s
    }

    @Test func artistFacetsDedupeCaseInsensitively() {
        let s = store(tunes: [
            Tune(id: 1, title: "a", artist: "Yunis"),
            Tune(id: 2, title: "b", artist: "yunis"),
            Tune(id: 3, title: "c", artist: "Upsammy"),
        ])
        let facets = s.artistFacets()
        #expect(facets.count == 2)
        #expect(facets.first { $0.name.lowercased() == "yunis" }?.tuneCount == 2)
    }

    @Test func genreFacetsUseJoinThenLegacyAndSortByCount() {
        let s = store(tunes: [
            Tune(id: 1, title: "a", artist: "x", genres: ["Techno", "IDM"]),
            Tune(id: 2, title: "b", artist: "x", genres: ["techno"]),
            Tune(id: 3, title: "c", artist: "x", genre: "Ambient", genres: []),
        ])
        let facets = s.genreFacets()
        #expect(facets.first?.name.lowercased() == "techno")
        #expect(facets.first?.tuneCount == 2)
        #expect(facets.contains { $0.name == "Ambient" && $0.tuneCount == 1 })
    }

    @Test func recentlyAddedSortsNewestFirstAndSkipsUnplayable() {
        let old = Date(timeIntervalSince1970: 1_000)
        let new = Date(timeIntervalSince1970: 2_000)
        let s = store(tunes: [
            Tune(id: 1, title: "old", artist: "x", dateAdded: old, hasServerAudio: true),
            Tune(id: 2, title: "new", artist: "x", dateAdded: new, hasServerAudio: true),
            Tune(id: 3, title: "dead", artist: "x", dateAdded: new, hasServerAudio: false),
            Tune(id: 4, title: "undated", artist: "x", hasServerAudio: true),
        ])
        let shelf = s.recentlyAddedTunes()
        #expect(shelf.map(\.id) == [2, 1])
    }

    @Test func forgottenFavoritesExcludesRecentLocalPlays() {
        let s = store(tunes: [
            Tune(id: 1, title: "fav", artist: "x", rating: 90, hasServerAudio: true),
            Tune(id: 2, title: "recent", artist: "x", rating: 95, hasServerAudio: true),
            Tune(id: 3, title: "unrated", artist: "x", hasServerAudio: true),
        ])
        let shelf = s.forgottenFavorites(excluding: [2])
        #expect(shelf.map(\.id) == [1])
    }

    @Test func smartCrateMaterializesFromQuery() {
        let s = store(tunes: [
            Tune(id: 1, title: "a", artist: "x", dateAdded: Date(timeIntervalSince1970: 1), genres: ["House"]),
            Tune(id: 2, title: "b", artist: "x", dateAdded: Date(timeIntervalSince1970: 2), genres: ["Acid House"]),
            Tune(id: 3, title: "c", artist: "x", genres: ["Techno"]),
        ])
        var crate = Crate(id: 69, name: "House", kind: .smart,
                          smartQuery: "in:\"DJ Library\" genre:house")
        s.applySmartQueriesForTesting(crates: [crate])
        #expect(s.tunes(in: 69).map(\.id) == [2, 1]) // matches only, newest first

        crate.smartQuery = "bpm:120" // unsupported → honest empty
        s.applySmartQueriesForTesting(crates: [crate])
        #expect(s.tunes(in: 69).isEmpty)
        #expect(s.smartCrateUnsupported(crate))
    }
}
