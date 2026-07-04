import Testing
import Foundation
@testable import CratesIOS

/// The Crates API is loosely typed (decompiled-spec artifacts: numbers as strings, missing fields,
/// unknown date formats). These tests pin the lenient decoding that keeps one sloppy field from
/// killing a whole list.
struct DecodingTests {
    private func decodeTune(_ json: String) throws -> Tune {
        try JSONDecoder().decode(Tune.self, from: Data(json.utf8))
    }

    @Test func decodesFullyPopulatedTune() throws {
        let t = try decodeTune("""
        {"tuneID": 42, "tuneTitle": "Solar Wind", "artist": "Rødhåd", "album": "WSNWG",
         "genre": "Techno", "tuneLength": "431", "bpm": "132", "tuneKey": "A♭m",
         "rating": 5, "coverID": 7, "dateAdded": "1719800000000", "purchasedFrom": 1}
        """)
        #expect(t.id == 42)
        #expect(t.title == "Solar Wind")
        #expect(t.lengthSeconds == 431)
        #expect(t.rating == 5)
        #expect(t.source == .bandcamp) // purchasedFrom 1 = Bandcamp per spec
        #expect(t.dateAdded != nil)
    }

    @Test func decodesStringTypedNumbers() throws {
        // ids and counts arrive as quoted strings from some endpoints
        let t = try decodeTune(#"{"tuneID": "77", "tuneName": "untitled", "rating": "3", "coverID": "12"}"#)
        #expect(t.id == 77)
        #expect(t.rating == 3)
        #expect(t.coverID == 12)
    }

    @Test func fallsBackToTuneNameWhenTitleMissing() throws {
        let t = try decodeTune(#"{"tuneID": 1, "tuneName": "from filename.mp3"}"#)
        #expect(t.title == "from filename.mp3")
        #expect(t.displayArtist == "Unknown Artist")
    }

    @Test func survivesGarbageFields() throws {
        let t = try decodeTune(#"{"tuneID": 5, "rating": "not-a-number", "coverID": [1,2]}"#)
        #expect(t.id == 5)
        #expect(t.rating == nil)
        #expect(t.coverID == nil)
    }

    @Test func parsesLengthFormats() {
        #expect(Tune.parseLength("431") == 431)            // seconds
        #expect(Tune.parseLength("431000") == 431)         // milliseconds heuristic
        #expect(Tune.parseLength("7:11") == 431)           // mm:ss
        #expect(Tune.parseLength("1:07:11") == 4031)       // hh:mm:ss
        #expect(Tune.parseLength("") == nil)
        #expect(Tune.parseLength(nil) == nil)
        #expect(Tune.parseLength("—") == nil)
    }

    @Test func parsesDateFormats() {
        #expect(Tune.parseDate("1719800000000") != nil)    // epoch ms
        #expect(Tune.parseDate("1719800000") != nil)       // epoch s
        #expect(Tune.parseDate("2026-07-04T10:00:00Z") != nil) // ISO8601
        #expect(Tune.parseDate("") == nil)
        #expect(Tune.parseDate(nil) == nil)
    }

    @Test func decodesCrateVariants() throws {
        let c = try JSONDecoder().decode(Crate.self, from: Data("""
        {"crateID": "9", "crateName": "Inbox", "tunesCount": 23, "hasSubcrates": true, "crateType": "INBOX_CRATE"}
        """.utf8))
        #expect(c.id == 9)
        #expect(c.tuneCount == 23)
        #expect(c.hasChildren)
        #expect(c.kind == .inbox)
    }

    /// Regression: the disk cache round-trips Tune through Codable. A lossy encoder silently
    /// strips duration/dates/source on every cold start (review finding).
    @Test func cacheRoundTripIsLossless() throws {
        let original = Tune(
            id: 42, title: "Solar Wind", artist: "Rødhåd", album: "WSNWG", genre: "Techno",
            lengthSeconds: 431, bpm: "132", key: "A♭m", rating: 5, coverID: 7,
            dateAdded: Date(timeIntervalSince1970: 1_719_800_000), source: .bandcamp,
            pageURL: "https://example.com/t")
        let data = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(Tune.self, from: data)
        #expect(restored == original)
        // And a whole array, as DiskCache stores it.
        let list = try JSONDecoder().decode([Tune].self, from: JSONEncoder().encode([original, original]))
        #expect(list == [original, original])
    }

    @Test func trackSourceMapping() {
        #expect(TrackSource.fromTypeName("Local File") == .localFile)
        #expect(TrackSource.fromTypeName("BANDCAMP") == .bandcamp)
        #expect(TrackSource.fromTypeName("YouTube Music") == .youtube)
        #expect(TrackSource.fromTypeName("weird-new-thing") == .unknown)
        #expect(TrackSource.fromTypeName(nil) == .unknown)
    }
}
