import Testing
import Foundation
@testable import CratesIOS

/// Queue persistence round-trips (dogfood round 4, I4). Snapshots are built and restored
/// in-memory via persistedSnapshot()/restore(from:) — DiskCache never touches these tests.
@MainActor
struct QueuePersistenceTests {
    private func makeTunes(_ n: Int) -> [Tune] {
        (1...n).map { Tune(id: Int64($0), title: "t\($0)", artist: "a", lengthSeconds: 180) }
    }

    private func makeController() -> PlaybackController {
        let p = PlaybackController()
        p.attach(connection: CratesConnection(host: "127.0.0.1", port: 54735, token: "test"),
                 downloads: DownloadManager())
        p.persistenceMode = .library
        return p
    }

    private func snapshot(of p: PlaybackController) -> PersistedQueue? {
        // persistedSnapshot is private; reconstruct through the public save path shape.
        // Instead: build directly from public state for assertion-side snapshots.
        guard let index = p.currentIndex else { return nil }
        return PersistedQueue(
            mode: .library,
            entries: p.entries.map { .init(tune: $0.tune, origin: $0.origin) },
            currentIndex: index,
            contextName: p.contextName,
            repeatMode: p.repeatMode,
            isShuffled: p.isShuffled,
            preShuffleOrder: p.preShuffleOrder_forTesting,
            currentTime: p.currentTime)
    }

    @Test func roundTripRestoresOrderOriginsIndexAndContext() {
        let p = makeController()
        p.play(makeTunes(5), startingAt: 2, context: "Crate X")
        p.playNext(Tune(id: 90, title: "n", artist: "a", lengthSeconds: 180))
        p.addToEndOfQueue(Tune(id: 91, title: "q", artist: "a", lengthSeconds: 180))
        let saved = snapshot(of: p)!

        let fresh = makeController()
        fresh.restore(from: saved, mode: .library)
        #expect(fresh.queue.map(\.id) == p.queue.map(\.id))
        #expect(fresh.entries.map(\.origin) == p.entries.map(\.origin))
        #expect(fresh.currentIndex == 2)
        #expect(fresh.contextName == "Crate X")
    }

    @Test func restoreIsPausedAndPrimed() {
        let p = makeController()
        p.play(makeTunes(3), startingAt: 1)
        var saved = snapshot(of: p)!
        saved.currentTime = 42

        let fresh = makeController()
        fresh.restore(from: saved, mode: .library)
        #expect(!fresh.isPlaying)
        #expect(fresh.currentTime == 42)
        #expect(fresh.duration == 180)
        #expect(fresh.current?.id == 2)
    }

    @Test func resumeAfterRestoreKeepsPosition() {
        let p = makeController()
        p.play(makeTunes(3), startingAt: 0)
        var saved = snapshot(of: p)!
        saved.currentTime = 42

        let fresh = makeController()
        fresh.restore(from: saved, mode: .library)
        fresh.resume() // builds the engine from the primed position
        #expect(fresh.currentTime == 42) // startPlayback(from:) must not zero it
        #expect(fresh.isPlaying)
    }

    @Test func shuffleSurvivesRelaunchAndUnshuffles() {
        let p = makeController()
        p.shuffleRNG = SeededPersistenceRNG(state: 4)
        p.play(makeTunes(8), startingAt: 0, context: "C")
        let original = p.queue.map(\.id)
        p.toggleShuffle()
        let saved = snapshot(of: p)!

        let fresh = makeController()
        fresh.restore(from: saved, mode: .library)
        #expect(fresh.isShuffled)
        #expect(fresh.queue.map(\.id) == p.queue.map(\.id)) // shuffled order restored as-is
        fresh.toggleShuffle() // un-shuffle after relaunch restores true crate order
        #expect(fresh.queue.map(\.id) == original)
    }

    @Test func modeMismatchDoesNotRestore() {
        let p = makeController()
        p.play(makeTunes(3), startingAt: 0)
        let saved = snapshot(of: p)! // .library

        let fresh = makeController()
        fresh.restore(from: saved, mode: .demo)
        #expect(fresh.current == nil)
        #expect(fresh.queue.isEmpty)
    }

    @Test func deletedTunesPruneWithCurrentKept() {
        let p = makeController()
        p.play(makeTunes(5), startingAt: 2)
        let saved = snapshot(of: p)!

        let fresh = makeController()
        // Tunes 1 and 5 were deleted server-side; the current (3) is always kept.
        fresh.restore(from: saved, mode: .library, validTuneIDs: [2, 3, 4])
        #expect(fresh.queue.map(\.id) == [2, 3, 4])
        #expect(fresh.current?.id == 3)
    }

    @Test func activeQueueIsNeverClobberedByRestore() {
        let p = makeController()
        p.play(makeTunes(2), startingAt: 0)
        let saved = snapshot(of: p)!

        let busy = makeController()
        busy.play(makeTunes(4), startingAt: 3) // user started playing before restore landed
        busy.restore(from: saved, mode: .library)
        #expect(busy.queue.count == 4)
        #expect(busy.current?.id == 4)
    }

    @Test func pruneDeletedTunesAfterSyncFixesIndex() {
        let p = makeController()
        p.play(makeTunes(5), startingAt: 2) // current = 3
        p.pruneDeletedTunes(valid: [2, 3, 4, 5]) // tune 1 deleted
        #expect(p.queue.map(\.id) == [2, 3, 4, 5])
        #expect(p.current?.id == 3)
        #expect(p.currentIndex == 1)
    }
}

/// Local deterministic RNG (mirror of QueueLogicTests's — fileprivate there).
private struct SeededPersistenceRNG: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
