import Testing
import Foundation
@testable import CratesIOS

/// Pending play-report store (TODO §5): coalescing, absolute-count computation, persistence
/// round-trip, and flush bookkeeping. Pure value-type tests — no network, no DiskCache.
struct PlaySyncTests {
    private let date = Date(timeIntervalSince1970: 1_780_000_000)

    // MARK: - Absolute-count computation

    @Test func firstPlayOfUnknownCountIsOne() {
        var store = PendingPlayStore()
        let count = store.recordPlay(tuneID: 5, objectID: "abc", localPlayedCount: nil, at: date)
        #expect(count == 1)
        #expect(store.reports == [PendingPlayReport(
            tuneID: 5, objectID: "abc", playedCount: 1,
            lastListenDate: ServerDate.string(from: date))])
    }

    @Test func playAddsOneToTheLocallySyncedCount() {
        var store = PendingPlayStore()
        #expect(store.recordPlay(tuneID: 5, objectID: nil, localPlayedCount: 7, at: date) == 8)
    }

    @Test func pendingUnsentPlaysKeepStacking() {
        // Two completions before any flush: the pending count is fresher than the library cache
        // (which may lag), so the second play must build on the first, not restart from base.
        var store = PendingPlayStore()
        store.recordPlay(tuneID: 5, objectID: nil, localPlayedCount: 0, at: date)
        let second = store.recordPlay(tuneID: 5, objectID: nil, localPlayedCount: 0, at: date)
        #expect(second == 2)
    }

    @Test func fresherLibraryCountWinsOverStalePending() {
        // A sync can land between plays and raise the library count past the pending one
        // (desktop plays); the higher base wins.
        var store = PendingPlayStore()
        store.recordPlay(tuneID: 5, objectID: nil, localPlayedCount: 0, at: date) // pending = 1
        #expect(store.recordPlay(tuneID: 5, objectID: nil, localPlayedCount: 9, at: date) == 10)
    }

    // MARK: - Coalescing

    @Test func multiplePlaysOfTheSameTuneCoalesceToOneReport() {
        var store = PendingPlayStore()
        let later = date.addingTimeInterval(300)
        store.recordPlay(tuneID: 5, objectID: "abc", localPlayedCount: 0, at: date)
        store.recordPlay(tuneID: 5, objectID: "abc", localPlayedCount: 0, at: later)
        #expect(store.reports.count == 1)
        #expect(store.reports[0].playedCount == 2) // latest absolute count
        #expect(store.reports[0].lastListenDate == ServerDate.string(from: later))
    }

    @Test func coalescingKeepsAKnownObjectIDWhenALaterPlayLacksOne() {
        var store = PendingPlayStore()
        store.recordPlay(tuneID: 5, objectID: "abc", localPlayedCount: 0, at: date)
        store.recordPlay(tuneID: 5, objectID: nil, localPlayedCount: 0, at: date)
        #expect(store.reports[0].objectID == "abc")
    }

    @Test func differentTunesStaySeparateReports() {
        var store = PendingPlayStore()
        store.recordPlay(tuneID: 5, objectID: nil, localPlayedCount: 0, at: date)
        store.recordPlay(tuneID: 9, objectID: nil, localPlayedCount: 3, at: date)
        #expect(store.reports.map(\.tuneID) == [5, 9])
        #expect(store.reports.map(\.playedCount) == [1, 4])
    }

    // MARK: - Persistence round-trip

    @Test func storeRoundTripsThroughJSON() throws {
        var store = PendingPlayStore()
        store.recordPlay(tuneID: 5, objectID: "abc", localPlayedCount: 2, at: date)
        store.recordPlay(tuneID: 9, objectID: nil, localPlayedCount: nil, at: date)
        let revived = try JSONDecoder().decode(PendingPlayStore.self,
                                               from: JSONEncoder().encode(store))
        #expect(revived == store)
    }

    // MARK: - Flush bookkeeping

    @Test func markSentRemovesTheDeliveredReport() {
        var store = PendingPlayStore()
        store.recordPlay(tuneID: 5, objectID: nil, localPlayedCount: 0, at: date)
        store.recordPlay(tuneID: 9, objectID: nil, localPlayedCount: 0, at: date)
        store.markSent(store.reports[0])
        #expect(store.reports.map(\.tuneID) == [9])
    }

    @Test func markSentKeepsAPlayThatLandedMidFlight() {
        var store = PendingPlayStore()
        store.recordPlay(tuneID: 5, objectID: nil, localPlayedCount: 0, at: date)
        let inFlight = store.reports[0] // count 1, now on the wire
        store.recordPlay(tuneID: 5, objectID: nil, localPlayedCount: 0, at: date) // count 2 lands mid-flight
        store.markSent(inFlight)
        #expect(store.reports.map(\.playedCount) == [2]) // the newer count must still be sent
    }

    // MARK: - Wire shape

    @Test func requestBodyMatchesTheVerifiedEndpointShape() throws {
        let report = PendingPlayReport(tuneID: 5, objectID: "6a48fef55dd66754e05976a6",
                                       playedCount: 1, lastListenDate: "2026-07-10 01:45:00")
        let body = try report.requestBody()
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let tunes = try #require(json["tunes"] as? [[String: Any]])
        #expect(tunes.count == 1)
        #expect(tunes[0]["tuneID"] as? Int64 == 5)
        #expect(tunes[0]["tuneObjectID"] as? String == "6a48fef55dd66754e05976a6")
        #expect(tunes[0]["objectID"] as? String == "6a48fef55dd66754e05976a6")
        let attrs = try #require(json["attributes"] as? [[String: Any]])
        #expect(attrs.count == 2)
        #expect(attrs[0]["attribute"] as? String == "playedCount")
        #expect(attrs[0]["value"] as? Int == 1)
        #expect(attrs[1]["attribute"] as? String == "lastListenDate")
        #expect(attrs[1]["value"] as? String == "2026-07-10 01:45:00")
        // Harness aid: the exact bytes the client sends, for live curl verification.
        print("PLAY-REPORT-JSON: \(String(data: body, encoding: .utf8)!)")
    }

    @Test func requestBodyOmitsUnknownObjectIDsEntirely() throws {
        // The server silently IGNORES null values (probe report) — a nil objectID must vanish
        // from the payload, never encode as null.
        let report = PendingPlayReport(tuneID: 5, objectID: nil,
                                       playedCount: 1, lastListenDate: "2026-07-10 01:45:00")
        let body = try report.requestBody()
        let text = try #require(String(data: body, encoding: .utf8))
        #expect(!text.contains("null"))
        #expect(!text.contains("objectID"))
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let tunes = try #require(json["tunes"] as? [[String: Any]])
        #expect(tunes[0].keys.sorted() == ["tuneID"])
    }

    @Test func serverDateFormatMatchesTheProbe() {
        // Probe-verified format: "2026-07-10 01:45:00" (server echoes with ".000").
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone.current
        let d = cal.date(from: DateComponents(year: 2026, month: 7, day: 10,
                                              hour: 1, minute: 45, second: 0))!
        #expect(ServerDate.string(from: d) == "2026-07-10 01:45:00")
        #expect(ServerDate.parse("2026-07-10 01:45:00.000") == d)
        #expect(ServerDate.parse("2026-07-10 01:45:00") == d)
    }
}
