import Foundation

/// Representative demo library so the POC is explorable without a paired server — used by demo
/// mode and SwiftUI previews. Deliberately DJ-flavored to match Crates' audience.
enum SampleData {
    static let crates: [Crate] = [
        Crate(id: 1, name: "Inbox", tuneCount: 23, hasChildren: false, kind: .inbox),
        Crate(id: 2, name: "Peak Time / Driving", tuneCount: 142, hasChildren: true, kind: .crate),
        Crate(id: 3, name: "Deep & Hypnotic", tuneCount: 88, hasChildren: false, kind: .crate),
        Crate(id: 4, name: "Recently Added", tuneCount: 50, hasChildren: false, kind: .smart),
        Crate(id: 5, name: "Warmup Selectors", tuneCount: 61, hasChildren: false, kind: .crate),
        Crate(id: 6, name: "Play History", tuneCount: 500, hasChildren: false, kind: .history),
    ]

    static func tune(_ id: Int64, _ title: String, _ artist: String, _ album: String,
                     _ len: Double, _ bpm: String, _ key: String, _ genre: String,
                     _ source: TrackSource, _ daysAgo: Int, _ rating: Int? = nil) -> Tune {
        // Streaming-only imports (YouTube/Spotify rips without an audio file) mirror the real
        // library's codec-null tunes, so the dimmed unplayable treatment is visible in demo.
        let hasAudio: Bool = switch source {
        case .youtube, .spotify, .unknown: false
        default: true
        }
        return Tune(id: id, title: title, artist: artist, album: album, genre: genre,
                    lengthSeconds: len, bpm: bpm, key: key, rating: rating, coverID: id,
                    dateAdded: Date(timeIntervalSinceNow: -Double(daysAgo) * 86_400),
                    source: source, pageURL: nil, hasServerAudio: hasAudio)
    }

    static let tunesByCrate: [Int64: [Tune]] = [
        2: [
            tune(101, "Solar Wind", "Rødhåd", "WSNWG", 431, "132", "A♭m", "Techno", .bandcamp, 2, 5),
            tune(102, "Nightdrive (Original Mix)", "Kobosil", "R —", 398, "134", "F♯m", "Techno", .localFile, 4, 4),
            tune(103, "Endless", "Answer Code Request", "Gnosis", 412, "130", "Cm", "Techno", .localFile, 6),
            tune(104, "Reflections", "Blawan", "Wet Will Always Dry", 356, "133", "Gm", "Techno", .bandcamp, 8, 5),
            tune(105, "Overdrive", "SPFDJ", "Intrepid Skin", 289, "138", "Dm", "Hard Techno", .youtube, 9),
            tune(106, "Voltage", "I Hate Models", "Warm Water", 402, "136", "Am", "Techno", .soundcloud, 12, 4),
            tune(107, "Cascade", "Etapp Kyle", "Sequence", 388, "131", "E♭m", "Techno", .localFile, 15),
            tune(108, "Pulsar", "Stef Mendesidis", "Metron", 421, "134", "Bm", "Techno", .bandcamp, 18),
        ],
        3: [
            tune(201, "Submerged", "Donato Dozzy", "K", 512, "122", "Fm", "Deep Techno", .localFile, 3, 5),
            tune(202, "Undercurrent", "Peter Van Hoesen", "Perceiver", 468, "124", "Gm", "Deep Techno", .localFile, 7),
            tune(203, "Slow Tide", "Wata Igarashi", "PGM", 445, "120", "Am", "Hypnotic", .bandcamp, 11, 4),
            tune(204, "Mirror Pool", "Refracted", "Sombra", 502, "123", "Dm", "Hypnotic", .soundcloud, 14),
            tune(205, "Vapour", "Voidloss", "Known By Very Few", 389, "121", "Cm", "Deep Techno", .youtube, 20),
        ],
        1: [
            tune(301, "untitled 04", "Unknown Artist", "promo", 367, "128", "—", "Unsorted", .unknown, 0),
            tune(302, "New ID", "VTSS", "forthcoming", 298, "140", "F♯m", "Unsorted", .bandcamp, 1),
            tune(303, "rip from set", "Unknown Artist", "", 445, "—", "—", "Unsorted", .youtube, 1),
        ],
    ]
}
