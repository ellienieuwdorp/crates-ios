import Foundation
import Observation

/// Top-level wiring. Owns the connection, the API client, and the three observable stores
/// (library / player / downloads). Views reach these through the environment.
@MainActor
@Observable
final class AppModel {
    private(set) var connection: CratesConnection
    private(set) var client: CratesClient

    let library = LibraryStore()
    let player = PlaybackController()
    let downloads = DownloadManager()
    let usage = UsageLog()
    let pins = HomePins()

    var isPaired: Bool { connection.isConfigured }
    /// Demo mode lets the POC render a realistic library with no server (simulator, screenshots).
    var isDemo = false

    /// Live onboarding state, surfaced by the pairing/sync UI.
    enum Onboarding: Equatable {
        case idle
        case waitingForApproval            // pairing request sent; approve on the desktop
        case syncing(String, Double)       // downloading/importing the library backup
        case done
        case failed(String)
    }
    private(set) var onboarding: Onboarding = .idle

    private static let connKey = "crates.connection"
    private static let lastSyncKey = "crates.lastSyncDate"
    /// Opaque server-frame delta cursor (max stamp string from the last payload) — see SyncClient.
    /// nonisolated: written from a detached persistence task.
    private nonisolated static let cursorKey = "crates.syncCursor"

    /// Debounce for foreground-triggered delta syncs (a "delta" still moves ~350 KB because
    /// most tables always ship full).
    private var lastDeltaAttempt: Date? = nil

    /// Guards against concurrent/duplicate initial syncs — two overlapping imports race on temp
    /// files and corrupt the parse, then persist garbage over the good cache.
    private var isSyncing = false

    init() {
        let conn = AppModel.loadConnection() ?? CratesConnection(host: "", port: CratesConnection.defaultPort, token: "")
        connection = conn
        client = CratesClient(connection: conn)
        wire()
        // Paired ⇒ the library is backup-backed. Mark it now, before any view's onAppear can fire
        // a REST refreshRoot (whose shape would overwrite the imported crates).
        if conn.isConfigured { library.markSnapshotBacked() }
    }

    private func wire() {
        library.attach(client: client)
        downloads.attach(client: client, connection: connection)
        player.attach(connection: connection, downloads: downloads)
        downloads.nowPlayingTuneID = { [weak player] in player?.current?.id }
        let conn = connection
        Task { await ArtworkStore.shared.update(connection: conn) }
    }

    func bootstrap() async {
        // Hermetic demo mode for UI tests: ignore any persisted pairing and show sample data.
        if ProcessInfo.processInfo.arguments.contains("-uitestDemo") {
            connection = CratesConnection(host: "", port: CratesConnection.defaultPort, token: "")
            await client.update(connection: connection)
            wire()
            enterDemoMode()
            player.persistenceMode = nil // hermetic: no queue state leaks between test runs
            return
        }
        await library.hydrateFromDisk()
        await usage.hydrate()
        pins.configure(demo: false)
        if isPaired {
            // Paired ⇒ the library is backup-synced; disk cache is the source of truth.
            library.markSnapshotBacked()
            // Restore the queue BEFORE any sync: offline-first. An empty hydrated library
            // can't validate tunes — pass nil (an empty set would wipe the whole restore).
            let ids = Set(library.allTunes.map(\.id))
            await player.restoreQueue(mode: .library, validTuneIDs: ids.isEmpty ? nil : ids)
            if library.rootCrates.isEmpty {
                try? await runInitialSync()   // first launch after pairing, or cache was cleared
            } else {
                await runDeltaSync()          // background freshness on every launch
            }
        } else {
            enterDemoMode()
            await player.restoreQueue(mode: .demo)
        }
    }

    func setConnection(_ conn: CratesConnection) async {
        connection = conn
        isDemo = false
        await client.update(connection: conn)
        AppModel.saveConnection(conn)
        wire()
        library.refreshRoot()
    }

    // MARK: - Real onboarding: pair → bulk backup sync → import → browse

    /// Drive the full connect flow. Blocks on desktop approval, then downloads and imports the
    /// library backup (the same mechanism the official app uses). Progress is published on
    /// `onboarding` for the UI.
    func pairAndSync(host: String, port: Int) async {
        onboarding = .waitingForApproval
        do {
            let conn = try await PairingService().requestPairing(host: host, port: port)
            connection = conn
            isDemo = false
            await client.update(connection: conn)
            AppModel.saveConnection(conn)
            wire()
            player.persistenceMode = .library // freshly paired sessions persist their queue
            try await runInitialSync()
            onboarding = .done
        } catch {
            onboarding = .failed((error as? CratesAPIError)?.errorDescription ?? error.localizedDescription)
        }
    }

    /// Download + import the full library backup into the store. Single-flight: a concurrent call
    /// is a no-op (the in-flight sync is authoritative). `quiet` suppresses onboarding UI when
    /// the full sync is a background reseed (migration / invalid cursor), not user onboarding.
    func runInitialSync(quiet: Bool = false) async throws {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }

        if !quiet { onboarding = .syncing("Downloading library…", 0.05) }
        let sync = SyncClient(connection: connection)
        let zipURL = try await sync.downloadBackup(includeImages: false, sinceCursor: nil)

        if !quiet { onboarding = .syncing("Importing…", 0.5) }
        let result = try await Task.detached(priority: .userInitiated) {
            try BackupImporter.importBackup(zipURL: zipURL, mode: .full, cachedTunes: [:], cachedAudio: [:])
        }.value
        try? FileManager.default.removeItem(at: zipURL)

        library.loadSnapshot(result.snapshot)
        persistSyncArtifacts(result)
        UserDefaults.standard.set(Date(), forKey: AppModel.lastSyncKey)
        player.pruneDeletedTunes(valid: Set(result.snapshot.allTunes.map(\.id)))
        downloads.reconcileAll(tunesByCrate: result.snapshot.tunesByCrate)
        if !quiet { onboarding = .syncing("Done — \(result.snapshot.tuneCount) tunes", 1.0) }
    }

    /// Incremental sync: fetch the delta since the stored cursor, merge into the raw caches,
    /// rebuild the snapshot. Background-only — never touches onboarding UI; failures leave the
    /// cached library on screen. Falls back to a quiet full sync when there is no cursor/raw
    /// cache yet (pre-delta installs) or the server rejects the cursor (HTTP 400).
    func runDeltaSync(force: Bool = false) async {
        guard isPaired, !isDemo, !isSyncing else { return }
        if !force, let last = lastDeltaAttempt, Date().timeIntervalSince(last) < 90 { return }

        let cursor = UserDefaults.standard.string(forKey: AppModel.cursorKey)
        let cachedTunes = await DiskCache.shared.load("raw_tunes", as: [Int64: Backup.TuneRow].self)
        let cachedAudio = await DiskCache.shared.load("raw_audio", as: [Int64: Backup.AudioFileRow].self)
        guard let cursor, let cachedTunes, let cachedAudio else {
            try? await runInitialSync(quiet: true) // seed cursor + raw caches
            lastDeltaAttempt = Date()
            return
        }

        guard !isSyncing else { return } // re-check: the cache loads above suspended
        isSyncing = true
        defer { isSyncing = false }
        lastDeltaAttempt = Date()

        do {
            let zipURL = try await SyncClient(connection: connection).downloadBackup(sinceCursor: cursor)
            let result = try await Task.detached(priority: .utility) {
                try BackupImporter.importBackup(zipURL: zipURL, mode: .delta,
                                                cachedTunes: cachedTunes, cachedAudio: cachedAudio)
            }.value
            try? FileManager.default.removeItem(at: zipURL)

            library.loadSnapshot(result.snapshot)
            persistSyncArtifacts(result, previousCursor: cursor)
            UserDefaults.standard.set(Date(), forKey: AppModel.lastSyncKey)
            player.pruneDeletedTunes(valid: Set(result.snapshot.allTunes.map(\.id)))
            downloads.reconcileAll(tunesByCrate: result.snapshot.tunesByCrate)
            if !result.changedCoverIDs.isEmpty {
                let changed = result.changedCoverIDs
                Task.detached { await ArtworkStore.shared.invalidate(coverIDs: changed) }
            }
        } catch {
            if case CratesAPIError.http(400) = error {
                // Server rejected the cursor — drop it; the next attempt reseeds via full sync.
                UserDefaults.standard.removeObject(forKey: AppModel.cursorKey)
            }
            // Otherwise silent: delta is background freshness, the cached library stays up.
        }
    }

    /// Persist the raw caches, then the cursor — in that order. A failure between the two
    /// leaves the old cursor, and the next delta simply re-fetches idempotently (upserts by PK,
    /// inclusive >= filter re-delivers the boundary row anyway).
    private func persistSyncArtifacts(_ result: BackupImporter.MergeResult, previousCursor: String? = nil) {
        let raws = (tunes: result.rawTunes, audio: result.rawAudio)
        // Monotonic: an empty delta has no stamps — keep the old cursor.
        let cursor = [previousCursor, result.newCursor].compactMap { $0 }.max()
        Task.detached {
            await DiskCache.shared.save(raws.tunes, key: "raw_tunes")
            await DiskCache.shared.save(raws.audio, key: "raw_audio")
            if let cursor {
                UserDefaults.standard.set(cursor, forKey: AppModel.cursorKey)
            }
        }
    }

    func dismissOnboarding() { onboarding = .idle }

    /// Trickle the full cover corpus (~112MB measured) into the art cache — makes the whole
    /// library render offline. Cache-first philosophy: the cache IS the app.
    func warmAllArtwork() {
        let ids = Array(Set(library.allTunes.compactMap(\.coverID)))
        ArtworkStore.shared.prefetch(coverIDs: ids, variant: .row)
    }

    func signOut() {
        player.stop()
        player.eraseQueuePersistence() // a re-pair to a different server could collide on tune IDs
        connection = CratesConnection(host: "", port: CratesConnection.defaultPort, token: "")
        UserDefaults.standard.removeObject(forKey: AppModel.connKey)
        UserDefaults.standard.removeObject(forKey: AppModel.cursorKey) // next pairing starts with a full sync
        Task { await ArtworkStore.shared.clear() } // the previous server's art goes with its token
        Task { await client.update(connection: connection) }
        wire() // player/downloads must drop the stale host + bearer token immediately
    }

    /// Populate the stores with representative sample data so the UI is explorable offline.
    func enterDemoMode() {
        isDemo = true
        library.loadDemoData(SampleData.crates, tunesByCrate: SampleData.tunesByCrate)
        pins.configure(demo: true)
        player.persistenceMode = .demo // demo queues stay in the demo world
    }

    // MARK: - Persistence (token → Keychain in a real build)

    private static func loadConnection() -> CratesConnection? {
        guard let data = UserDefaults.standard.data(forKey: connKey) else { return nil }
        return try? JSONDecoder().decode(CratesConnection.self, from: data)
    }
    private static func saveConnection(_ conn: CratesConnection) {
        if let data = try? JSONEncoder().encode(conn) { UserDefaults.standard.set(data, forKey: connKey) }
    }
}
