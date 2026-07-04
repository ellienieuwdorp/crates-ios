import Testing
import Foundation
@testable import CratesIOS

/// Local-search ranking + folding over LibraryStore.allTunes (dogfood round 3, item 8).
@MainActor
struct LocalSearchTests {
    private func makeStore() -> LibraryStore {
        let store = LibraryStore()
        store.setAllTunes([
            Tune(id: 1, title: "Submerged", artist: "Donato Dozzy"),
            Tune(id: 2, title: "Sub Culture", artist: "Someone Else"),
            Tune(id: 3, title: "Deep Water", artist: "Subduction"),
            Tune(id: 4, title: "Nightdrive", artist: "Kobosil"),
            Tune(id: 5, title: "Café del Mar", artist: "Energy 52"),
        ])
        return store
    }

    @Test func findsByTitleAndArtist() {
        let s = makeStore()
        #expect(s.searchTunes("dozzy").map(\.id) == [1])
        #expect(s.searchTunes("kobosil").map(\.id) == [4])
    }

    @Test func titlePrefixOutranksArtistMatch() {
        let s = makeStore()
        let ids = s.searchTunes("sub").map(\.id)
        // Title-prefix matches (1, 2) before the artist-only match (3).
        #expect(Set(ids.prefix(2)) == Set([1, 2]))
        #expect(ids.last == 3)
    }

    @Test func tokenSearchRequiresAllTokens() {
        let s = makeStore()
        #expect(s.searchTunes("deep water").map(\.id) == [3])
        #expect(s.searchTunes("deep kobosil").isEmpty)
    }

    @Test func foldingIgnoresCaseAndDiacritics() {
        let s = makeStore()
        #expect(s.searchTunes("cafe del mar").map(\.id) == [5])
        #expect(s.searchTunes("CAFÉ").map(\.id) == [5])
    }

    @Test func emptyQueryReturnsNothing() {
        let s = makeStore()
        #expect(s.searchTunes("   ").isEmpty)
    }
}
