import XCTest
import AVFoundation
@testable import CratesIOS

/// FLAC playability spike (TODO §2 codec matrix / §5 player decision): the server streams raw
/// FLAC over range-capable progressive HTTP (verified live —
/// docs/research/reports/server-probes-2026-07-10.md), so the open question is purely
/// client-side: does plain AVPlayer decode a progressive raw-FLAC stream, or do we need an
/// AudioStreaming-style engine? This test answers it against the real server.
///
/// Opt-in like the other live tests (CRATES_LIVE=1; pass with TEST_RUNNER_CRATES_LIVE=1 through
/// xcodebuild). Token comes from CRATES_TOKEN or, failing that, the host app's persisted
/// pairing. Skips gracefully when no server answers. Read-only: /stream never mutates.
final class LiveFLACStreamTest: XCTestCase {
    private static let flacTuneID = 10 // 99MB raw FLAC, audio/flac (probe report Q2)

    @MainActor
    func testAVPlayerPlaysRawProgressiveFLAC() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CRATES_LIVE"] == "1",
                          "Set CRATES_LIVE=1 to run against the live server")
        let env = ProcessInfo.processInfo.environment
        let host = env["CRATES_HOST"] ?? "localhost"
        var token = env["CRATES_TOKEN"] ?? ""
        if token.isEmpty,
           let data = UserDefaults.standard.data(forKey: "crates.connection"),
           let conn = try? JSONDecoder().decode(CratesConnection.self, from: data) {
            token = conn.token
        }
        try XCTSkipIf(token.isEmpty, "No token: set CRATES_TOKEN or pair the host app first")

        // Reachability guard: a 3s ping decides skip-vs-run so an offline machine never fails.
        let base = "http://\(host):\(CratesConnection.defaultPort)/resources"
        var ping = URLRequest(url: URL(string: "\(base)/backend/ping")!, timeoutInterval: 3)
        ping.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (_, resp) = try await URLSession.shared.data(for: ping)
            try XCTSkipUnless((resp as? HTTPURLResponse)?.statusCode == 200,
                              "Server answered but refused the token — skipping")
        } catch {
            throw XCTSkip("No Crates server reachable at \(host) — skipping FLAC spike")
        }

        // Exactly the app's streaming path: AVURLAsset + Bearer header option.
        let url = URL(string: "\(base)/stream/\(Self.flacTuneID)")!
        let asset = AVURLAsset(url: url, options: [
            "AVURLAssetHTTPHeaderFieldsKey": ["Authorization": "Bearer \(token)"],
        ])
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        player.play()

        // Verdict needs more than .readyToPlay — require actual decoded playback progress.
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if item.status == .failed {
                XCTFail("FLAC AVPlayer verdict: NOT PLAYABLE — \(String(describing: item.error))")
                return
            }
            if item.status == .readyToPlay, item.currentTime().seconds > 2 {
                break // ready AND >2s of real audio decoded
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        player.pause()
        XCTAssertEqual(item.status, .readyToPlay, "FLAC item never became ready within 30s")
        XCTAssertGreaterThan(item.currentTime().seconds, 2,
                             "FLAC item is ready but playback never progressed")
        print("FLAC-VERDICT: PLAYABLE — status readyToPlay, progressed to " +
              "\(item.currentTime().seconds)s, duration \(item.duration.seconds)s")
    }
}
