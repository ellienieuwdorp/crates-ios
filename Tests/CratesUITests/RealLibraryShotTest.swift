import XCTest

/// Screenshots the real (already-paired) library — Browse tree and a crate with tunes. Requires
/// the app to be paired + synced (run after LivePairingTest). Captures visuals, not assertions.
final class RealLibraryShotTest: XCTestCase {
    nonisolated(unsafe) var app: XCUIApplication!

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name; a.lifetime = .keepAlways; add(a)
    }

    @MainActor
    func testCaptureRealLibrary() throws {
        // Needs an already-paired+synced app against a real server. Opt-in via CRATES_LIVE=1.
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CRATES_LIVE"] == "1",
                          "Set CRATES_LIVE=1 to capture the real library")
        app = XCUIApplication()
        app.launch()
        sleep(2)
        shot("R1-home")
        app.buttons["Browse"].firstMatch.tap()
        sleep(1)
        shot("R2-browse-tree")
        // "Library" root has direct tunes.
        let lib = app.staticTexts["Library"].firstMatch
        if lib.waitForExistence(timeout: 5) {
            lib.tap()
            sleep(2)
            shot("R3-library-tunes")
        }
    }
}
