import Foundation
import Observation

/// Per-crate offline download policy (Idea #2b). A crate can be set to keep all downloaded, or to
/// keep only the last N tracks *added* to it, evicting older files as new ones arrive.
struct DownloadPolicy: Codable, Sendable, Equatable {
    enum Mode: String, Codable, Sendable { case off, keepLastN, keepAll }
    var mode: Mode = .off
    var keepCount: Int = 100   // configurable: 100, 200, …
}

/// Manages local audio files for offline playback. The POC implements the file layout, the
/// local-file-preferred lookup, and the "keep last N added" eviction math; the actual bulk
/// URLSession background transfer is stubbed with a clear extension point so the UI and retention
/// logic can be built and tested first.
@MainActor
@Observable
final class DownloadManager {
    private(set) var policies: [Int64: DownloadPolicy] = [:]
    private(set) var downloadedTuneIDs: Set<Int64> = []
    private(set) var activeDownloads: [Int64: Double] = [:] // tuneID → progress 0...1

    private let root: URL
    private var client: CratesClient?

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        root = base.appendingPathComponent("CratesAudio", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        rescanDisk()
        loadPolicies()
    }

    func attach(client: CratesClient) { self.client = client }

    // MARK: - Lookup (used by the player: local file always wins)

    func localFileURL(for tuneID: Int64) -> URL? {
        let url = fileURL(for: tuneID)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func isDownloaded(_ tuneID: Int64) -> Bool { downloadedTuneIDs.contains(tuneID) }

    private func fileURL(for tuneID: Int64) -> URL {
        root.appendingPathComponent("\(tuneID).audio")
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
    /// Eviction only removes files no crate's keep-set claims.
    func reconcile(crateID: Int64, tunes: [Tune]) {
        let policy = policy(for: crateID)
        let target = Self.tunesToKeep(tunes: tunes, policy: policy)
        keepSetByCrate[crateID] = Set(target.map(\.id))
        saveKeepSets()

        let keptByAnyone = keepSetByCrate.values.reduce(into: Set<Int64>()) { $0.formUnion($1) }
        for id in downloadedTuneIDs where !keptByAnyone.contains(id) {
            evict(id)
        }
        for tune in target where !isDownloaded(tune.id) {
            enqueueDownload(tune)
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

    // MARK: - Transfer (extension point)

    func enqueueDownload(_ tune: Tune) {
        guard activeDownloads[tune.id] == nil, !isDownloaded(tune.id) else { return }
        activeDownloads[tune.id] = 0
        // POC stub: real implementation uses a URLSession background configuration with the
        // bearer header, writing to fileURL(for:), reporting progress, retrying on failure.
        // Kept as a no-op-with-state so retention logic and UI are exercisable without a server.
    }

    func evict(_ tuneID: Int64) {
        try? FileManager.default.removeItem(at: fileURL(for: tuneID))
        downloadedTuneIDs.remove(tuneID)
        activeDownloads[tuneID] = nil
    }

    private func rescanDisk() {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        downloadedTuneIDs = Set(files.compactMap { name in
            name.hasSuffix(".audio") ? Int64(name.replacingOccurrences(of: ".audio", with: "")) : nil
        })
    }

    // MARK: - Persistence

    private var policiesFile: URL { root.appendingPathComponent("policies.json") }
    private var keepSetsFile: URL { root.appendingPathComponent("keepsets.json") }
    private func savePolicies() {
        if let data = try? JSONEncoder().encode(policies) { try? data.write(to: policiesFile) }
    }
    private func saveKeepSets() {
        if let data = try? JSONEncoder().encode(keepSetByCrate) { try? data.write(to: keepSetsFile) }
    }
    private func loadPolicies() {
        if let data = try? Data(contentsOf: policiesFile),
           let p = try? JSONDecoder().decode([Int64: DownloadPolicy].self, from: data) {
            policies = p
        }
        if let data = try? Data(contentsOf: keepSetsFile),
           let k = try? JSONDecoder().decode([Int64: Set<Int64>].self, from: data) {
            keepSetByCrate = k
        }
    }
}
