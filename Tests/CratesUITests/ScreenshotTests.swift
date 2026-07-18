import XCTest

/// Drives the demo flow and captures screenshots as test attachments, so palette/layout changes
/// can be reviewed without hand-tapping the simulator. Not a correctness test.
final class ScreenshotTests: XCTestCase {
    nonisolated(unsafe) var app: XCUIApplication!

    @MainActor
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
        app.launchArguments = ["-uitestDemo", "-uitestPlayableDemo", "-uitestSilent"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Demo Library"].waitForExistence(timeout: 10))
        shot("01-home")

        // Into a crate.
        app.buttons["Browse"].firstMatch.tap()
        app.staticTexts["Peak Time / Driving"].firstMatch.tap()
        let track = app.staticTexts["Solar Wind"].firstMatch
        XCTAssertTrue(track.waitForExistence(timeout: 5))
        shot("02-crate-detail")

        // Start playback → mini player, using the silent bundled screenshot fixture.
        track.tap()
        sleep(1)
        shot("03-playing-miniplayer")

        // Trailing swipe reveals Play Next without committing the action.
        let playNextRow = app.staticTexts["Nightdrive (Original Mix)"].firstMatch
        let playNextStart = playNextRow.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5))
        playNextStart.press(forDuration: 0.1,
                            thenDragTo: playNextStart.withOffset(CGVector(dx: -145, dy: 0)))
        sleep(1)
        shot("04-swipe-play-next")
        app.navigationBars["Peak Time / Driving"].tap() // dismiss the exposed action

        // Leading swipe reveals Queue; tap it so the expanded player has a manual queue row.
        let queueRow = app.staticTexts["Endless"].firstMatch
        let queueStart = queueRow.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5))
        queueStart.press(forDuration: 0.1,
                         thenDragTo: queueStart.withOffset(CGVector(dx: 145, dy: 0)))
        sleep(1)
        shot("05-swipe-add-to-queue")
        let queueAction = app.buttons["Queue"].firstMatch
        XCTAssertTrue(queueAction.waitForExistence(timeout: 3))
        queueAction.tap()

        // Swipe up on the mini player, then expand the in-place queue with a slow detent drag.
        let mini = app.descendants(matching: .any)["miniPlayer"].firstMatch
        XCTAssertTrue(mini.waitForExistence(timeout: 5))
        mini.swipeUp()
        sleep(1)
        shot("06-now-playing")

        let handle = app.descendants(matching: .any)["queueHandle"].firstMatch
        XCTAssertTrue(handle.waitForExistence(timeout: 5), "full player did not open")
        let window = app.windows.firstMatch
        handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.25,
                   thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)),
                   withVelocity: XCUIGestureVelocity(rawValue: 180),
                   thenHoldForDuration: 0.25)
        sleep(1)
        shot("07-queue-expanded")
        handle.tap() // collapse again so the swipe-down dismiss below behaves the same
        sleep(1)

        // Basic navigation: Home with the mini player, then an offline local search.
        app.swipeDown(velocity: .fast)
        app.buttons["Home"].firstMatch.tap()
        sleep(1)
        shot("08-home-with-miniplayer")
        app.buttons["Search"].firstMatch.tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("Dozzy")
        XCTAssertTrue(app.staticTexts["Submerged"].waitForExistence(timeout: 5))
        shot("09-local-search")
    }
}
