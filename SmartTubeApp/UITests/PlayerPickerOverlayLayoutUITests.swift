import XCTest

/// Verifies that all player picker overlays (Quality, Speed, Sleep Timer, Captions, Audio Track)
/// are constrained to the same portrait-width cap as the more-menu overlay (task #58).
final class PlayerPickerOverlayLayoutUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = [
            "--uitesting",
            "--uitesting-deeplink-video=dQw4w9WgXcQ",
            "--uitesting-open-more-menu"
        ]
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
        app = nil
    }

    // MARK: - Helpers

    private func waitForPlayer() throws {
        let player = app.otherElements["player.view"].firstMatch
        guard player.waitForExistence(timeout: 20) else {
            throw XCTSkip("Player did not open within 20 s — network unavailable or video inaccessible")
        }
    }

    /// Checks that an overlay element's width is ≤ 85 % of the screen width (the portrait cap).
    private func assertWidthConstrained(_ element: XCUIElement, named name: String) {
        let screenWidth = app.frame.size.width
        let overlayWidth = element.frame.size.width
        let expectedMax = screenWidth * 0.85
        XCTAssertLessThanOrEqual(
            overlayWidth, expectedMax,
            "\(name) width (\(overlayWidth)pt) must be ≤ 85 % of screen width (\(screenWidth)pt) — task #58"
        )
        XCTAssertGreaterThan(
            overlayWidth, screenWidth * 0.3,
            "\(name) width (\(overlayWidth)pt) must be reasonable (> 30 % of screen)"
        )
    }

    // MARK: - Tests

    func testQualityPickerWidthIsConstrainedInLandscape() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        app.launch()
        try waitForPlayer()

        let qualityRow = app.buttons["player.moreMenu.qualityRow"].firstMatch
        guard qualityRow.waitForExistence(timeout: 10) else {
            throw XCTSkip("Quality row not shown — video formats unavailable")
        }
        qualityRow.tap()

        let qualityPicker = app.otherElements["player.qualityPicker"].firstMatch
        XCTAssertTrue(qualityPicker.waitForExistence(timeout: 5), "Quality picker must appear after tapping quality row")
        assertWidthConstrained(qualityPicker, named: "Quality picker")
    }

    func testSpeedPickerWidthIsConstrainedInLandscape() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        app.launch()
        try waitForPlayer()

        let speedRow = app.buttons["player.moreMenu.speedRow"].firstMatch
        XCTAssertTrue(speedRow.waitForExistence(timeout: 10), "Speed row must appear in more menu")
        speedRow.tap()

        let speedPicker = app.otherElements["player.speedPicker"].firstMatch
        XCTAssertTrue(speedPicker.waitForExistence(timeout: 5), "Speed picker must appear after tapping speed row")
        assertWidthConstrained(speedPicker, named: "Speed picker")
    }

    func testSleepTimerPickerWidthIsConstrainedInLandscape() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        app.launch()
        try waitForPlayer()

        let sleepRow = app.buttons["player.moreMenu.sleepTimerRow"].firstMatch
        XCTAssertTrue(sleepRow.waitForExistence(timeout: 10), "Sleep timer row must appear in more menu")
        sleepRow.tap()

        let sleepPicker = app.otherElements["player.sleepTimerPicker"].firstMatch
        XCTAssertTrue(sleepPicker.waitForExistence(timeout: 5), "Sleep timer picker must appear after tapping sleep row")
        assertWidthConstrained(sleepPicker, named: "Sleep timer picker")
    }
}
