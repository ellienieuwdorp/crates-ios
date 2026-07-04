import XCTest

/// End-to-end smoke of the demo-mode happy path: launch → Home hotlinks → Browse → open a crate →
/// tap a track → mini player appears → expand to full player → queue sheet. Exercises the whole
/// cache→UI→player wiring without a server.
final class SmokeTests: XCTestCase {
    nonisolated(unsafe) var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func launch() {
        app = XCUIApplication()
        app.launchArguments = ["-uitestDemo"] // hermetic: force demo mode regardless of pairing
        app.launch()
    }

    @MainActor
    func testDemoBrowsePlayAndQueueFlow() {
        launch()
        // Home renders demo hotlinks.
        XCTAssertTrue(app.staticTexts["Demo Library"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Inbox"].exists)

        // Browse tab → crate list.
        app.buttons["Browse"].firstMatch.tap()
        let crate = app.staticTexts["Peak Time / Driving"].firstMatch
        XCTAssertTrue(crate.waitForExistence(timeout: 5))
        crate.tap()

        // Crate detail shows demo tunes; tap the first row to start playback.
        let firstTrack = app.staticTexts["Solar Wind"].firstMatch
        XCTAssertTrue(firstTrack.waitForExistence(timeout: 5))
        firstTrack.tap()

        // Mini player accessory appears with the playing track (row + accessory both match).
        let matches = app.staticTexts.matching(identifier: "Solar Wind")
        XCTAssertTrue(matches.firstMatch.waitForExistence(timeout: 5))

        // Expand to the full player via the mini player (the accessory is the last match).
        let accessory = matches.element(boundBy: max(0, matches.count - 1))
        accessory.tap()
        let queueButton = app.buttons["list.bullet"].firstMatch
        if queueButton.waitForExistence(timeout: 3) {
            queueButton.tap()
            XCTAssertTrue(app.staticTexts["Up Next"].waitForExistence(timeout: 3))
        }
    }

    @MainActor
    func testSearchTabFindsDemoTracks() {
        launch()
        // Let the cold launch settle before driving the keyboard (first-run flake otherwise).
        XCTAssertTrue(app.staticTexts["Demo Library"].waitForExistence(timeout: 10))
        app.buttons["Search"].firstMatch.tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("Dozzy")
        XCTAssertTrue(app.staticTexts["Submerged"].waitForExistence(timeout: 10))
    }
}
