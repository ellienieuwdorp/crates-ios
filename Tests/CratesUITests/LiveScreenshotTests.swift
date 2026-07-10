import XCTest

/// LIVE screenshot run against a real Crates server on localhost (the desktop app running on
/// this Mac). Opt-in and secret-free: skips unless the runner passes a server token via
/// `TEST_RUNNER_CRATES_LIVE_TOKEN=… xcodebuild test`. The paired connection is injected through
/// the UserDefaults argument domain, so no desktop pairing approval is needed and nothing
/// persists into the repo. Captures the redesigned Home (shelves + re-seeded pins), Browse
/// (facets + curated roots), and a materialized genre smart crate — all against real data.
/// Deliberately never starts playback (a live run must not blast audio from the host Mac).
final class LiveScreenshotTests: XCTestCase {

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    @MainActor
    func testLiveHomeBrowseAndSmartCrate() throws {
        guard let token = ProcessInfo.processInfo.environment["CRATES_LIVE_TOKEN"],
              !token.isEmpty else {
            throw XCTSkip("No CRATES_LIVE_TOKEN in the runner environment — live run is opt-in.")
        }

        let json = #"{"host":"localhost","port":54735,"token":"\#(token)"}"#
        let app = XCUIApplication()
        app.launchArguments = ["-crates.connection", "<data>\(Data(json.utf8).base64EncodedString())</data>"]
        app.launch()

        // First launch syncs the full backup; "Your Library" header + a shelf title appearing
        // means import finished and the adaptive Home rendered.
        XCTAssertTrue(app.staticTexts["Your Library"].waitForExistence(timeout: 90),
                      "paired Home did not appear (sync failed?)")
        _ = app.staticTexts["Recently Added"].waitForExistence(timeout: 60)
        shot("live-01-home-bottom")

        // The adaptive shelves live above the pins — scroll up to reveal them.
        app.swipeDown(velocity: .slow)
        sleep(1)
        shot("live-02-home-shelves")

        app.buttons["Browse"].firstMatch.tap()
        sleep(1)
        shot("live-03-browse")

        app.staticTexts["Artists"].firstMatch.tap()
        sleep(1)
        shot("live-04-artists")
        app.navigationBars.buttons.firstMatch.tap()

        app.staticTexts["Genres"].firstMatch.tap()
        sleep(1)
        shot("live-05-genres")
        app.navigationBars.buttons.firstMatch.tap()

        // A genre smart crate, materialized client-side (House ⊇ acid/tech house).
        app.buttons["Home"].firstMatch.tap()
        sleep(1)
        let house = app.staticTexts["House"].firstMatch
        if house.waitForExistence(timeout: 5) {
            house.tap()
            sleep(1)
            shot("live-06-smart-crate-house")
        }
    }
}
