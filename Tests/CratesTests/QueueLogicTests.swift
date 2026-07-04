import Testing
import Foundation
@testable import CratesIOS

/// Deterministic RNG (SplitMix64) so shuffle tests assert exact behavior, not probabilities.
private struct SeededRNG: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

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

    @Test func addToQueueJumpsAheadOfRemainingContext() {
        let p = makeController()
        p.play(makeTunes(3), startingAt: 0)
        p.addToEndOfQueue(Tune(id: 99, title: "x", artist: "a"))
        // Manual additions play before the rest of the auto-added context.
        #expect(p.queue.map(\.id) == [1, 99, 2, 3])
        #expect(p.currentIndex == 0)
    }

    @Test func playNextInsertsDirectlyAfterCurrent() {
        let p = makeController()
        p.play(makeTunes(4), startingAt: 1)
        p.playNext(Tune(id: 99, title: "x", artist: "a"))
        #expect(p.queue.map(\.id) == [1, 2, 99, 3, 4])
        #expect(p.current?.id == 2)
    }

    /// The Up Next ordering invariant: play-next block (FIFO), then queued block (FIFO), then
    /// the remaining context tracks.
    @Test func manualBlocksKeepFIFOOrderAheadOfContext() {
        let p = makeController()
        p.play(makeTunes(4), startingAt: 0) // context: [1][2,3,4]
        p.addToEndOfQueue(Tune(id: 90, title: "q1", artist: "a"))
        p.playNext(Tune(id: 91, title: "n1", artist: "a"))
        p.playNext(Tune(id: 92, title: "n2", artist: "a"))
        p.addToEndOfQueue(Tune(id: 93, title: "q2", artist: "a"))
        #expect(p.queue.map(\.id) == [1, 91, 92, 90, 93, 2, 3, 4])
        #expect(p.entries[1].origin == .playNext)
        #expect(p.entries[3].origin == .queued)
        #expect(p.entries[5].origin == .context)
    }

    @Test func playRecordsContextName() {
        let p = makeController()
        p.play(makeTunes(2), startingAt: 0, context: "Peak Time")
        #expect(p.contextName == "Peak Time")
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

    // MARK: - Shuffle (deterministic via seeded RNG)

    @Test func shuffleKeepsCurrentAndShufflesOnlyUpcoming() {
        let p = makeController()
        p.shuffleRNG = SeededRNG(state: 1)
        p.play(makeTunes(10), startingAt: 2)
        let before = p.queue.map(\.id)
        p.toggleShuffle()
        #expect(p.isShuffled)
        #expect(p.currentIndex == 2)
        #expect(p.current?.id == 3)
        #expect(Array(p.queue.map(\.id).prefix(3)) == Array(before.prefix(3))) // played + current untouched
        #expect(Set(p.queue.map(\.id)) == Set(before)) // same tracks, none lost or duplicated
        #expect(p.queue.map(\.id) != before) // seeded RNG: order actually changed
    }

    @Test func unshuffleRestoresOriginalUpcomingOrder() {
        let p = makeController()
        p.shuffleRNG = SeededRNG(state: 7)
        p.play(makeTunes(8), startingAt: 1)
        let before = p.queue.map(\.id)
        p.toggleShuffle()
        p.toggleShuffle()
        #expect(!p.isShuffled)
        #expect(p.queue.map(\.id) == before)
    }

    @Test func unshuffleAfterAdvancingRestoresRemainingRelativeOrder() {
        let p = makeController()
        p.shuffleRNG = SeededRNG(state: 3)
        p.play(makeTunes(8), startingAt: 0)
        let original = p.queue.map(\.id)
        p.toggleShuffle()
        p.next(); p.next() // advance into the shuffled region
        let playedPrefix = Array(p.queue.map(\.id).prefix((p.currentIndex ?? 0) + 1))
        p.toggleShuffle()
        // Played/current tracks stay where they landed; the remainder returns to original
        // relative order.
        #expect(Array(p.queue.map(\.id).prefix(playedPrefix.count)) == playedPrefix)
        let remaining = Array(p.queue.map(\.id).dropFirst(playedPrefix.count))
        let expected = original.filter { remaining.contains($0) }
        #expect(remaining == expected)
    }

    @Test func manualAddsLandCorrectlyWhileShuffled() {
        let p = makeController()
        p.shuffleRNG = SeededRNG(state: 5)
        p.play(makeTunes(6), startingAt: 0)
        p.toggleShuffle()
        p.playNext(Tune(id: 90, title: "n", artist: "a"))
        p.addToEndOfQueue(Tune(id: 91, title: "q", artist: "a"))
        // Origin invariant survives shuffling: play-next block, queued block, then context.
        #expect(p.entries[1].origin == .playNext && p.entries[1].tune.id == 90)
        #expect(p.entries[2].origin == .queued && p.entries[2].tune.id == 91)
        p.toggleShuffle()
        // Manual rows keep their slots through un-shuffle.
        #expect(p.entries[1].tune.id == 90)
        #expect(p.entries[2].tune.id == 91)
    }

    @Test func playWhileShuffledStartsTappedTrackAndKeepsFlag() {
        let p = makeController()
        p.shuffleRNG = SeededRNG(state: 9)
        p.play(makeTunes(5), startingAt: 0)
        p.toggleShuffle()
        p.play(makeTunes(7), startingAt: 4) // new context while shuffled
        #expect(p.isShuffled)
        #expect(p.current?.id == 5) // the tapped track always plays
        #expect(Set(p.queue.map(\.id)) == Set((1...7).map(Int64.init)))
    }

    // MARK: - Failure auto-advance (the device repeat-all bug)

    @Test func failureAutoAdvancesToNextTrack() {
        let p = makeController()
        p.play(makeTunes(3), startingAt: 0)
        p.handlePlaybackFailure("dead")
        #expect(p.currentIndex == 1) // skipped past the dead track
    }

    @Test func allDeadQueueStopsAfterOneLapInsteadOfLooping() {
        let p = makeController()
        p.play(makeTunes(3), startingAt: 0)
        p.repeatMode = .all
        p.handlePlaybackFailure("dead")
        p.handlePlaybackFailure("dead")
        p.handlePlaybackFailure("dead") // third consecutive failure = full lap
        let stuck = p.currentIndex
        p.handlePlaybackFailure("dead")
        #expect(p.currentIndex == stuck) // lap guard: no further advancing
        #expect(p.playbackError != nil)
        #expect(!p.isPlaying)
    }

    @Test func userJumpResetsTheFailureLapGuard() {
        let p = makeController()
        p.play(makeTunes(3), startingAt: 0)
        p.handlePlaybackFailure("dead")
        p.handlePlaybackFailure("dead")
        p.handlePlaybackFailure("dead")
        p.jump(to: 0) // user acts — fresh lap
        p.handlePlaybackFailure("dead")
        #expect(p.currentIndex == 1) // advancing works again
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
