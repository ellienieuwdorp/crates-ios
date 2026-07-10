import XCTest

/// The swipe-up-to-open gesture on the mini player accessory (TODO §6): a short upward drag
/// on the pill must present the full player, same destination as tap. Tap behavior is covered
/// by SmokeTests; this exercises the gesture path specifically.
final class MiniPlayerGestureTests: XCTestCase {
    nonisolated(unsafe) var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testSwipeUpOnMiniPlayerOpensFullPlayer() {
        app = XCUIApplication()
        app.launchArguments = ["-uitestDemo", "-uitestSilent"]
        app.launch()

        // Start playback from a crate so the accessory has content.
        XCTAssertTrue(app.staticTexts["Demo Library"].waitForExistence(timeout: 10))
        app.buttons["Browse"].firstMatch.tap()
        let crate = app.staticTexts["Peak Time / Driving"].firstMatch
        XCTAssertTrue(crate.waitForExistence(timeout: 5))
        crate.tap()
        let firstTrack = app.staticTexts["Solar Wind"].firstMatch
        XCTAssertTrue(firstTrack.waitForExistence(timeout: 5))
        firstTrack.tap()

        let mini = app.descendants(matching: .any)["miniPlayer"].firstMatch
        XCTAssertTrue(mini.waitForExistence(timeout: 5))

        // Swipe up on the accessory — the full player sheet must appear (queue pill present).
        mini.swipeUp()
        let handle = app.descendants(matching: .any)["queueHandle"].firstMatch
        XCTAssertTrue(handle.waitForExistence(timeout: 5),
                      "swipe up on the mini player did not open the full player")

        // Dismiss and confirm tap still opens it too (gesture must not eat the tap path).
        app.swipeDown()
        XCTAssertFalse(handle.waitForExistence(timeout: 3))
        XCTAssertTrue(mini.waitForExistence(timeout: 5))
        mini.tap()
        XCTAssertTrue(handle.waitForExistence(timeout: 5),
                      "tap on the mini player stopped opening the full player")
    }
}
