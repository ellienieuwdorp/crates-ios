import XCTest

/// Drives the demo flow and captures screenshots as test attachments, so palette/layout changes
/// can be reviewed without hand-tapping the simulator. Not a correctness test.
final class ScreenshotTests: XCTestCase {
    nonisolated(unsafe) var app: XCUIApplication!

    private func shot(_ name: String) {
        let s = XCUIScreen.main.screenshot()
        let a = XCTAttachment(screenshot: s)
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    @MainActor
    func testCaptureKeyScreens() {
        app = XCUIApplication()
        app.launchArguments = ["-uitestDemo"] // hermetic: force demo mode regardless of pairing
        app.launch()
        XCTAssertTrue(app.staticTexts["Demo Library"].waitForExistence(timeout: 10))
        shot("01-home")

        // Into a crate.
        app.buttons["Browse"].firstMatch.tap()
        app.staticTexts["Peak Time / Driving"].firstMatch.tap()
        let track = app.staticTexts["Solar Wind"].firstMatch
        XCTAssertTrue(track.waitForExistence(timeout: 5))
        shot("02-crate-detail")

        // Start playback → mini player.
        track.tap()
        sleep(1)
        shot("03-playing-miniplayer")

        // Expand to full player.
        let matches = app.staticTexts.matching(identifier: "Solar Wind")
        matches.element(boundBy: max(0, matches.count - 1)).tap()
        sleep(1)
        shot("04-now-playing")

        // Back to Home with the mini player up — the hotlink grid must sit above the accessory.
        app.swipeDown(velocity: .fast)
        app.buttons["Home"].firstMatch.tap()
        sleep(1)
        shot("05-home-with-miniplayer")
    }
}
