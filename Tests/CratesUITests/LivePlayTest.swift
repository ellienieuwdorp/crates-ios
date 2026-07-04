import XCTest

/// Reproduces the on-device "crash when playing a real file" report (2026-07-04): drives the
/// real (already-paired) library and starts actual streaming playback. Opt-in via CRATES_LIVE=1
/// so CI/demo runs never depend on a live server. A crash here lands the crash report in the
/// xcresult bundle — that's the point.
final class LivePlayTest: XCTestCase {
    nonisolated(unsafe) var app: XCUIApplication!

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name; a.lifetime = .keepAlways; add(a)
    }

    @MainActor
    func testPlayRealTrackDoesNotCrash() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CRATES_LIVE"] == "1",
                          "Set CRATES_LIVE=1 to run against the paired live server")
        app = XCUIApplication()
        app.launch()

        app.buttons["Browse"].firstMatch.tap()
        let lib = app.staticTexts["Library"].firstMatch
        XCTAssertTrue(lib.waitForExistence(timeout: 10), "no 'Library' crate — is the app paired + synced?")
        lib.tap()

        // Start playback via the crate menu: deterministic, no dependency on tune names.
        let menu = app.buttons["crateMenu"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        menu.tap()
        let playAll = app.buttons["Play All"].firstMatch
        XCTAssertTrue(playAll.waitForExistence(timeout: 5))
        playAll.tap()

        // The reported crash hits right after playback starts; watch the process for 10s.
        sleep(5)
        shot("L1-after-play-5s")
        XCTAssertEqual(app.state, .runningForeground, "app crashed within 5s of starting real playback")
        sleep(5)
        shot("L2-after-play-10s")
        XCTAssertEqual(app.state, .runningForeground, "app crashed within 10s of starting real playback")
    }
}
