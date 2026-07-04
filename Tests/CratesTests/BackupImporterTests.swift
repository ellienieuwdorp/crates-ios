import Testing
import Foundation
import ZIPFoundation
@testable import CratesIOS

/// Validates the relational join in BackupImporter against a hand-built backup zip shaped exactly
/// like a real `CratesBackup.zip` (verified field names). Exercises hierarchy, per-crate tune
/// ordering, tune↔audiofile enrichment, ratings, source derivation, and hidden-crate exclusion.
struct BackupImporterTests {

    private func makeZip(_ tables: [String: String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bkp-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let zipURL = dir.appendingPathComponent("CratesBackup.zip")
        let archive = try Archive(url: zipURL, accessMode: .create)
        for (name, json) in tables {
            let data = Data(json.utf8)
            try archive.addEntry(with: name, type: .file, uncompressedSize: Int64(data.count)) { pos, size in
                data.subdata(in: Int(pos)..<Int(pos) + size)
            }
        }
        return zipURL
    }

    @Test func importsRealisticBackupShape() throws {
        let zip = try makeZip([
            "Crates.json": """
            [
              {"CrateID":1,"Name":"Library","CrateTypeID":1,"Hidden":false},
              {"CrateID":2,"Name":"Peak Time","CrateTypeID":2,"Hidden":false},
              {"CrateID":3,"Name":"Deep","CrateTypeID":2,"Hidden":false},
              {"CrateID":9,"Name":"Secret","CrateTypeID":2,"Hidden":true}
            ]
            """,
            "CrateToCrates.json": """
            [
              {"ParentCrateID":1,"ChildCrateID":3,"CrateOrderingID":2},
              {"ParentCrateID":1,"ChildCrateID":2,"CrateOrderingID":1}
            ]
            """,
            // TuneLength is a STRING and some fields are absent — exactly as the real server sends.
            "Tunes.json": """
            [
              {"TuneID":101,"TuneTitle":"Solar Wind","Artist":"Rødhåd","Album":"WSNWG","Genre":"Techno","TuneLength":"431","DateAdded":"2026-07-01 10:00:00","CoverID":7,"DefaultAudioSourceType":1,"TuneDefaultLocation":"/music/solar.aiff"},
              {"TuneID":102,"TuneTitle":"Bandcamp One","Artist":"X","DefaultAudioSourceType":5,"TuneDefaultLocation":"https://bandcamp.com/EmbeddedPlayer/track=1"}
            ]
            """,
            "CrateToTunes.json": """
            [
              {"CrateID":2,"TuneID":102,"TuneOrderingID":2,"DateModified":"2026-07-02 09:00:00"},
              {"CrateID":2,"TuneID":101,"TuneOrderingID":1,"DateModified":"2026-07-01 09:00:00"}
            ]
            """,
            "AudioFiles.json": """
            [
              {"TuneID":101,"Bpm":"132","Key":"A♭m","Codec":"AIFF","FileType":"aiff","StorageType":"LOCAL_STORAGE"}
            ]
            """,
            "Ratings.json": #"[{"ObjectID":101,"RatingValue":5}]"#,
        ])

        let snap = try BackupImporter.importBackup(zipURL: zip)

        // Hidden crate excluded; roots exclude children.
        #expect(snap.allCratesByID[9] == nil)
        #expect(snap.rootCrates.map(\.id) == [1]) // 2 and 3 are children of 1

        // Hierarchy ordered by CrateOrderingID (2 before 3).
        #expect(snap.childrenByCrate[1]?.map(\.id) == [2, 3])
        #expect(snap.allCratesByID[1]?.hasChildren == true)

        // Per-crate tune ordering by TuneOrderingID (101 before 102).
        let crate2 = snap.tunesByCrate[2]
        #expect(crate2?.map(\.id) == [101, 102])
        #expect(snap.allCratesByID[2]?.tuneCount == 2)

        // Tune enrichment: bpm/key from AudioFiles, rating from Ratings, source from type id.
        let solar = crate2?.first
        #expect(solar?.title == "Solar Wind")
        #expect(solar?.bpm == "132")
        #expect(solar?.key == "A♭m")
        #expect(solar?.rating == 5)
        #expect(solar?.source == .localFile)
        #expect(solar?.lengthSeconds == 431)

        // Bandcamp source derived from type 5.
        #expect(crate2?.last?.source == .bandcamp)

        #expect(snap.tuneCount == 2)
    }

    @Test func handlesMissingTablesGracefully() throws {
        let zip = try makeZip(["Crates.json": #"[{"CrateID":1,"Name":"Only"}]"#])
        let snap = try BackupImporter.importBackup(zipURL: zip)
        #expect(snap.rootCrates.count == 1)
        #expect(snap.tuneCount == 0)
    }
}
