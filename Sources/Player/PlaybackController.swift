import Foundation
import AVFoundation
import MediaPlayer
import Observation
import UIKit

enum RepeatMode: String, Codable, Sendable { case off, all, one }

/// How an entry got into the queue. Drives the Up Next split: manual additions (play-next, then
/// queued) always precede the remaining auto-added context tracks.
enum QueueOrigin: String, Codable, Sendable, Equatable {
    /// Swipe-left "play next" — jumps the line, FIFO within its own block.
    case playNext
    /// Swipe-right "add to queue" — after all play-next items, FIFO within its own block.
    case queued
    /// Auto-added because a track was tapped inside a crate/search (the rest of that context).
    case context
}

/// A queue slot with identity independent of the tune it holds — the same track queued twice must
/// be two distinct, individually movable/removable rows.
struct QueueEntry: Identifiable, Equatable, Sendable {
    let id: UUID
    var tune: Tune
    var origin: QueueOrigin
    init(_ tune: Tune, origin: QueueOrigin = .context) { self.id = UUID(); self.tune = tune; self.origin = origin }
}

/// Disk snapshot of the queue ("queue_v1"). Runtime UUIDs are process-local, so entry identity
/// is positional here: `preShuffleOrder` stores indices into `entries` *as saved*, remapped
/// onto freshly minted UUIDs on restore (before pruning — pruning shifts positions).
struct PersistedQueue: Codable, Sendable {
    enum Mode: String, Codable, Sendable { case library, demo }
    struct Entry: Codable, Sendable {
        var tune: Tune
        var origin: QueueOrigin
    }
    var v: Int = 1
    var mode: Mode
    var entries: [Entry]
    var currentIndex: Int?
    var contextName: String?
    var repeatMode: RepeatMode
    var isShuffled: Bool
    var preShuffleOrder: [Int]
    var currentTime: Double
}

/// The phone *is* the player (Philosophy #5): its own queue, streaming audio on-device, with full
/// system media integration. A downloaded local file is always preferred over the stream.
@MainActor
@Observable
final class PlaybackController {
    // Queue state
    private(set) var entries: [QueueEntry] = []
    private(set) var currentIndex: Int? = nil
    private(set) var isPlaying = false
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    /// Set when the current track can't be played (no server, stream failed). UI shows it honestly
    /// instead of a fake playing state (Philosophy #7).
    private(set) var playbackError: String? = nil
    var repeatMode: RepeatMode = .off {
        didSet { scheduleSave() } // @Observable preserves property observers
    }
    /// Toggle only via toggleShuffle() — the flag must never flip without the reorder side
    /// effect (it was a dead flag once; see docs/design/dogfood-round-3.md W1). restore(from:)
    /// is the one sanctioned direct assignment: its entries arrive already in shuffled order
    /// with the un-shuffle snapshot alongside.
    private(set) var isShuffled = false
    /// Original relative order (entry IDs) of the context tracks, snapshotted when shuffle
    /// turns on. Un-shuffling sorts the surviving upcoming context entries back into this order.
    @ObservationIgnored private var preShuffleOrder: [UUID] = []
    /// Test seam: inject a seeded generator for deterministic shuffle assertions.
    @ObservationIgnored var shuffleRNG: any RandomNumberGenerator = SystemRandomNumberGenerator()
    /// Lap guard for auto-skipping unplayable tracks: an entirely dead queue must stop with an
    /// honest error after one pass, not loop failures forever.
    private var consecutiveFailures = 0
    /// Where the context part of the queue came from (crate name, "Search"…) — shown as the
    /// Up Next section label.
    private(set) var contextName: String? = nil

    /// Tune-only view of the queue, for lists and tests.
    var queue: [Tune] { entries.map(\.tune) }
    var current: Tune? { currentEntry?.tune }
    var currentEntry: QueueEntry? {
        guard let i = currentIndex, entries.indices.contains(i) else { return nil }
        return entries[i]
    }
    var hasContent: Bool { current != nil }

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var failedObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    private var interruptionObserver: NSObjectProtocol?
    private var audioSessionActivated = false
    private var connection: CratesConnection?
    private var downloads: DownloadManager?
    /// Lock-screen / Control Center artwork for the current track. Kept alongside its coverID so
    /// `updateNowPlaying()` never attaches a stale image after a track change.
    private var currentArtwork: (coverID: Int64, artwork: MPMediaItemArtwork)?
    private var artworkTask: Task<Void, Never>?
    /// Set while an AVPlayer seek is in flight; the periodic time observer stays quiet until it
    /// lands so the scrubber doesn't snap back to pre-seek times.
    private var pendingSeekTarget: Double?

    /// Async preview resolution in flight (Bandcamp). Cancelled on every track change.
    @ObservationIgnored private var resolveTask: Task<Void, Never>?
    /// Seam so tests can stub resolution without touching the network.
    @ObservationIgnored var previewResolver: @Sendable (Tune) async throws -> URL = { tune in
        try await BandcampResolver.shared.resolve(tune)
    }

    // MARK: Persistence state
    /// Which world the queue belongs to; nil disables persistence entirely (pre-bootstrap,
    /// hermetic UI tests). Set by AppModel.
    @ObservationIgnored var persistenceMode: PersistedQueue.Mode?
    /// Fires when a track starts fresh (not on persistence-restore resume). AppModel wires this
    /// to the local usage log; kept as a hook so the player stays library-agnostic.
    @ObservationIgnored var onTrackStarted: ((Tune) -> Void)?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var lastSavedTime: Double = 0
    /// nonisolated: read from detached persistence tasks (precedent: AppModel.cursorKey).
    private nonisolated static let queueCacheKey = "queue_v1"
    /// UI-test etiquette: `-uitestSilent` zeroes the AVPlayer's own volume (never the system's)
    /// so live simulator runs can assert real playback without blasting audio from the host Mac.
    @ObservationIgnored private let forceSilent =
        ProcessInfo.processInfo.arguments.contains("-uitestSilent")
    /// Screenshot automation can opt into a bundled silent track so the player stays in a
    /// representative playing state without a server or network dependency. Ordinary demo mode
    /// remains intentionally honest about unavailable audio.
    @ObservationIgnored private let usePlayableDemoFixture =
        ProcessInfo.processInfo.arguments.contains("-uitestPlayableDemo")

    init() {
        // Category only — activation waits for the first actual play, so launching the app never
        // silences another app's audio.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        configureRemoteCommands()
        observeInterruptions()
    }

    func attach(connection: CratesConnection, downloads: DownloadManager) {
        self.connection = connection
        self.downloads = downloads
    }

    // MARK: - Queue actions (Idea #5: swipe to queue)
    //
    // Up Next ordering invariant: after the current track come the manual additions —
    // play-next items (FIFO), then queued items (FIFO) — and only then the rest of the
    // auto-added context. Manual additions always jump ahead of the remaining context.

    /// Swipe-right gesture target: add to the queue — plays after all manual additions,
    /// before the remaining context tracks.
    func addToEndOfQueue(_ tune: Tune) {
        let entry = QueueEntry(tune, origin: .queued)
        guard let i = currentIndex else {
            entries.append(entry)
            startPlayback(at: entries.count - 1)
            return
        }
        var pos = i + 1
        while pos < entries.count, entries[pos].origin != .context { pos += 1 }
        entries.insert(entry, at: pos)
        scheduleSave()
    }

    /// Swipe-left gesture target: play next — goes to the end of the play-next block (FIFO),
    /// ahead of queued items and context.
    func playNext(_ tune: Tune) {
        let entry = QueueEntry(tune, origin: .playNext)
        guard let i = currentIndex else {
            entries.insert(entry, at: 0)
            startPlayback(at: 0)
            return
        }
        var pos = i + 1
        while pos < entries.count, entries[pos].origin == .playNext { pos += 1 }
        entries.insert(entry, at: pos)
        scheduleSave()
    }

    /// Replace the queue and start from a chosen index (e.g. tapping a track in a crate).
    /// An empty list or out-of-range index stops playback rather than stranding orphaned audio.
    func play(_ tunes: [Tune], startingAt index: Int, context: String? = nil) {
        guard !tunes.isEmpty, tunes.indices.contains(index) else { stop(); return }
        entries = tunes.map { QueueEntry($0, origin: .context) }
        contextName = context
        consecutiveFailures = 0
        startPlayback(at: index)
        if isShuffled {
            // Shuffle survives a context change (platform convention): the tapped track
            // starts, the rest of the new context shuffles behind it.
            preShuffleOrder = entries.map(\.id) // all .context by construction
            shuffleUpcomingContext()
        }
    }

    /// Tap-to-jump in the queue sheet.
    func jump(to index: Int) {
        guard entries.indices.contains(index) else { return }
        consecutiveFailures = 0 // user-initiated: give the lap guard a fresh lap
        startPlayback(at: index)
    }

    func removeFromQueue(at offsets: IndexSet) {
        guard !offsets.isEmpty else { return }
        let removingCurrent = currentIndex.map { offsets.contains($0) } ?? false

        if removingCurrent, let ci = currentIndex {
            // Successor: nearest surviving entry after the current one, else nearest before.
            let successorID = entries.indices
                .filter { !offsets.contains($0) }
                .min { a, b in
                    let (da, db) = (a > ci ? a - ci : ci - a + entries.count, b > ci ? b - ci : ci - b + entries.count)
                    return da < db
                }
                .map { entries[$0].id }
            entries.remove(atOffsets: offsets)
            if let sid = successorID, let newIndex = entries.firstIndex(where: { $0.id == sid }) {
                startPlayback(at: newIndex)
            } else {
                stop()
            }
        } else {
            let currentID = currentEntry?.id
            entries.remove(atOffsets: offsets)
            if let cid = currentID {
                currentIndex = entries.firstIndex(where: { $0.id == cid })
            }
        }
        scheduleSave()
    }

    func moveInQueue(from source: IndexSet, to destination: Int) {
        let currentID = currentEntry?.id
        entries.move(fromOffsets: source, toOffset: destination)
        if let cid = currentID {
            currentIndex = entries.firstIndex(where: { $0.id == cid })
        }
        scheduleSave()
    }

    // MARK: - Persistence (dogfood round 4, I4)

    /// Debounced structural save — call after any queue/state mutation. The 500ms window
    /// coalesces bursts (queue-all, multi-remove) into one disk write.
    private func scheduleSave() {
        guard persistenceMode != nil else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.saveQueueNow()
        }
    }

    /// Immediate save — pause, background transition, and the 5s position cadence. A stopped
    /// queue (currentIndex nil) is not restorable, so it never overwrites the last good state.
    func saveQueueNow() {
        guard let snapshot = persistedSnapshot() else { return }
        lastSavedTime = currentTime
        Task.detached { await DiskCache.shared.save(snapshot, key: Self.queueCacheKey) }
    }

    private func persistedSnapshot() -> PersistedQueue? {
        guard let mode = persistenceMode, let index = currentIndex else { return nil }
        let indexByID = Dictionary(uniqueKeysWithValues: entries.enumerated().map { ($1.id, $0) })
        return PersistedQueue(
            mode: mode,
            entries: entries.map { .init(tune: $0.tune, origin: $0.origin) },
            currentIndex: index,
            contextName: contextName,
            repeatMode: repeatMode,
            isShuffled: isShuffled,
            preShuffleOrder: preShuffleOrder.compactMap { indexByID[$0] },
            currentTime: currentTime)
    }

    /// Rebuild the queue from a snapshot, PAUSED — primes current/duration/currentTime and the
    /// system now-playing info WITHOUT creating an AVPlayer; the first resume() builds the
    /// engine and seeks. No-op on mode mismatch, an already-active queue, or nothing surviving.
    func restore(from saved: PersistedQueue, mode: PersistedQueue.Mode, validTuneIDs: Set<Int64>? = nil) {
        persistenceMode = mode
        guard entries.isEmpty, currentIndex == nil else { return } // user beat the restore
        guard saved.mode == mode, let savedIndex = saved.currentIndex,
              saved.entries.indices.contains(savedIndex) else { return }

        let minted = saved.entries.map { QueueEntry($0.tune, origin: $0.origin) }
        // Remap positional pre-shuffle order onto the fresh UUIDs BEFORE pruning.
        let mintedPreShuffle = saved.preShuffleOrder.compactMap {
            minted.indices.contains($0) ? minted[$0].id : nil
        }
        let currentID = minted[savedIndex].id

        // Prune tunes deleted since the save (nil = can't validate, trust the snapshot).
        // The current entry is always kept — its failure path reports honestly if it's gone.
        let kept: [QueueEntry] = validTuneIDs.map { valid in
            minted.filter { $0.id == currentID || valid.contains($0.tune.id) }
        } ?? minted
        guard let newIndex = kept.firstIndex(where: { $0.id == currentID }) else { return }

        entries = kept
        currentIndex = newIndex
        contextName = saved.contextName
        repeatMode = saved.repeatMode
        isShuffled = saved.isShuffled // sanctioned direct assignment — see the declaration
        preShuffleOrder = saved.isShuffled ? mintedPreShuffle : []

        // Paused prime: position + lock-screen metadata, no AVPlayer until resume().
        isPlaying = false
        currentTime = saved.currentTime
        duration = kept[newIndex].tune.lengthSeconds ?? 0
        lastSavedTime = saved.currentTime
        updateNowPlaying()
        loadArtwork(for: kept[newIndex].tune)
    }

    func restoreQueue(mode: PersistedQueue.Mode, validTuneIDs: Set<Int64>? = nil) async {
        let saved: PersistedQueue? = await DiskCache.shared.load(Self.queueCacheKey, as: PersistedQueue.self)
        if let saved {
            restore(from: saved, mode: mode, validTuneIDs: validTuneIDs)
        } else {
            persistenceMode = mode
        }
    }

    /// A sync landed: drop queue entries whose tunes no longer exist (the current entry is
    /// always kept — pruning it would force an autoplay-or-stop decision mid-listen).
    func pruneDeletedTunes(valid: Set<Int64>) {
        guard !valid.isEmpty else { return }
        let currentID = currentEntry?.id
        let kept = entries.filter { $0.id == currentID || valid.contains($0.tune.id) }
        guard kept.count != entries.count else { return }
        entries = kept
        if let cid = currentID { currentIndex = entries.firstIndex { $0.id == cid } }
        scheduleSave()
    }

    func eraseQueuePersistence() {
        saveTask?.cancel()
        persistenceMode = nil
        Task.detached { await DiskCache.shared.remove(Self.queueCacheKey) }
    }

    /// Test hook: the positional pre-shuffle mapping exactly as persistedSnapshot writes it.
    var preShuffleOrder_forTesting: [Int] {
        let indexByID = Dictionary(uniqueKeysWithValues: entries.enumerated().map { ($1.id, $0) })
        return preShuffleOrder.compactMap { indexByID[$0] }
    }

    // MARK: - Shuffle
    //
    // Shuffles only the upcoming *context* entries: manual play-next/queued rows keep their
    // exact slots, so the Up Next origin invariant — and the origin-scanning inserts in
    // playNext/addToEndOfQueue — keep working unchanged while shuffled. (Do not "fix" this to
    // shuffle the whole upcoming region: interleaved origins silently break both inserts.)

    func toggleShuffle() {
        if isShuffled {
            isShuffled = false
            restoreUpcomingContextOrder()
            preShuffleOrder = []
        } else {
            isShuffled = true
            preShuffleOrder = entries.filter { $0.origin == .context }.map(\.id)
            shuffleUpcomingContext()
        }
        scheduleSave()
    }

    /// Indices after the current track holding auto-added context entries — the only slots
    /// shuffle may permute.
    private var upcomingContextSlots: [Int] {
        let start = (currentIndex ?? -1) + 1
        return entries.indices.filter { $0 >= start && entries[$0].origin == .context }
    }

    private func shuffleUpcomingContext() {
        let slots = upcomingContextSlots
        guard slots.count > 1 else { return }
        var pool = slots.map { entries[$0] }
        var rng = shuffleRNG
        pool.shuffle(using: &rng)
        shuffleRNG = rng
        for (slot, entry) in zip(slots, pool) { entries[slot] = entry }
    }

    private func restoreUpcomingContextOrder() {
        let slots = upcomingContextSlots
        guard slots.count > 1 else { return }
        let rank = Dictionary(uniqueKeysWithValues: preShuffleOrder.enumerated().map { ($1, $0) })
        let restored = slots.map { entries[$0] }
            .sorted { (rank[$0.id] ?? .max) < (rank[$1.id] ?? .max) } // stable: strangers keep current order
        for (slot, entry) in zip(slots, restored) { entries[slot] = entry }
    }

    // MARK: - Transport

    func togglePlayPause() { isPlaying ? pause() : resume() }

    func resume() {
        guard let i = currentIndex, current != nil else { return }
        if player == nil {
            // Primed restore (relaunch) or a prior no-URL failure: build the engine now, from
            // the primed position — never a fake isPlaying without audio.
            startPlayback(at: i, from: currentTime)
            return
        }
        activateAudioSessionIfNeeded()
        player?.play(); isPlaying = true; updateNowPlaying()
    }

    func pause() {
        // Cancel any in-flight preview resolve: without this, a resolve that lands after the
        // user (or an interruption) paused would barge audio in. Cancelling leaves the track
        // in the primed-paused shape; resume() rebuilds from currentTime and re-coalesces.
        resolveTask?.cancel(); resolveTask = nil
        player?.pause(); isPlaying = false; updateNowPlaying()
        saveQueueNow() // pause is a natural checkpoint — never lose the position here
    }

    func stop() {
        removeObservers() // must run while the AVPlayer is alive — deallocating with a live time observer is a hard crash
        player?.replaceCurrentItem(with: nil)
        player = nil
        currentIndex = nil; isPlaying = false
        currentTime = 0; duration = 0; playbackError = nil
        pendingSeekTarget = nil
        resolveTask?.cancel(); resolveTask = nil
        artworkTask?.cancel(); artworkTask = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    /// User-initiated skip: always advances (repeat-one applies to natural track end, not to the
    /// user explicitly asking for the next track).
    func next() { advance(honorRepeatOne: false) }

    /// Fired exactly at natural completion — the played-to-the-end moment, never a skip or a
    /// failure. AppModel wires this into play-count sync (TODO §5).
    @ObservationIgnored var onTrackCompleted: ((Tune) -> Void)?

    /// Natural end-of-track: count the completed play, then honor repeat-one.
    private func trackDidEnd() {
        if let tune = current { onTrackCompleted?(tune) }
        advance(honorRepeatOne: true)
    }

    private func advance(honorRepeatOne: Bool) {
        guard let i = currentIndex else { return }
        if honorRepeatOne, repeatMode == .one { seek(to: 0); resume(); return }
        if i + 1 < entries.count { startPlayback(at: i + 1) }
        else if repeatMode == .all, !entries.isEmpty { startPlayback(at: 0) }
        else { pause(); seek(to: 0) }
    }

    func previous() {
        guard let i = currentIndex else { return }
        if currentTime > 3 { seek(to: 0); return } // restart current if >3s in
        if i > 0 { startPlayback(at: i - 1) }
        else { seek(to: 0) }
    }

    func seek(to seconds: Double) {
        currentTime = seconds
        updateNowPlaying()
        guard let player else { return }
        // Mute the periodic observer until the seek lands, and seek with zero tolerance:
        // the default keyframe tolerance can land whole seconds away, which reads as the
        // scrubber thumb snapping around after release.
        pendingSeekTarget = seconds
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor in
                guard let self, finished else { return } // superseded by a newer seek
                self.pendingSeekTarget = nil
            }
        }
        scheduleSave()
    }

    // MARK: - Engine

    private func startPlayback(at index: Int, from resumeTime: Double = 0) {
        guard entries.indices.contains(index) else { return }
        currentIndex = index
        playbackError = nil
        pendingSeekTarget = nil
        resolveTask?.cancel()
        let tune = entries[index].tune
        currentTime = resumeTime
        duration = tune.lengthSeconds ?? 0
        // Fresh starts only (resumeTime > 0 is a persistence restore of an already-counted
        // play) — feeds the local usage log / Recently Played shelf.
        if resumeTime == 0 { onTrackStarted?(tune) }

        if let url = resolvePlaybackURL(for: tune) {
            beginEngine(tune: tune, url: url, resumeTime: resumeTime, attachAuth: !url.isFileURL)
            return
        }

        if BandcampResolver.canResolve(tune) {
            // Bandcamp preview (dogfood: online-source previews): resolve the stream URL
            // client-side — the same mechanism the desktop uses — then play natively.
            removeObservers()
            player?.replaceCurrentItem(with: nil)
            player = nil // so resume() during the resolve re-enters startPlayback, not a dead item
            isPlaying = false
            updateNowPlaying()
            loadArtwork(for: tune)
            let entryID = entries[index].id
            let resolve = previewResolver
            // Explicit @MainActor: state mutation + engine spin-up must land on the actor
            // (this target compiles in Swift 5 mode, so inference slips are warnings only).
            resolveTask = Task { @MainActor [weak self] in
                do {
                    let url = try await resolve(tune)
                    guard let self, !Task.isCancelled, self.currentEntry?.id == entryID else { return }
                    // Honor user intent formed DURING the resolve (a pause/interruption cancels
                    // resolveTask, so reaching here means play is still wanted) and pick up any
                    // scrub that happened while resolving via the live currentTime.
                    // attachAuth false is load-bearing: NEVER send the server's bearer token
                    // to an external CDN.
                    self.beginEngine(tune: tune, url: url, resumeTime: self.currentTime, attachAuth: false)
                } catch {
                    guard let self, !Task.isCancelled, self.currentEntry?.id == entryID else { return }
                    self.handlePlaybackFailure("Preview unavailable — the artist may have disabled streaming.")
                }
            }
            return
        }

        // No local file, no server audio, no preview: same stranding shape as a failed
        // stream, so it takes the same auto-skip path (recursion is bounded by the lap
        // guard — an entirely dead queue stops after one pass, honestly).
        removeObservers()
        player?.replaceCurrentItem(with: nil)
        // Distinguish "the server has no audio for this tune" (online import we can't preview)
        // from "we can't reach the server" — the old message claimed the latter for both.
        let message = (connection?.isConfigured == true && tune.knownUnstreamable)
            ? "\(tune.source.label) only — no audio file on the server."
            : "Not available — no server connection and not downloaded."
        handlePlaybackFailure(message)
    }

    /// The actual AVPlayer engine spin-up, shared by the direct and resolved-preview paths.
    private func beginEngine(tune: Tune, url: URL, resumeTime: Double, attachAuth: Bool) {
        pendingSeekTarget = nil // any seek issued during a resolve is folded into resumeTime
        let asset: AVURLAsset
        if url.isFileURL || !attachAuth {
            asset = AVURLAsset(url: url)
        } else {
            // Attach the bearer header to the streaming asset (AVURLAsset can't read it otherwise).
            asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": connection?.authHeader ?? [:]])
        }
        let item = AVPlayerItem(asset: asset)

        removeObservers()
        let p = player ?? AVPlayer()
        if forceSilent { p.volume = 0 }
        p.replaceCurrentItem(with: item)
        player = p
        installObservers(on: item)
        activateAudioSessionIfNeeded()
        p.play(); isPlaying = true
        if resumeTime > 0 { seek(to: resumeTime) } // AVFoundation queues seeks on loading items
        updateNowPlaying()
        loadArtwork(for: tune)
        scheduleSave()
    }

    /// Local file wins if downloaded; otherwise stream by tune id (Philosophy #4/#5). Tunes the
    /// server is KNOWN to refuse (codec-null) return nil so the preview path can take over
    /// instead of burning a doomed request.
    private func resolvePlaybackURL(for tune: Tune) -> URL? {
        if let local = downloads?.localFileURL(for: tune.id) { return local }
        if usePlayableDemoFixture,
           let fixture = Bundle.main.url(forResource: "demo-preview", withExtension: "m4a") {
            return fixture
        }
        guard tune.hasServerAudio != false else { return nil }
        guard let conn = connection, conn.isConfigured else { return nil }
        return conn.streamURL(tuneID: tune.id)
    }

    private func installObservers(on item: AVPlayerItem) {
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] t in
            guard let self else { return }
            guard self.pendingSeekTarget == nil else { return } // seek in flight — don't fight it
            self.currentTime = t.seconds
            if abs(self.currentTime - self.lastSavedTime) >= 5 { self.saveQueueNow() } // position cadence
            if self.duration == 0 {
                let d = item.duration.seconds
                if d.isFinite, d > 0 { self.duration = d }
            }
            self.updateNowPlayingTime()
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.trackDidEnd() }
        }
        // A dying stream mid-track posts FailedToPlayToEndTime while item.status can stay
        // .readyToPlay — without this observer the app froze in a fake playing state and
        // repeat/advance silently died (dogfood round 3, W1).
        failedObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
        ) { [weak self] note in
            let message = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError)?
                .localizedDescription ?? "The stream stopped unexpectedly."
            Task { @MainActor in self?.handlePlaybackFailure(message) }
        }
        // Surface load failures (bad token, server refusal, unsupported codec) AND move on:
        // a failed item never posts DidPlayToEndTime, so without advancing here one dead
        // track strands the entire queue.
        statusObservation = item.observe(\.status) { [weak self] item, _ in
            switch item.status {
            case .readyToPlay:
                Task { @MainActor in self?.consecutiveFailures = 0 } // a track that loads resets the lap guard
            case .failed:
                let message = item.error?.localizedDescription ?? "The stream failed to load."
                Task { @MainActor in self?.handlePlaybackFailure(message) }
            default:
                break
            }
        }
    }

    /// Common exit for every way a track can die (load failure, mid-stream death, no URL):
    /// surface the honest error, then auto-skip — unless we've already failed our way around
    /// the whole queue, in which case stop advancing and leave the error visible.
    func handlePlaybackFailure(_ message: String) {
        isPlaying = false
        playbackError = message
        updateNowPlaying()
        if let current, current.source == .bandcamp {
            // Likely an expired signed URL — drop it so the next attempt re-resolves fresh.
            let id = current.id
            Task.detached { await BandcampResolver.shared.invalidate(id) }
        }
        consecutiveFailures += 1
        guard consecutiveFailures < max(entries.count, 1) else { return } // full dead lap — stop honestly
        advance(honorRepeatOne: false) // never honorRepeatOne: repeat-one would re-seek the dead item forever
    }

    private func removeObservers() {
        if let t = timeObserver { player?.removeTimeObserver(t); timeObserver = nil }
        if let e = endObserver { NotificationCenter.default.removeObserver(e); endObserver = nil }
        if let f = failedObserver { NotificationCenter.default.removeObserver(f); failedObserver = nil }
        statusObservation?.invalidate(); statusObservation = nil
    }

    // MARK: - System integration

    private func activateAudioSessionIfNeeded() {
        guard !audioSessionActivated else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            audioSessionActivated = true
        } catch {
            // Non-fatal in the simulator; playback still works for local files.
        }
    }

    private func observeInterruptions() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            // Extract Sendable scalars before hopping actors — userInfo itself isn't Sendable.
            let rawType = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let rawOptions = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
            Task { @MainActor in
                guard let self, let raw = rawType,
                      let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
                switch type {
                case .began:
                    self.pause()
                case .ended:
                    if let optRaw = rawOptions,
                       AVAudioSession.InterruptionOptions(rawValue: optRaw).contains(.shouldResume) {
                        self.resume()
                    }
                @unknown default: break
                }
            }
        }
    }

    private func configureRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in Task { @MainActor in self?.resume() }; return .success }
        c.pauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.pause() }; return .success }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.togglePlayPause() }; return .success }
        c.nextTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.next() }; return .success }
        c.previousTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.previous() }; return .success }
        c.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.seek(to: e.positionTime) }
            return .success
        }
    }

    private func updateNowPlaying() {
        guard let tune = current else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: tune.displayTitle,
            MPMediaItemPropertyArtist: tune.displayArtist,
            MPMediaItemPropertyAlbumTitle: tune.album,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
        ]
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        if let art = currentArtwork, art.coverID == tune.coverID {
            info[MPMediaItemPropertyArtwork] = art.artwork
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// Fetch the cover for the system player through the shared ArtworkStore — instant when
    /// cached (the user just tapped the row showing it) and offline-capable. Failure just
    /// leaves the system player artless — never blocks playback.
    private func loadArtwork(for tune: Tune) {
        artworkTask?.cancel()
        defer { prefetchUpcomingArtwork() }
        guard let coverID = tune.coverID else { return }
        if currentArtwork?.coverID == coverID { return } // same cover (e.g. same album), keep it
        artworkTask = Task { [weak self] in
            guard let image = await ArtworkStore.shared.image(coverID: coverID, variant: .display),
                  !Task.isCancelled else { return }
            // The request handler must NOT be MainActor-isolated (the implicit default inside
            // this class): MediaPlayer calls it on its own accessQueue when the lock screen
            // renders, and the runtime isolation check traps — EXC_BREAKPOINT on every real
            // track with cover art (found via on-device crash log, 2026-07-04). UIImage is
            // immutable here, so handing it across is safe.
            nonisolated(unsafe) let artworkImage = image
            let artwork = MPMediaItemArtwork(boundsSize: artworkImage.size) { @Sendable _ in artworkImage }
            guard let self, self.current?.coverID == coverID else { return }
            self.currentArtwork = (coverID, artwork)
            self.updateNowPlaying()
        }
    }

    /// Warm the next few queue covers so track changes and the lock screen render instantly.
    private func prefetchUpcomingArtwork() {
        guard let i = currentIndex else { return }
        let upcoming = entries.dropFirst(i + 1).prefix(3).compactMap(\.tune.coverID)
        guard !upcoming.isEmpty else { return }
        ArtworkStore.shared.prefetch(coverIDs: Array(upcoming), variant: .display)
    }

    private func updateNowPlayingTime() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
    }
}
