import Foundation
import Observation

/// Per-crate offline download policy (Idea #2b). A crate can be set to keep all downloaded, or to
/// keep only the last N tracks *added* to it, evicting older files as new ones arrive.
struct DownloadPolicy: Codable, Sendable, Equatable {
    enum Mode: String, Codable, Sendable { case off, keepLastN, keepAll }
    var mode: Mode = .off
    var keepCount: Int = 100   // configurable: 100, 200, …
}

/// Per-tune download lifecycle for the UI. Per-file progress on LAN is nearly binary (seconds
/// of `preparing` while the server converts, then an instant transfer), so states carry more
/// signal than fractions.
enum DownloadState: Sendable, Equatable {
    case queued
    case preparing          // request sent; server is converting (~0.5s per source-minute)
    case downloading(Double)
    case failed(String)
}

/// The offline downloads engine (dogfood round 4, I2 — design live-probed against the server):
/// `/sync/download/{tuneID}` transcodes to the user's profile server-side (result cached there),
/// ignores Range (retry = restart; cheap on LAN), and answers 500+JSON for tunes with no audio —
/// a completed URLSession task is therefore NOT a success until status + content sniffing pass,
/// or we'd install `{"message": "No audioFiles…"}` as a playable file.
@MainActor
@Observable
final class DownloadManager {
    private(set) var policies: [Int64: DownloadPolicy] = [:]
    private(set) var downloadedTuneIDs: Set<Int64> = []
    private(set) var activeDownloads: [Int64: DownloadState] = [:]
    /// Manually downloaded tunes — immune to every policy sweep.
    private(set) var pinnedTuneIDs: Set<Int64> = []

    /// Injected so the sweep can spare the playing track without a Player dependency cycle.
    @ObservationIgnored var nowPlayingTuneID: (() -> Int64?)?

    private let root: URL
    private var client: CratesClient?
    private var connection: CratesConnection?
    @ObservationIgnored private var transport: any DownloadTransport
    @ObservationIgnored private var eventPump: Task<Void, Never>?

    /// tuneID → {ext, codec, bitrate, bytes, completedAt} — the bookkeeping that makes
    /// completed files verifiable across launches.
    private(set) var manifest: [Int64: ManifestEntry] = [:]
    struct ManifestEntry: Codable, Sendable, Equatable {
        var ext: String
        var codec: String?
        var bitrate: String?
        var bytes: Int
        var completedAt: Date
    }

    private var pending: [Tune] = []
    private var running: Set<Int64> = []
    private var retryCounts: [Int64: Int] = [:]
    private static let maxConcurrent = 3
    private static let maxRetries = 3

    /// Fail-safe: eviction is forbidden until the keep-set store loaded cleanly — a corrupt
    /// file must degrade to download-only, never to "evict everything".
    private var keepSetsLoaded = false

    init(transport: (any DownloadTransport)? = nil) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        root = base.appendingPathComponent("CratesAudio", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.transport = transport ?? ForegroundTransport()
        loadPolicies()
        loadManifest()
        rescanDisk()
        pumpEvents()
    }

    func attach(client: CratesClient, connection: CratesConnection) {
        self.client = client
        self.connection = connection
    }

    // MARK: - Lookup (used by the player: local file always wins)

    func localFileURL(for tuneID: Int64) -> URL? {
        if let entry = manifest[tuneID] {
            let url = root.appendingPathComponent("\(tuneID).\(entry.ext)")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        let legacy = root.appendingPathComponent("\(tuneID).audio")
        return FileManager.default.fileExists(atPath: legacy.path) ? legacy : nil
    }

    func isDownloaded(_ tuneID: Int64) -> Bool { downloadedTuneIDs.contains(tuneID) }

    var storageBytesUsed: Int { manifest.values.reduce(0) { $0 + $1.bytes } }

    // MARK: - Manual downloads (single tune, pinned = policy-sweep-immune)

    func downloadTune(_ tune: Tune) {
        pinnedTuneIDs.insert(tune.id)
        savePins()
        enqueueDownload(tune)
    }

    func removeDownload(_ tuneID: Int64) {
        pinnedTuneIDs.remove(tuneID)
        savePins()
        transport.cancel(tuneID: tuneID)
        running.remove(tuneID)
        pending.removeAll { $0.id == tuneID }
        evict(tuneID)
    }

    // MARK: - Policy

    func policy(for crateID: Int64) -> DownloadPolicy { policies[crateID] ?? DownloadPolicy() }

    func setPolicy(_ policy: DownloadPolicy, for crateID: Int64, crateTunes: [Tune]) {
        policies[crateID] = policy
        savePolicies()
        reconcile(crateID: crateID, tunes: crateTunes)
    }

    /// Tune IDs each crate's policy currently wants kept, persisted so eviction can respect
    /// crates whose tune lists aren't loaded right now.
    private(set) var keepSetByCrate: [Int64: Set<Int64>] = [:]

    /// Given a crate's current tunes (assumed ordered with newest-added last, matching the
    /// server's ordered list), compute which tunes should be kept downloaded under the policy and
    /// enqueue/evict accordingly. This is the retention brain (Idea #2b) — pure and testable.
    func reconcile(crateID: Int64, tunes: [Tune]) {
        let target = Self.tunesToKeep(tunes: tunes, policy: policy(for: crateID))
        keepSetByCrate[crateID] = Set(target.map(\.id))
        keepSetsLoaded = true // freshly computed state is trustworthy by definition
        saveKeepSets()
        sweep()
        for tune in target where !isDownloaded(tune.id) {
            enqueueDownload(tune)
        }
    }

    /// A sync landed: recompute every policy'd crate's keep-set from fresh tune lists, then
    /// sweep once — sibling keep-sets can never go stale against each other.
    func reconcileAll(tunesByCrate: [Int64: [Tune]]) {
        for (crateID, policy) in policies where policy.mode != .off {
            guard let tunes = tunesByCrate[crateID] else { continue }
            keepSetByCrate[crateID] = Set(Self.tunesToKeep(tunes: tunes, policy: policy).map(\.id))
        }
        keepSetsLoaded = true
        saveKeepSets()
        sweep()
        for (crateID, policy) in policies where policy.mode != .off {
            guard let tunes = tunesByCrate[crateID] else { continue }
            for tune in Self.tunesToKeep(tunes: tunes, policy: policy) where !isDownloaded(tune.id) {
                enqueueDownload(tune)
            }
        }
    }

    /// The core retention selection: newest-N-added when `keepLastN`, everything when `keepAll`.
    /// Server returns crate tunes in add-order (oldest→newest), so "last N added" = suffix of N.
    /// Dates only override server order when every tune has one — a nil date in a comparator
    /// breaks strict weak ordering, and partial date info shouldn't scramble a valid order.
    nonisolated static func tunesToKeep(tunes: [Tune], policy: DownloadPolicy) -> [Tune] {
        switch policy.mode {
        case .off: return []
        case .keepAll: return tunes
        case .keepLastN:
            let dated = tunes.compactMap { t in t.dateAdded.map { (t, $0) } }
            let ordered = dated.count == tunes.count
                ? dated.sorted { $0.1 < $1.1 }.map(\.0)
                : tunes
            return Array(ordered.suffix(max(0, policy.keepCount)))
        }
    }

    /// Evict downloads nothing wants. Fail-safe by construction: never runs on unloaded
    /// keep-sets, always spares pins and the playing track, and cancels in-flight work that
    /// fell out of the union.
    func sweep() {
        guard keepSetsLoaded else { return } // corrupt store must never mean "evict everything"
        var wanted = pinnedTuneIDs
        for keeps in keepSetByCrate.values { wanted.formUnion(keeps) }
        let playing = nowPlayingTuneID?()
        for id in downloadedTuneIDs.subtracting(wanted) where id != playing {
            evict(id)
        }
        for id in Set(activeDownloads.keys).subtracting(wanted) where id != playing {
            transport.cancel(tuneID: id)
            running.remove(id)
            pending.removeAll { $0.id == id }
            activeDownloads[id] = nil
        }
    }

    // MARK: - Transfer engine

    func enqueueDownload(_ tune: Tune) {
        guard activeDownloads[tune.id] == nil || isFailed(tune.id), !isDownloaded(tune.id) else { return }
        guard tune.hasServerAudio != false else { // known codec-null: the server would 500
            activeDownloads[tune.id] = .failed("No audio file on the server for this tune.")
            return
        }
        retryCounts[tune.id] = 0
        activeDownloads[tune.id] = .queued
        pending.removeAll { $0.id == tune.id }
        pending.append(tune)
        pump()
    }

    private func isFailed(_ id: Int64) -> Bool {
        if case .failed = activeDownloads[id] { return true }
        return false
    }

    private func pump() {
        while running.count < Self.maxConcurrent, !pending.isEmpty {
            let tune = pending.removeFirst()
            guard let connection, connection.isConfigured,
                  let url = connection.url(path: "sync/download/\(tune.id)") else {
                activeDownloads[tune.id] = .failed("Not connected to a server.")
                continue
            }
            running.insert(tune.id)
            activeDownloads[tune.id] = .preparing
            transport.start(tuneID: tune.id, url: url, authHeader: connection.authHeader)
        }
    }

    private func pumpEvents() {
        let stream = transport.events
        eventPump = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                self.handle(event)
            }
        }
    }

    private func handle(_ event: DownloadEvent) {
        switch event {
        case .preparing(let id):
            if running.contains(id) { activeDownloads[id] = .preparing }
        case .progress(let id, let fraction):
            if running.contains(id) { activeDownloads[id] = .downloading(fraction) }
        case .finished(let id, let staged, let status, let contentType, let disposition):
            running.remove(id)
            install(tuneID: id, staged: staged, status: status,
                    contentType: contentType, disposition: disposition)
            pump()
        case .failed(let id, let message, let transient):
            running.remove(id)
            fail(tuneID: id, message: message, transient: transient)
            pump()
        }
    }

    /// Verify then install: HTTP 200 + non-JSON/HTML body (a 500 error body "completes" a
    /// download task successfully — probe-verified).
    private func install(tuneID: Int64, staged: URL, status: Int,
                         contentType: String?, disposition: String?) {
        defer { try? FileManager.default.removeItem(at: staged) }

        guard status == 200 else {
            let body = (try? String(contentsOf: staged, encoding: .utf8))?.prefix(200) ?? ""
            // 500 + JSON "No audioFiles" is permanent (feeds the unplayable flag's world);
            // anything else gets the transient path.
            let permanent = body.contains("No audioFiles")
            fail(tuneID: tuneID,
                 message: permanent ? "No audio file on the server for this tune." : "Server error (\(status)).",
                 transient: !permanent)
            return
        }
        if let sniff = Self.sniffRejection(fileURL: staged, contentType: contentType) {
            fail(tuneID: tuneID, message: sniff, transient: false)
            return
        }

        let ext = Self.fileExtension(fromDisposition: disposition) ?? "m4a"
        let dest = root.appendingPathComponent("\(tuneID).\(ext)")
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.moveItem(at: staged, to: dest)
        } catch {
            fail(tuneID: tuneID, message: "Couldn't save the file.", transient: true)
            return
        }
        let bytes = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int) ?? 0
        manifest[tuneID] = ManifestEntry(ext: ext, codec: nil, bitrate: nil,
                                         bytes: bytes ?? 0, completedAt: Date())
        saveManifest()
        downloadedTuneIDs.insert(tuneID)
        activeDownloads[tuneID] = nil
        retryCounts[tuneID] = nil
    }

    private func fail(tuneID: Int64, message: String, transient: Bool) {
        let attempts = (retryCounts[tuneID] ?? 0) + 1
        retryCounts[tuneID] = attempts
        guard transient, attempts <= Self.maxRetries else {
            activeDownloads[tuneID] = .failed(message)
            return
        }
        activeDownloads[tuneID] = .queued
        // Jittered backoff 1s/4s/16s, then back into the queue.
        let delay = pow(4.0, Double(attempts - 1)) * .random(in: 0.8...1.2)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, let connection = self.connection, connection.isConfigured,
                  let url = connection.url(path: "sync/download/\(tuneID)"),
                  self.activeDownloads[tuneID] == .queued, !self.running.contains(tuneID) else { return }
            self.running.insert(tuneID)
            self.activeDownloads[tuneID] = .preparing
            self.transport.start(tuneID: tuneID, url: url, authHeader: connection.authHeader)
        }
    }

    /// Content sniffing: an error body must never become a "downloaded track".
    nonisolated static func sniffRejection(fileURL: URL, contentType: String?) -> String? {
        if let type = contentType?.lowercased(),
           type.contains("json") || type.contains("html") || type.contains("text/") {
            return "Server sent an error instead of audio."
        }
        guard let handle = try? FileHandle(forReadingFrom: fileURL),
              let head = try? handle.read(upToCount: 1) else { return "Empty download." }
        try? handle.close()
        if head.isEmpty { return "Empty download." }
        if head[0] == UInt8(ascii: "{") || head[0] == UInt8(ascii: "<") {
            return "Server sent an error instead of audio."
        }
        return nil
    }

    /// Parse ONLY the extension from Content-Disposition — the filename is the desktop's source
    /// file name, not the tune title. Handles quoted and bare forms.
    nonisolated static func fileExtension(fromDisposition disposition: String?) -> String? {
        guard let disposition,
              let range = disposition.range(of: "filename=", options: .caseInsensitive) else { return nil }
        var name = String(disposition[range.upperBound...])
        if let semicolon = name.firstIndex(of: ";") { name = String(name[..<semicolon]) }
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")).trimmingCharacters(in: .whitespaces)
        let ext = (name as NSString).pathExtension.lowercased()
        guard !ext.isEmpty, ext.count <= 5, ext.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
        return ext
    }

    func evict(_ tuneID: Int64) {
        if let entry = manifest[tuneID] {
            try? FileManager.default.removeItem(at: root.appendingPathComponent("\(tuneID).\(entry.ext)"))
        }
        try? FileManager.default.removeItem(at: root.appendingPathComponent("\(tuneID).audio"))
        manifest[tuneID] = nil
        saveManifest()
        downloadedTuneIDs.remove(tuneID)
        activeDownloads[tuneID] = nil
    }

    /// Disk is truth: reconcile the manifest against what actually exists. Files without a
    /// manifest entry are adopted (legacy installs); entries without files are dropped.
    private func rescanDisk() {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        var found: Set<Int64> = []
        for name in files {
            let ext = (name as NSString).pathExtension.lowercased()
            guard let id = Int64((name as NSString).deletingPathExtension),
                  ["audio", "m4a", "mp3", "aac", "flac", "wav", "aiff", "aif", "ogg"].contains(ext) else { continue }
            found.insert(id)
            if manifest[id] == nil, ext != "audio" {
                let bytes = (try? FileManager.default.attributesOfItem(
                    atPath: root.appendingPathComponent(name).path)[.size] as? Int) ?? 0
                manifest[id] = ManifestEntry(ext: ext, codec: nil, bitrate: nil,
                                             bytes: bytes ?? 0, completedAt: Date())
            }
        }
        downloadedTuneIDs = found
        for id in manifest.keys where !found.contains(id) { manifest[id] = nil }
        saveManifest()
    }

    // MARK: - Persistence

    private var policiesFile: URL { root.appendingPathComponent("policies.json") }
    private var keepSetsFile: URL { root.appendingPathComponent("keepsets.json") }
    private var manifestFile: URL { root.appendingPathComponent("manifest.json") }
    private var pinsFile: URL { root.appendingPathComponent("pins.json") }

    private func savePolicies() {
        if let data = try? JSONEncoder().encode(policies) { try? data.write(to: policiesFile) }
    }
    private func saveKeepSets() {
        if let data = try? JSONEncoder().encode(keepSetByCrate) { try? data.write(to: keepSetsFile) }
    }
    private func saveManifest() {
        if let data = try? JSONEncoder().encode(manifest) { try? data.write(to: manifestFile) }
    }
    private func savePins() {
        if let data = try? JSONEncoder().encode(pinnedTuneIDs) { try? data.write(to: pinsFile) }
    }

    private func loadPolicies() {
        if let data = try? Data(contentsOf: policiesFile),
           let p = try? JSONDecoder().decode([Int64: DownloadPolicy].self, from: data) {
            policies = p
        }
        if FileManager.default.fileExists(atPath: keepSetsFile.path) {
            if let data = try? Data(contentsOf: keepSetsFile),
               let k = try? JSONDecoder().decode([Int64: Set<Int64>].self, from: data) {
                keepSetByCrate = k
                keepSetsLoaded = true
            }
            // else: file exists but won't decode → keepSetsLoaded stays false → no eviction.
        } else {
            keepSetsLoaded = true // first run: nothing to protect yet
        }
        if let data = try? Data(contentsOf: pinsFile),
           let pins = try? JSONDecoder().decode(Set<Int64>.self, from: data) {
            pinnedTuneIDs = pins
        }
    }

    private func loadManifest() {
        if let data = try? Data(contentsOf: manifestFile),
           let m = try? JSONDecoder().decode([Int64: ManifestEntry].self, from: data) {
            manifest = m
        }
    }
}
