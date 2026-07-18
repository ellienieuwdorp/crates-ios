import XCTest

/// Round-5 wave-2 defect B (observed on device): the queue's Edit affordance was a tiny
/// footnote-sized text, and the full-width tap target of the queue pill's row meant a missed
/// Edit tap on the blank space just above the queue collapsed the very list being edited.
///
/// Contract under test:
///  1. Tapping blank space beside the pill while expanded does NOT collapse the queue.
///  2. The labeled Edit button enters edit mode; Done exits it.
///  3. The pill itself still collapses (explicit affordance kept).
final class QueueEditTests: XCTestCase {
    nonisolated(unsafe) var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
    }

    /// Same navigation as QueueMorphTests — see the demo dead-lap note there.
    @MainActor
    private func launchAndExpandQueue() {
        app = XCUIApplication()
        app.launchArguments = ["-uitestDemo", "-uitestSilent"]
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
        let handle = app.descendants(matching: .any)["queueHandle"].firstMatch
        XCTAssertTrue(handle.waitForExistence(timeout: 5), "full player did not open")
        handle.tap()
        XCTAssertTrue(app.descendants(matching: .any)["queueList"].firstMatch
            .staticTexts["Nightdrive (Original Mix)"].waitForExistence(timeout: 5),
            "queue did not expand")
    }

    @MainActor
    func testBlankSpaceDoesNotCollapseAndEditToggles() {
        launchAndExpandQueue()

        let handle = app.descendants(matching: .any)["queueHandle"].firstMatch
        let queueRow = app.descendants(matching: .any)["queueList"].firstMatch
            .staticTexts["Nightdrive (Original Mix)"]

        // (1) Blank space beside the pill — the exact spot that used to collapse the queue.
        handle.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.5)).tap()
        sleep(1)
        XCTAssertTrue(queueRow.exists && queueRow.isHittable,
                      "queue collapsed from a blank-space tap")
        handle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        sleep(1)
        XCTAssertTrue(queueRow.exists && queueRow.isHittable,
                      "queue collapsed from a blank-space tap (trailing side)")

        // (2) Edit enters edit mode (button relabels to Done); Done exits.
        let edit = app.descendants(matching: .any)["queueEdit"].firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 5), "labeled Edit button missing")
        XCTAssertEqual(edit.label, "Edit")
        edit.tap()
        XCTAssertTrue(app.descendants(matching: .any)["queueEdit"].firstMatch
            .staticTexts["Done"].waitForExistence(timeout: 3) || edit.label == "Done",
            "Edit tap did not enter edit mode")
        XCTAssertTrue(queueRow.exists, "edit mode collapsed the queue")
        edit.tap()
        var waited = 0
        while edit.label != "Edit", waited < 6 { usleep(500_000); waited += 1 }
        XCTAssertEqual(edit.label, "Edit", "Done tap did not exit edit mode")

        // (3) The pill itself still collapses.
        handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        sleep(2)
        XCTAssertFalse(queueRow.isHittable, "pill tap no longer collapses the queue")
    }
}
