import XCTest

/// Verification harness for the Now Playing queue morph (Ellie, 2026-07-10: the queue faded
/// on its own curve, separate from the player — the morph must track the drag as ONE surface).
///
/// The mid-gesture *visual* proof is captured from OUTSIDE the process (`xcrun simctl io
/// screenshot` loop while these tests run) — XCTest can't observe intermediate opacity. These
/// tests provide the slow, deterministic drags for that camera, plus settled-state assertions.
final class QueueMorphTests: XCTestCase {
    nonisolated(unsafe) var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
    }

    /// Demo mode on the simulator has no playable audio, so starting a crate makes failure
    /// auto-advance walk the whole context and stop honestly at its end with an empty
    /// Up Next. Queue rows for the morph therefore come from manual swipe-queueing AFTER
    /// that dead lap settles — those entries stay put because nothing tries to play them.
    @MainActor
    private func launchAndOpenPlayer(extraArguments: [String] = []) {
        app = XCUIApplication()
        app.launchArguments = ["-uitestDemo", "-uitestSilent"] + extraArguments
        app.launch()

        XCTAssertTrue(app.staticTexts["Demo Library"].waitForExistence(timeout: 10))
        app.buttons["Browse"].firstMatch.tap()
        let crate = app.staticTexts["Peak Time / Driving"].firstMatch
        XCTAssertTrue(crate.waitForExistence(timeout: 5))
        crate.tap()
        let firstTrack = app.staticTexts["Solar Wind"].firstMatch
        XCTAssertTrue(firstTrack.waitForExistence(timeout: 5))
        firstTrack.tap()
        sleep(4) // let the demo dead lap finish so it can't drain the manual queue below

        // Manual queue entries: full leading swipe on two rows → add to end of queue.
        // (XCUIElement.swipeRight on the label is too short to cross the full-swipe
        // threshold — drag a coordinate across the whole row width instead.)
        for title in ["Nightdrive (Original Mix)", "Endless"] {
            let row = app.staticTexts[title].firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 5))
            let start = row.coordinate(withNormalizedOffset: CGVector(dx: 0.0, dy: 0.5))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 360, dy: 0)))
            usleep(800_000) // let the swipe action fire and the row settle back
        }

        let mini = app.descendants(matching: .any)["miniPlayer"].firstMatch
        XCTAssertTrue(mini.waitForExistence(timeout: 5))
        mini.tap()
        XCTAssertTrue(app.descendants(matching: .any)["queueHandle"].firstMatch
            .waitForExistence(timeout: 5), "full player did not open")
    }

    /// Slow detent drags in both directions with settled holds between, so an external
    /// screenshot loop gets clean mid-gesture frames of expand AND collapse.
    @MainActor
    func testSlowQueueDragBothDirections() {
        launchAndOpenPlayer()
        sleep(3) // settled-collapsed still for the camera

        let handle = app.descendants(matching: .any)["queueHandle"].firstMatch
        let window = app.windows.firstMatch

        // Expand: grab the handle pill and drag it near the top, slowly (~60 pt/s).
        let sheetTop = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.06))
        handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.4, thenDragTo: sheetTop,
                   withVelocity: XCUIGestureVelocity(rawValue: 60), thenHoldForDuration: 0.5)

        // Settled expanded: the next context track is visible INSIDE the queue list (the
        // crate list behind the sheet shows the same title, so scope to the list).
        let queueList = app.descendants(matching: .any)["queueList"].firstMatch
        XCTAssertTrue(queueList.waitForExistence(timeout: 5))
        XCTAssertTrue(queueList.staticTexts["Nightdrive (Original Mix)"]
            .waitForExistence(timeout: 5), "queue did not expand from the slow drag")
        sleep(3) // settled-expanded still for the camera

        // Collapse: same grab, dragged to the bottom third, same slow velocity.
        let sheetBottom = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9))
        handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.4, thenDragTo: sheetBottom,
                   withVelocity: XCUIGestureVelocity(rawValue: 60), thenHoldForDuration: 0.5)

        sleep(3) // settled-collapsed still for the camera
        XCTAssertTrue(handle.isHittable, "player did not settle back to the collapsed detent")
    }

    /// Collapsed detent at the largest accessibility type size: everything from the artwork
    /// to the queue pill must fit on screen (TODO §6 residual — art scales down at AX sizes).
    /// Navigation goes through the Home "Inbox" tile + first row: at AXXXL the Browse crate
    /// list is virtualized and the drag test's crate sits below the fold.
    @MainActor
    func testCollapsedPlayerFitsAtAccessibilityXXXL() {
        app = XCUIApplication()
        app.launchArguments = [
            "-uitestDemo", "-uitestSilent",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
        ]
        app.launch()

        XCTAssertTrue(app.staticTexts["Demo Library"].waitForExistence(timeout: 20))
        app.buttons["Browse"].firstMatch.tap()
        // At AXXXL the crate sits below the fold of the virtualized Browse list.
        let crate = app.staticTexts["Peak Time / Driving"].firstMatch
        var scrolls = 0
        while !(crate.exists && crate.isHittable), scrolls < 8 {
            app.swipeUp()
            scrolls += 1
        }
        XCTAssertTrue(crate.exists, "crate not reachable at AXXXL")
        crate.tap()
        let firstTrack = app.staticTexts["Solar Wind"].firstMatch
        XCTAssertTrue(firstTrack.waitForExistence(timeout: 5))
        firstTrack.tap()

        // Playback (even the demo dead lap) must have claimed the mini player before
        // expanding, or the sheet opens onto "Nothing playing".
        let idlePill = app.staticTexts["Not Playing"].firstMatch
        var waits = 0
        while idlePill.exists, waits < 10 { usleep(500_000); waits += 1 }
        let mini = app.descendants(matching: .any)["miniPlayer"].firstMatch
        XCTAssertTrue(mini.waitForExistence(timeout: 5))
        mini.tap()
        XCTAssertTrue(app.descendants(matching: .any)["queueHandle"].firstMatch
            .waitForExistence(timeout: 5), "full player did not open")
        sleep(4) // still frame for the camera

        // Hittability proves the controls land inside the window, not below the fold.
        XCTAssertTrue(app.descendants(matching: .any)["playerPlayPause"].firstMatch.isHittable,
                      "transport is off screen at AXXXL")
        XCTAssertTrue(app.descendants(matching: .any)["queueHandle"].firstMatch.isHittable,
                      "queue pill is off screen at AXXXL")
    }
}
