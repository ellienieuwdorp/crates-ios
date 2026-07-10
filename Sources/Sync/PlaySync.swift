import Foundation

/// Play-count sync back to the server (TODO §5): the phone's listens must show up in the
/// desktop library, or mobile is a "second screen that lies".
///
/// Endpoint semantics (verified live — docs/research/reports/server-probes-2026-07-10.md):
/// `POST /tunes/update.tunes.attributes` SETS absolute values, it never increments. The client
/// must send `current + 1`, which makes a read-modify-write race with the desktop possible
/// (both bump from the same base → one play lost). Accepted POC limitation. `value: null` is
/// silently IGNORED by the server (an empty string clears) — payloads must never encode null.

/// One play awaiting sync. `playedCount` is the ABSOLUTE value the server will be set to.
struct PendingPlayReport: Codable, Sendable, Equatable {
    var tuneID: Int64
    /// The server bean's objectID. Sent as tuneObjectID/objectID when known (the desktop sends
    /// all three ids); a bare tuneID is also honored (verified live), so nil just omits them.
    var objectID: String?
    var playedCount: Int
    /// Server wall-clock format "yyyy-MM-dd HH:mm:ss" — see ServerDate.
    var lastListenDate: String
}

/// Pure pending-report bookkeeping, persisted as-is ("pending_plays_v1" — same pattern as
/// PersistedQueue). One entry per tune: multiple plays coalesce into the latest absolute count,
/// so a flush after three offline listens sends one write, not three.
struct PendingPlayStore: Codable, Sendable, Equatable {
    var v: Int = 1
    private(set) var reports: [PendingPlayReport] = []

    var isEmpty: Bool { reports.isEmpty }

    /// Count a play. The new absolute count is (freshest known count) + 1, where an unsent
    /// pending report is at least as fresh as the library cache — plays already counted but
    /// not yet flushed must keep stacking, never restart from a stale base.
    @discardableResult
    mutating func recordPlay(tuneID: Int64, objectID: String?,
                             localPlayedCount: Int?, at date: Date = Date()) -> Int {
        let existing = reports.first { $0.tuneID == tuneID }
        let newCount = max(localPlayedCount ?? 0, existing?.playedCount ?? 0) + 1
        reports.removeAll { $0.tuneID == tuneID }
        reports.append(PendingPlayReport(tuneID: tuneID,
                                         objectID: objectID ?? existing?.objectID,
                                         playedCount: newCount,
                                         lastListenDate: ServerDate.string(from: date)))
        return newCount
    }

    /// A report was accepted by the server: drop it — unless another play for the same tune
    /// landed while the request was in flight (its higher count still has to be sent).
    mutating func markSent(_ sent: PendingPlayReport) {
        reports.removeAll { $0.tuneID == sent.tuneID && $0.playedCount <= sent.playedCount }
    }
}

extension PendingPlayReport {
    /// The exact wire shape the endpoint expects:
    /// `{tunes:[{tuneID, tuneObjectID, objectID}], attributes:[{attribute, value}]}`.
    /// Synthesized Encodable omits nil optionals entirely (encodeIfPresent) — load-bearing,
    /// because the server silently ignores `value: null` instead of clearing.
    private struct Payload: Encodable {
        struct TuneRef: Encodable {
            var tuneID: Int64
            var tuneObjectID: String?
            var objectID: String?
        }
        struct Attribute: Encodable {
            var attribute: String
            var value: Value
            enum Value: Encodable {
                case int(Int)
                case string(String)
                func encode(to encoder: Encoder) throws {
                    var c = encoder.singleValueContainer()
                    switch self {
                    case .int(let i): try c.encode(i)
                    case .string(let s): try c.encode(s)
                    }
                }
            }
        }
        var tunes: [TuneRef]
        var attributes: [Attribute]
    }

    /// JSON body for `POST /tunes/update.tunes.attributes`.
    func requestBody() throws -> Data {
        let payload = Payload(
            tunes: [.init(tuneID: tuneID, tuneObjectID: objectID, objectID: objectID)],
            attributes: [
                .init(attribute: "playedCount", value: .int(playedCount)),
                .init(attribute: "lastListenDate", value: .string(lastListenDate)),
            ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys] // deterministic, diffable in tests/logs
        return try encoder.encode(payload)
    }
}

/// The server's wall-clock date format ("2026-07-10 01:45:00", stored/echoed with ".000").
/// Server-local wall time by convention; the phone's current timezone is the best available
/// stand-in (personal setup: same household/tailnet, same clock).
enum ServerDate {
    static func string(from date: Date) -> String {
        makeFormatter("yyyy-MM-dd HH:mm:ss").string(from: date)
    }

    static func parse(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        return makeFormatter("yyyy-MM-dd HH:mm:ss.SSS").date(from: raw)
            ?? makeFormatter("yyyy-MM-dd HH:mm:ss").date(from: raw)
    }

    // Built per call: DateFormatter isn't Sendable, and plays are seconds-apart events.
    private static func makeFormatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f
    }
}

/// Offline-first flush engine for pending play reports. Reports persist across launches and
/// flush in the background when the server is reachable: on record, on foreground, and after
/// sync. Failures back off and retry — reports are never lost and playback never waits.
@MainActor
final class PlayReporter {
    private var store = PendingPlayStore()
    private var client: CratesClient?
    private var flushTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var consecutiveFailures = 0
    /// nonisolated: read from detached persistence tasks (precedent: AppModel.cursorKey).
    private nonisolated static let cacheKey = "pending_plays_v1"

    func attach(client: CratesClient) { self.client = client }

    func hydrate() async {
        guard store.isEmpty,
              let cached: PendingPlayStore = await DiskCache.shared.load(Self.cacheKey, as: PendingPlayStore.self)
        else { return }
        store = cached
    }

    /// Count a completed play and kick a background flush. Returns the new absolute count so
    /// the caller can mirror it into the library cache.
    @discardableResult
    func recordPlay(tuneID: Int64, objectID: String?, localPlayedCount: Int?) -> Int {
        let newCount = store.recordPlay(tuneID: tuneID, objectID: objectID,
                                        localPlayedCount: localPlayedCount)
        persist()
        flushSoon()
        return newCount
    }

    /// Kick a background flush if there is anything to send. Single-flight; an explicit kick
    /// (foreground, post-sync) also cancels any pending backoff — reachability likely changed.
    func flushSoon() {
        retryTask?.cancel(); retryTask = nil
        guard flushTask == nil, !store.isEmpty, client != nil else { return }
        flushTask = Task { [weak self] in
            await self?.flushAll()
            self?.flushTask = nil
        }
    }

    /// Signed out: pending reports belong to the old server's tune IDs — drop them.
    func erase() {
        flushTask?.cancel(); flushTask = nil
        retryTask?.cancel(); retryTask = nil
        store = PendingPlayStore()
        consecutiveFailures = 0
        Task.detached { await DiskCache.shared.remove(Self.cacheKey) }
    }

    private func flushAll() async {
        guard let client else { return }
        let api = LibraryAPI(client: client)
        // `first` re-reads live state each lap, so plays recorded mid-flush are picked up too.
        while let report = store.reports.first {
            do {
                try await api.reportPlay(report)
                consecutiveFailures = 0
                store.markSent(report)
                persist()
            } catch {
                // Server unreachable (or refusing): keep everything, back off, retry later.
                consecutiveFailures += 1
                scheduleRetry()
                return
            }
        }
    }

    private func scheduleRetry() {
        let delay = min(300.0, 15 * pow(2, Double(consecutiveFailures - 1)))
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.flushSoon()
        }
    }

    private func persist() {
        let snapshot = store
        Task.detached { await DiskCache.shared.save(snapshot, key: Self.cacheKey) }
    }

    /// Test hook: current pending reports.
    var pendingReports_forTesting: [PendingPlayReport] { store.reports }
}
