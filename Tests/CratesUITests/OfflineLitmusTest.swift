import XCTest

/// The philosophy's FIRST litmus test, executed for real: "Kill the Wi-Fi: does the app still
/// open, browse, and play what's downloaded?" Two phases against ONE app container:
///
///   Phase A — the REAL local server (the desktop app on this Mac): fresh install → full
///   backup sync → auto-download 3 tunes (`-uitestDownloadCount`, the deterministic test hook)
///   → the Downloaded surface lists them as installs verify.
///
///   Phase B — relaunch the SAME container with the injected connection pointing at an
///   unreachable TEST-NET host (192.0.2.1, guaranteed non-routable). Persisted caches survive,
///   the network doesn't. Asserts: Home renders from disk, Browse works, Downloaded lists the
///   same tunes, and tapping one PLAYS from the local file (mini player shows the track, the
///   play/pause state toggles).
///
/// Opt-in and secret-free like LiveScreenshotTests: runs only when the runner passes
/// TEST_RUNNER_CRATES_LIVE_TOKEN; the connection is injected via the UserDefaults argument
/// domain so no pairing approval is needed and nothing persists into the repo. Playback is
/// forced silent via `-uitestSilent` (the AVPlayer's own volume, never the system's) — a live
/// run must never blast audio from the host Mac.
///
/// For a clean Phase A, uninstall the app from the simulator first:
///   xcrun simctl uninstall booted me.nieuwdorp.crates
final class OfflineLitmusTest: XCTestCase {

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    private func connectionArgument(host: String, token: String) -> String {
        let json = #"{"host":"\#(host)","port":54735,"token":"\#(token)"}"#
        return "<data>\(Data(json.utf8).base64EncodedString())</data>"
    }

    @MainActor
    func testKillTheWiFi_downloadsSurviveAndPlayOffline() throws {
        guard let token = ProcessInfo.processInfo.environment["CRATES_LIVE_TOKEN"],
              !token.isEmpty else {
            throw XCTSkip("No CRATES_LIVE_TOKEN in the runner environment — live run is opt-in.")
        }

        // ── Phase A: real server on localhost — full sync, then 3 downloads install. ──
        let app = XCUIApplication()
        app.launchArguments = [
            "-crates.connection", connectionArgument(host: "localhost", token: token),
            "-uitestDownloadCount", "3",
            "-uitestSilent",
        ]
        app.launch()

        // First launch syncs the full backup; the shelf title appearing means import finished.
        XCTAssertTrue(app.staticTexts["Your Library"].waitForExistence(timeout: 90),
                      "paired Home did not appear (sync failed?)")
        _ = app.staticTexts["Recently Added"].waitForExistence(timeout: 60)
        shot("A1-home-synced-live")

        // The Downloaded surface fills as the server converts + transfers each tune.
        app.buttons["Browse"].firstMatch.tap()
        let downloadedEntry = app.staticTexts["Downloaded"].firstMatch
        XCTAssertTrue(downloadedEntry.waitForExistence(timeout: 10),
                      "Browse has no Downloaded entry")
        downloadedEntry.tap()
        XCTAssertTrue(app.cells.element(boundBy: 2).waitForExistence(timeout: 180),
                      "3 downloads did not install (conversion + transfer window exceeded)")
        // Row layout: the tune title is the row's first static text (TrackRow).
        let titles = (0..<3).map { app.cells.element(boundBy: $0).staticTexts.firstMatch.label }
        shot("A2-downloaded-list-live")
        app.terminate()

        // ── Phase B: same container, server replaced by an unreachable TEST-NET host. ──
        app.launchArguments = [
            "-crates.connection", connectionArgument(host: "192.0.2.1", token: token),
            "-uitestSilent",
        ]
        app.launch()

        // Home renders from the disk cache — no network required, no blocking, no error wall.
        XCTAssertTrue(app.staticTexts["Your Library"].waitForExistence(timeout: 30),
                      "offline cold start did not render Home from cache")
        shot("B1-home-offline")

        // Browse works offline: facets + curated roots come from the cached corpus.
        app.buttons["Browse"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Artists"].waitForExistence(timeout: 10),
                      "Browse did not render offline")
        shot("B2-browse-offline")

        // The downloaded-only surface lists the same tunes downloaded in Phase A.
        app.staticTexts["Downloaded"].firstMatch.tap()
        for title in titles {
            XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 10),
                          "downloaded tune '\(title)' missing from the offline Downloaded list")
        }
        shot("B3-downloaded-offline")

        // Tap the first downloaded tune: it must PLAY — the local file beats the (dead) stream.
        // The accessory's "miniPlayer" identifier propagates onto every child element (SwiftUI
        // container-identifier behavior), so the pill's texts/buttons are addressed through it.
        app.cells.element(boundBy: 0).tap()
        let miniTitle = app.staticTexts.matching(identifier: "miniPlayer")
            .matching(NSPredicate(format: "label == %@", titles[0])).firstMatch
        XCTAssertTrue(miniTitle.waitForExistence(timeout: 10),
                      "mini player is not showing the tapped downloaded tune")
        XCTAssertFalse(app.staticTexts["Can't play — tap for details"].exists,
                       "offline playback of a downloaded tune reported an error")

        // Playing state, asserted via the explicit play/pause label — then toggle it.
        let playPause = app.buttons.matching(identifier: "miniPlayer")
            .matching(NSPredicate(format: "label == 'Pause' OR label == 'Play'")).firstMatch
        XCTAssertTrue(playPause.waitForExistence(timeout: 10), "mini play/pause control missing")
        XCTAssertEqual(playPause.label, "Pause",
                       "downloaded tune is not in the playing state offline")
        shot("B4-playing-offline")
        playPause.tap()
        let toggledToPlay = expectation(for: NSPredicate(format: "label == 'Play'"),
                                        evaluatedWith: playPause)
        wait(for: [toggledToPlay], timeout: 5)
        shot("B5-paused-offline")
    }
}
