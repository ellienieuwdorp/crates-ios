import Foundation
import AVFoundation
import MediaPlayer
import Observation
import UIKit

enum RepeatMode: Sendable { case off, all, one }

/// A queue slot with identity independent of the tune it holds — the same track queued twice must
/// be two distinct, individually movable/removable rows.
struct QueueEntry: Identifiable, Equatable, Sendable {
    let id: UUID
    var tune: Tune
    init(_ tune: Tune) { self.id = UUID(); self.tune = tune }
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
    var repeatMode: RepeatMode = .off
    var isShuffled = false

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
    private var statusObservation: NSKeyValueObservation?
    private var interruptionObserver: NSObjectProtocol?
    private var audioSessionActivated = false
    private var connection: CratesConnection?
    private var downloads: DownloadManager?
    /// Lock-screen / Control Center artwork for the current track. Kept alongside its coverID so
    /// `updateNowPlaying()` never attaches a stale image after a track change.
    private var currentArtwork: (coverID: Int64, artwork: MPMediaItemArtwork)?
    private var artworkTask: Task<Void, Never>?

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

    /// Swipe-right gesture target: append to the end of the queue.
    func addToEndOfQueue(_ tune: Tune) {
        entries.append(QueueEntry(tune))
        if currentIndex == nil { startPlayback(at: entries.count - 1) }
    }

    /// Swipe-left gesture target: insert to play immediately after the current track.
    func playNext(_ tune: Tune) {
        guard let i = currentIndex else {
            entries.insert(QueueEntry(tune), at: 0)
            startPlayback(at: 0)
            return
        }
        entries.insert(QueueEntry(tune), at: i + 1)
    }

    /// Replace the queue and start from a chosen index (e.g. tapping a track in a crate).
    /// An empty list or out-of-range index stops playback rather than stranding orphaned audio.
    func play(_ tunes: [Tune], startingAt index: Int) {
        guard !tunes.isEmpty, tunes.indices.contains(index) else { stop(); return }
        entries = tunes.map(QueueEntry.init)
        startPlayback(at: index)
    }

    /// Tap-to-jump in the queue sheet.
    func jump(to index: Int) {
        guard entries.indices.contains(index) else { return }
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
    }

    func moveInQueue(from source: IndexSet, to destination: Int) {
        let currentID = currentEntry?.id
        entries.move(fromOffsets: source, toOffset: destination)
        if let cid = currentID {
            currentIndex = entries.firstIndex(where: { $0.id == cid })
        }
    }

    // MARK: - Transport

    func togglePlayPause() { isPlaying ? pause() : resume() }

    func resume() {
        guard current != nil else { return }
        activateAudioSessionIfNeeded()
        player?.play(); isPlaying = true; updateNowPlaying()
    }

    func pause() {
        player?.pause(); isPlaying = false; updateNowPlaying()
    }

    func stop() {
        removeObservers() // must run while the AVPlayer is alive — deallocating with a live time observer is a hard crash
        player?.replaceCurrentItem(with: nil)
        player = nil
        currentIndex = nil; isPlaying = false
        currentTime = 0; duration = 0; playbackError = nil
        artworkTask?.cancel(); artworkTask = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    /// User-initiated skip: always advances (repeat-one applies to natural track end, not to the
    /// user explicitly asking for the next track).
    func next() { advance(honorRepeatOne: false) }

    /// Natural end-of-track: honors repeat-one.
    private func trackDidEnd() { advance(honorRepeatOne: true) }

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
        player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
        currentTime = seconds
        updateNowPlaying()
    }

    // MARK: - Engine

    private func startPlayback(at index: Int) {
        guard entries.indices.contains(index) else { return }
        currentIndex = index
        playbackError = nil
        let tune = entries[index].tune
        currentTime = 0
        duration = tune.lengthSeconds ?? 0

        guard let url = resolvePlaybackURL(for: tune) else {
            // No local file and no configured server: show the track as current but be honest
            // that it can't play right now — never a fake spinning "playing" state.
            removeObservers()
            player?.replaceCurrentItem(with: nil)
            isPlaying = false
            playbackError = "Not available — no server connection and not downloaded."
            updateNowPlaying()
            return
        }

        let asset: AVURLAsset
        if url.isFileURL {
            asset = AVURLAsset(url: url)
        } else {
            // Attach the bearer header to the streaming asset (AVURLAsset can't read it otherwise).
            let headers = connection?.authHeader ?? [:]
            asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        }
        let item = AVPlayerItem(asset: asset)

        removeObservers()
        let p = player ?? AVPlayer()
        p.replaceCurrentItem(with: item)
        player = p
        installObservers(on: item)
        activateAudioSessionIfNeeded()
        p.play(); isPlaying = true
        updateNowPlaying()
        loadArtwork(for: tune)
    }

    /// Local file wins if downloaded; otherwise stream by tune id (Philosophy #4/#5).
    private func resolvePlaybackURL(for tune: Tune) -> URL? {
        if let local = downloads?.localFileURL(for: tune.id) { return local }
        guard let conn = connection, conn.isConfigured else { return nil }
        return conn.streamURL(tuneID: tune.id)
    }

    private func installObservers(on item: AVPlayerItem) {
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] t in
            guard let self else { return }
            self.currentTime = t.seconds
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
        // Surface stream failures (bad token, server down, unsupported codec) instead of
        // spinning silently with isPlaying == true.
        statusObservation = item.observe(\.status) { [weak self] item, _ in
            guard item.status == .failed else { return }
            let message = item.error?.localizedDescription ?? "The stream failed to load."
            Task { @MainActor in
                guard let self else { return }
                self.isPlaying = false
                self.playbackError = message
                self.updateNowPlaying()
            }
        }
    }

    private func removeObservers() {
        if let t = timeObserver { player?.removeTimeObserver(t); timeObserver = nil }
        if let e = endObserver { NotificationCenter.default.removeObserver(e); endObserver = nil }
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

    /// Fetch the cover for the system player. Covers come from the unauthenticated
    /// `/covers/byCoverID/{id}` endpoint; no cover, demo mode, or fetch failure just leaves the
    /// system player artless — never blocks playback.
    private func loadArtwork(for tune: Tune) {
        artworkTask?.cancel()
        guard let coverID = tune.coverID else { return }
        if currentArtwork?.coverID == coverID { return } // same cover (e.g. same album), keep it
        guard let url = connection?.coverURL(coverID: coverID) else { return }
        artworkTask = Task { [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = UIImage(data: data), !Task.isCancelled else { return }
            let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            guard let self, self.current?.coverID == coverID else { return }
            self.currentArtwork = (coverID, artwork)
            self.updateNowPlaying()
        }
    }

    private func updateNowPlayingTime() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
    }
}
