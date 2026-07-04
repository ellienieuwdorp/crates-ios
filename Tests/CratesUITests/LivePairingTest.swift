import XCTest

/// Interactive end-to-end validation against a REAL Crates server on the host machine. Not part of
/// the normal suite (needs a live server + a human to approve on the desktop). Drives:
///   Settings → enter host → Pair → [approve on desktop] → backup sync → real library appears.
/// Host is taken from the CRATES_HOST env var (default "localhost").
final class LivePairingTest: XCTestCase {
    nonisolated(unsafe) var app: XCUIApplication!

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name; a.lifetime = .keepAlways; add(a)
    }

    @MainActor
    func testLivePairAndSync() throws {
        // Needs a real server + a human to approve on the desktop. Opt-in via CRATES_LIVE=1.
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CRATES_LIVE"] == "1",
                          "Set CRATES_LIVE=1 to run the live pairing test")
        let host = ProcessInfo.processInfo.environment["CRATES_HOST"] ?? "localhost"
        app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)"]
        app.launch()

        // Open Settings (gear on Home).
        XCTAssertTrue(app.staticTexts["Demo Library"].waitForExistence(timeout: 10))
        app.buttons["gearshape"].firstMatch.tap()

        // Enter host + pair.
        let hostField = app.textFields.firstMatch
        XCTAssertTrue(hostField.waitForExistence(timeout: 5))
        hostField.tap()
        hostField.typeText(host)
        shot("01-host-entered")
        app.buttons["Pair with Server"].tap()
        shot("02-waiting-approval")

        // Wait for the whole pair→sync→import to finish. Settings auto-dismisses on done; then a
        // real crate from the library should appear on Home. Generous timeout: 60s approval window
        // + backup download + import.
        let synced = app.staticTexts["Play History"].waitForExistence(timeout: 180)
            || app.staticTexts["Collection"].waitForExistence(timeout: 5)
            || app.staticTexts["Library"].waitForExistence(timeout: 5)
        shot("03-after-sync")
        XCTAssertTrue(synced, "Expected a real library crate to appear after sync")

        // Open Browse to show the real crate tree.
        app.buttons["Browse"].firstMatch.tap()
        sleep(1)
        shot("04-real-library")
    }
}
