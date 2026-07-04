import XCTest

/// End-to-end download proof against the LIVE paired server (opt-in via CRATES_LIVE=1):
/// long-press a real track → Download → wait for the downloaded indicator. Exercises URL
/// building, bearer auth, the server's conversion latency, verification, manifest install,
/// and the row badge.
final class LiveDownloadTest: XCTestCase {
    @MainActor
    func testDownloadRealTrackEndToEnd() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CRATES_LIVE"] == "1",
                          "Set CRATES_LIVE=1 to run against the paired live server")
        let app = XCUIApplication()
        app.launch()

        app.buttons["Browse"].firstMatch.tap()
        let lib = app.staticTexts["Library"].firstMatch
        XCTAssertTrue(lib.waitForExistence(timeout: 10), "no 'Library' crate — is the app paired + synced?")
        lib.tap()

        // Hunt for the first row whose menu offers Download — many of this library's early
        // rows are codec-null bandcamp tunes whose menus (correctly) offer nothing.
        var tapped = false
        for index in 5..<18 {
            let row = app.cells.element(boundBy: index)
            guard row.waitForExistence(timeout: 5) else { break }
            row.press(forDuration: 0.8)
            let download = app.buttons["Download"].firstMatch
            if download.waitForExistence(timeout: 2) {
                download.tap()
                tapped = true
                break
            }
            app.tap() // dismiss the menu that offered nothing
        }
        guard tapped else {
            throw XCTSkip("no downloadable row among the first visible tunes")
        }

        // Server converts (~0.5s per source-minute) then transfers on LAN: allow 60s.
        let badge = app.images["arrow.down.circle.fill"].firstMatch
        XCTAssertTrue(badge.waitForExistence(timeout: 60),
                      "downloaded indicator never appeared — download failed or was mis-verified")
    }
}
