import Testing
import Foundation
@testable import CratesIOS

/// Queue index math in PlaybackController — the swipe-to-queue features (Ideas #5/#6) live or die
/// on these invariants. Runs on MainActor since the controller is UI-bound.
@MainActor
struct QueueLogicTests {
    private func makeTunes(_ n: Int) -> [Tune] {
        (1...n).map { Tune(id: Int64($0), title: "t\($0)", artist: "a") }
    }

    /// Playback in tests: AVPlayer with a nil/URL asset just idles in the simulator — the queue
    /// math is what we're asserting. A connection is attached so stream URLs resolve.
    private func makeController() -> PlaybackController {
        let c = PlaybackController()
        c.attach(connection: CratesConnection(host: "127.0.0.1", port: 54735, token: "test"),
                 downloads: DownloadManager())
        return c
    }

    @Test func playReplacesQueueAndSetsIndex() {
        let p = makeController()
        p.play(makeTunes(5), startingAt: 2)
        #expect(p.queue.count == 5)
        #expect(p.currentIndex == 2)
        #expect(p.current?.id == 3)
    }

    @Test func addToEndOfQueueOnEmptyStartsPlayback() {
        let p = makeController()
        let t = makeTunes(1)[0]
        p.addToEndOfQueue(t)
        #expect(p.currentIndex == 0)
        #expect(p.current?.id == t.id)
    }

    @Test func addToEndAppendsWithoutMovingCurrent() {
        let p = makeController()
        p.play(makeTunes(3), startingAt: 0)
        p.addToEndOfQueue(Tune(id: 99, title: "x", artist: "a"))
        #expect(p.queue.last?.id == 99)
        #expect(p.currentIndex == 0)
    }

    @Test func playNextInsertsDirectlyAfterCurrent() {
        let p = makeController()
        p.play(makeTunes(4), startingAt: 1)
        p.playNext(Tune(id: 99, title: "x", artist: "a"))
        #expect(p.queue.map(\.id) == [1, 2, 99, 3, 4])
        #expect(p.current?.id == 2)
    }

    @Test func removeBeforeCurrentShiftsIndex() {
        let p = makeController()
        p.play(makeTunes(4), startingAt: 2)
        p.removeFromQueue(at: IndexSet(integer: 0))
        #expect(p.queue.map(\.id) == [2, 3, 4])
        #expect(p.currentIndex == 1)
        #expect(p.current?.id == 3) // same track still current
    }

    @Test func removeAfterCurrentKeepsIndex() {
        let p = makeController()
        p.play(makeTunes(4), startingAt: 1)
        p.removeFromQueue(at: IndexSet(integer: 3))
        #expect(p.currentIndex == 1)
        #expect(p.current?.id == 2)
    }

    @Test func removeCurrentAdvances() {
        let p = makeController()
        p.play(makeTunes(3), startingAt: 1)
        p.removeFromQueue(at: IndexSet(integer: 1))
        #expect(p.queue.count == 2)
        #expect(p.current != nil) // playback moved to a neighbor, not stopped
    }

    @Test func removeLastRemainingStops() {
        let p = makeController()
        p.play(makeTunes(1), startingAt: 0)
        p.removeFromQueue(at: IndexSet(integer: 0))
        #expect(p.queue.isEmpty)
        #expect(p.current == nil)
        #expect(!p.isPlaying)
    }

    @Test func moveKeepsCurrentTrackCurrent() {
        let p = makeController()
        p.play(makeTunes(4), startingAt: 1) // current = id 2
        p.moveInQueue(from: IndexSet(integer: 3), to: 0) // move id 4 to front
        #expect(p.queue.map(\.id) == [4, 1, 2, 3])
        #expect(p.current?.id == 2)
        #expect(p.currentIndex == 2)
    }

    @Test func nextAtEndWithRepeatAllWraps() {
        let p = makeController()
        p.play(makeTunes(2), startingAt: 1)
        p.repeatMode = .all
        p.next()
        #expect(p.currentIndex == 0)
    }

    @Test func nextAtEndWithoutRepeatStaysAndPauses() {
        let p = makeController()
        p.play(makeTunes(2), startingAt: 1)
        p.next()
        #expect(p.currentIndex == 1)
        #expect(!p.isPlaying)
    }

    @Test func previousEarlyInTrackGoesBack() {
        let p = makeController()
        p.play(makeTunes(3), startingAt: 2)
        p.previous() // currentTime is 0 (< 3s) → previous track
        #expect(p.currentIndex == 1)
    }

    // MARK: - Review-finding regressions

    @Test func playWithEmptyListStopsInsteadOfStranding() {
        let p = makeController()
        p.play(makeTunes(3), startingAt: 0)
        p.play([], startingAt: 0)
        #expect(p.current == nil)
        #expect(!p.isPlaying)
        p.play(makeTunes(2), startingAt: 5) // out-of-range index
        #expect(p.current == nil)
    }

    @Test func manualNextAdvancesEvenInRepeatOne() {
        let p = makeController()
        p.play(makeTunes(3), startingAt: 0)
        p.repeatMode = .one
        p.next() // user-initiated skip must not be trapped by repeat-one
        #expect(p.currentIndex == 1)
    }

    @Test func removeCurrentTogetherWithEarlierPlaysSuccessor() {
        let p = makeController()
        p.play(makeTunes(5), startingAt: 2) // current = id 3
        p.removeFromQueue(at: IndexSet([0, 2])) // remove id 1 and the current id 3 together
        #expect(p.queue.map(\.id) == [2, 4, 5])
        #expect(p.current?.id == 4) // successor after the removed current, not a stale index
    }

    @Test func moveWithDuplicateTunesKeepsTheRightInstanceCurrent() {
        let p = makeController()
        let dup = Tune(id: 7, title: "dup", artist: "a")
        p.play([dup, makeTunes(1)[0], dup], startingAt: 2) // current = SECOND copy of id 7
        p.moveInQueue(from: IndexSet(integer: 0), to: 2)   // shuffle the first copy around
        #expect(p.current?.id == 7)
        #expect(p.currentIndex == 2) // still the second instance (entry identity, not tune equality)
    }

    @Test func jumpStartsAtRequestedEntry() {
        let p = makeController()
        p.play(makeTunes(4), startingAt: 0)
        p.jump(to: 3)
        #expect(p.currentIndex == 3)
        p.jump(to: 99) // no-op
        #expect(p.currentIndex == 3)
    }

    @Test func stopClearsEverythingWithoutCrashing() {
        let p = makeController()
        p.play(makeTunes(3), startingAt: 1)
        p.stop() // regression: used to deallocate AVPlayer with a live time observer (NSException)
        #expect(p.current == nil)
        #expect(p.queue.count == 3) // queue survives; only playback stops
        #expect(!p.isPlaying)
    }
}
