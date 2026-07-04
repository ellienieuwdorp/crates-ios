import Testing
import Foundation
@testable import CratesIOS

/// Download engine safety (dogfood round 4, I2): the sweep's fail-safety, the manifest's
/// verification helpers, and the response-sniffing that keeps error bodies from becoming
/// "playable" files. Uses a no-op transport so nothing touches the network.
@MainActor
struct DownloadEngineTests {
    final class NoopTransport: DownloadTransport, @unchecked Sendable {
        let events: AsyncStream<DownloadEvent>
        private let continuation: AsyncStream<DownloadEvent>.Continuation
        var started: [Int64] = []
        var cancelled: [Int64] = []
        init() { (events, continuation) = AsyncStream.makeStream(of: DownloadEvent.self) }
        func start(tuneID: Int64, url: URL, authHeader: [String: String]) { started.append(tuneID) }
        func cancel(tuneID: Int64) { cancelled.append(tuneID) }
    }

    private func tune(_ id: Int64, daysAgo: Int = 1, hasAudio: Bool = true) -> Tune {
        Tune(id: id, title: "t\(id)", artist: "a",
             dateAdded: Date(timeIntervalSinceNow: -Double(daysAgo) * 86_400),
             hasServerAudio: hasAudio)
    }

    private func makeManager(transport: NoopTransport = NoopTransport()) -> DownloadManager {
        let m = DownloadManager(transport: transport)
        m.attach(client: CratesClient(connection: CratesConnection(host: "127.0.0.1", port: 54735, token: "t")),
                 connection: CratesConnection(host: "127.0.0.1", port: 54735, token: "t"))
        return m
    }

    @Test func crossCrateUnionSparesSiblingKeeps() {
        let m = makeManager()
        m.setPolicy(.init(mode: .keepAll, keepCount: 0), for: 1, crateTunes: [tune(10), tune(11)])
        m.setPolicy(.init(mode: .keepAll, keepCount: 0), for: 2, crateTunes: [tune(11), tune(12)])
        // Crate 1's policy turns off; tune 11 must survive (crate 2 still wants it).
        m.setPolicy(.init(mode: .off, keepCount: 0), for: 1, crateTunes: [tune(10), tune(11)])
        #expect(m.keepSetByCrate[2]?.contains(11) == true)
        #expect(m.keepSetByCrate[1]?.isEmpty ?? true)
    }

    @Test func manuallyPinnedDownloadsSurviveEverySweep() {
        let m = makeManager()
        m.downloadTune(tune(99))
        #expect(m.pinnedTuneIDs.contains(99))
        m.setPolicy(.init(mode: .keepAll, keepCount: 0), for: 1, crateTunes: [tune(1)])
        m.sweep()
        #expect(m.pinnedTuneIDs.contains(99)) // pin untouched by policy churn
    }

    @Test func knownUnstreamableTunesFailImmediatelyWithoutNetwork() {
        let transport = NoopTransport()
        let m = makeManager(transport: transport)
        m.enqueueDownload(tune(5, hasAudio: false))
        #expect(m.activeDownloads[5] == .failed("No audio file on the server for this tune."))
        #expect(transport.started.isEmpty)
    }

    @Test func sweepCancelsActiveDownloadsNothingWants() {
        let transport = NoopTransport()
        let m = makeManager(transport: transport)
        m.setPolicy(.init(mode: .keepAll, keepCount: 0), for: 1, crateTunes: [tune(20)])
        #expect(transport.started.contains(20)) // policy enqueue started it
        // Policy off: the in-flight download is no longer wanted.
        m.setPolicy(.init(mode: .off, keepCount: 0), for: 1, crateTunes: [tune(20)])
        #expect(transport.cancelled.contains(20))
        #expect(m.activeDownloads[20] == nil)
    }

    @Test func dispositionExtensionParsing() {
        #expect(DownloadManager.fileExtension(fromDisposition: #"attachment; filename="Inter.m4a""#) == "m4a")
        #expect(DownloadManager.fileExtension(fromDisposition: "attachment; filename=track.mp3") == "mp3")
        #expect(DownloadManager.fileExtension(fromDisposition: #"attachment; filename="weird name.FLAC"; size=9"#) == "flac")
        #expect(DownloadManager.fileExtension(fromDisposition: "attachment") == nil)
        #expect(DownloadManager.fileExtension(fromDisposition: nil) == nil)
    }

    /// LIVE end-to-end (self-gating): runs only when the test host app is paired (its
    /// UserDefaults hold a configured connection) and a raw audio cache exists — i.e. on the
    /// dev simulator against the local server. Everywhere else it exits silently.
    @Test func liveDownloadInstallsVerifiedAudio() async throws {
        guard let data = UserDefaults.standard.data(forKey: "crates.connection"),
              let conn = try? JSONDecoder().decode(CratesConnection.self, from: data),
              conn.isConfigured,
              let audio = await DiskCache.shared.load("raw_audio", as: [Int64: Backup.AudioFileRow].self),
              let candidate = audio.values.first(where: { ($0.Codec?.isEmpty == false) && $0.TuneID != nil })?.TuneID
        else { return }

        let m = DownloadManager() // real ForegroundTransport
        m.attach(client: CratesClient(connection: conn), connection: conn)
        defer { m.removeDownload(candidate) }

        m.downloadTune(Tune(id: candidate, title: "live", artist: "", hasServerAudio: true))
        for _ in 0..<120 { // conversion ~0.5s per source-minute, then LAN transfer: allow 60s
            if m.isDownloaded(candidate) { break }
            try await Task.sleep(for: .milliseconds(500))
        }
        #expect(m.isDownloaded(candidate), "download never completed: \(String(describing: m.activeDownloads[candidate]))")
        let url = m.localFileURL(for: candidate)
        #expect(url != nil)
        if let url {
            let size = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0) ?? 0
            #expect(size > 100_000, "installed file suspiciously small (\(size) bytes)")
            #expect(url.pathExtension != "audio") // real extension from Content-Disposition
        }
    }

    @Test func sniffRejectsErrorBodies() throws {
        let dir = FileManager.default.temporaryDirectory
        let json = dir.appendingPathComponent("err-\(UUID().uuidString).tmp")
        try #"{"message": "No audioFiles found"}"#.write(to: json, atomically: true, encoding: .utf8)
        #expect(DownloadManager.sniffRejection(fileURL: json, contentType: "application/octet-stream") != nil)

        let html = dir.appendingPathComponent("err2-\(UUID().uuidString).tmp")
        try "<html><body>Jetty error</body></html>".write(to: html, atomically: true, encoding: .utf8)
        #expect(DownloadManager.sniffRejection(fileURL: html, contentType: nil) != nil)

        let audio = dir.appendingPathComponent("ok-\(UUID().uuidString).tmp")
        try Data([0xFF, 0xFB, 0x90, 0x00]).write(to: audio) // MP3 frame sync
        #expect(DownloadManager.sniffRejection(fileURL: audio, contentType: "application/octet-stream") == nil)
        #expect(DownloadManager.sniffRejection(fileURL: audio, contentType: "application/json") != nil)
    }
}
