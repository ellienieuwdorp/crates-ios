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
        downloads.attach(client: client)
        player.attach(connection: connection, downloads: downloads)
    }

    func bootstrap() async {
        // Hermetic demo mode for UI tests: ignore any persisted pairing and show sample data.
        if ProcessInfo.processInfo.arguments.contains("-uitestDemo") {
            connection = CratesConnection(host: "", port: CratesConnection.defaultPort, token: "")
            await client.update(connection: connection)
            wire()
            enterDemoMode()
            return
        }
        await library.hydrateFromDisk()
        if isPaired {
            // Paired ⇒ the library is backup-synced; disk cache is the source of truth.
            library.markSnapshotBacked()
            if library.rootCrates.isEmpty {
                try? await runInitialSync()   // first launch after pairing, or cache was cleared
            }
        } else {
            enterDemoMode()
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
            try await runInitialSync()
            onboarding = .done
        } catch {
            onboarding = .failed((error as? CratesAPIError)?.errorDescription ?? error.localizedDescription)
        }
    }

    /// Download + import the full library backup into the store. Single-flight: a concurrent call
    /// is a no-op (the in-flight sync is authoritative).
    func runInitialSync() async throws {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }

        onboarding = .syncing("Downloading library…", 0.05)
        let sync = SyncClient(connection: connection)
        let zipURL = try await sync.downloadBackup(includeImages: false, since: nil)

        onboarding = .syncing("Importing…", 0.5)
        let snapshot = try await Task.detached(priority: .userInitiated) {
            try BackupImporter.importBackup(zipURL: zipURL)
        }.value
        try? FileManager.default.removeItem(at: zipURL)

        library.loadSnapshot(snapshot)
        UserDefaults.standard.set(Date(), forKey: AppModel.lastSyncKey)
        onboarding = .syncing("Done — \(snapshot.tuneCount) tunes", 1.0)
    }

    func dismissOnboarding() { onboarding = .idle }

    func signOut() {
        player.stop()
        connection = CratesConnection(host: "", port: CratesConnection.defaultPort, token: "")
        UserDefaults.standard.removeObject(forKey: AppModel.connKey)
        Task { await client.update(connection: connection) }
        wire() // player/downloads must drop the stale host + bearer token immediately
    }

    /// Populate the stores with representative sample data so the UI is explorable offline.
    func enterDemoMode() {
        isDemo = true
        library.loadDemoData(SampleData.crates, tunesByCrate: SampleData.tunesByCrate)
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
