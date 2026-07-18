import XCTest

/// Round-5 wave-2 defect A (observed on device): expanding the player via the queue pill lands,
/// then does an extra up-down jolt before settling; sometimes also on drag expand/collapse.
///
/// Like QueueMorphTests, the *visual* proof is captured from outside the process (screenshot
/// loop + the `-morphLog` height trace in the app's Documents). This test drives the four
/// transition kinds slowly with settled holds between them, so the camera and the log get
/// clean post-settle windows: any height movement inside a hold is the jolt.
///
/// Settled-state assertions make it a regression test on its own: after each transition the
/// player must be in the expected detent.
final class QueueJoltTests: XCTestCase {
    nonisolated(unsafe) var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
    }

    /// Same navigation as QueueMorphTests: demo mode's dead lap must finish before manual
    /// queueing so the queue rows survive (nothing tries to play them).
    @MainActor
    private func launchAndOpenPlayer() {
        app = XCUIApplication()
        app.launchArguments = ["-uitestDemo", "-uitestSilent", "-morphLog"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Demo Library"].waitForExistence(timeout: 10))
        app.buttons["Browse"].firstMatch.tap()
        let crate = app.staticTexts["Peak Time / Driving"].firstMatch
        XCTAssertTrue(crate.waitForExistence(timeout: 5))
        crate.tap()
        let firstTrack = app.staticTexts["Solar Wind"].firstMatch
        XCTAssertTrue(firstTrack.waitForExistence(timeout: 5))
        firstTrack.tap()
        sleep(4)

        for title in ["Nightdrive (Original Mix)", "Endless"] {
            let row = app.staticTexts[title].firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 5))
            let start = row.coordinate(withNormalizedOffset: CGVector(dx: 0.0, dy: 0.5))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 360, dy: 0)))
            usleep(800_000)
        }

        let mini = app.descendants(matching: .any)["miniPlayer"].firstMatch
        XCTAssertTrue(mini.waitForExistence(timeout: 5))
        mini.tap()
        XCTAssertTrue(app.descendants(matching: .any)["queueHandle"].firstMatch
            .waitForExistence(timeout: 5), "full player did not open")
    }

    /// (a) tap-expand → hold, (d) tap-collapse via the floating chevron → hold,
    /// (b) slow drag expand → hold, (c) slow drag collapse → hold.
    @MainActor
    func testAllFourTransitionsSettleCleanly() {
        launchAndOpenPlayer()
        sleep(3) // settled-collapsed baseline window

        let handle = app.descendants(matching: .any)["queueHandle"].firstMatch
        let queueList = app.descendants(matching: .any)["queueList"].firstMatch
        let window = app.windows.firstMatch

        // (a) Tap-expand: the primary repro path.
        handle.tap()
        XCTAssertTrue(queueList.staticTexts["Nightdrive (Original Mix)"]
            .waitForExistence(timeout: 5), "queue did not expand from the pill tap")
        sleep(4) // post-settle window — any height motion here is the jolt

        // (d) Tap-collapse via the floating chevron.
        let chevron = app.descendants(matching: .any)["queueCollapseChevron"].firstMatch
        XCTAssertTrue(chevron.waitForExistence(timeout: 5))
        chevron.tap()
        sleep(4) // post-settle window
        XCTAssertTrue(handle.isHittable, "player did not settle collapsed after chevron tap")

        // (b) Slow drag expand.
        let sheetTop = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.06))
        handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.4, thenDragTo: sheetTop,
                   withVelocity: XCUIGestureVelocity(rawValue: 60), thenHoldForDuration: 0.5)
        XCTAssertTrue(queueList.staticTexts["Nightdrive (Original Mix)"]
            .waitForExistence(timeout: 5), "queue did not expand from the slow drag")
        sleep(4) // post-settle window

        // (c) Slow drag collapse.
        let sheetBottom = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9))
        handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.4, thenDragTo: sheetBottom,
                   withVelocity: XCUIGestureVelocity(rawValue: 60), thenHoldForDuration: 0.5)
        sleep(4) // post-settle window
        XCTAssertTrue(handle.isHittable, "player did not settle collapsed after the slow drag")
    }
}
