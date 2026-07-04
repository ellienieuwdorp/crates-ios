import Testing
import Foundation
@testable import CratesIOS

/// The "keep last N added" retention brain (Philosophy #4). These are the semantics users rely on
/// for offline storage, so they get the densest coverage.
struct RetentionPolicyTests {
    private func tune(_ id: Int64, daysAgo: Int?) -> Tune {
        Tune(id: id, title: "t\(id)", artist: "a",
             dateAdded: daysAgo.map { Date(timeIntervalSinceNow: -Double($0) * 86_400) })
    }

    @Test func offKeepsNothing() {
        let tunes = [tune(1, daysAgo: 1), tune(2, daysAgo: 2)]
        #expect(DownloadManager.tunesToKeep(tunes: tunes, policy: .init(mode: .off, keepCount: 100)).isEmpty)
    }

    @Test func keepAllKeepsEverything() {
        let tunes = (1...5).map { tune(Int64($0), daysAgo: $0) }
        #expect(DownloadManager.tunesToKeep(tunes: tunes, policy: .init(mode: .keepAll, keepCount: 1)).count == 5)
    }

    @Test func keepLastNSelectsNewestByDate() {
        // Deliberately shuffled server order; dates decide.
        let tunes = [tune(1, daysAgo: 10), tune(2, daysAgo: 1), tune(3, daysAgo: 30), tune(4, daysAgo: 2)]
        let kept = DownloadManager.tunesToKeep(tunes: tunes, policy: .init(mode: .keepLastN, keepCount: 2))
        #expect(Set(kept.map(\.id)) == Set([2, 4])) // the two newest
    }

    @Test func keepLastNFallsBackToServerOrderWhenDatesIncomplete() {
        // One nil date → dates are untrustworthy; server order (add-order) governs, suffix wins.
        let tunes = [tune(1, daysAgo: 1), tune(2, daysAgo: nil), tune(3, daysAgo: 99), tune(4, daysAgo: 50)]
        let kept = DownloadManager.tunesToKeep(tunes: tunes, policy: .init(mode: .keepLastN, keepCount: 2))
        #expect(kept.map(\.id) == [3, 4])
    }

    @Test func keepLastNLargerThanListKeepsAll() {
        let tunes = (1...3).map { tune(Int64($0), daysAgo: $0) }
        let kept = DownloadManager.tunesToKeep(tunes: tunes, policy: .init(mode: .keepLastN, keepCount: 200))
        #expect(kept.count == 3)
    }

    @Test func keepLastNZeroOrNegativeKeepsNothing() {
        let tunes = (1...3).map { tune(Int64($0), daysAgo: $0) }
        #expect(DownloadManager.tunesToKeep(tunes: tunes, policy: .init(mode: .keepLastN, keepCount: 0)).isEmpty)
        #expect(DownloadManager.tunesToKeep(tunes: tunes, policy: .init(mode: .keepLastN, keepCount: -5)).isEmpty)
    }

    @Test func emptyListIsFine() {
        #expect(DownloadManager.tunesToKeep(tunes: [], policy: .init(mode: .keepLastN, keepCount: 100)).isEmpty)
    }
}
