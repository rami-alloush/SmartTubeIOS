import XCTest

// MARK: - QuickAccessRowUITests
//
// Regression test for GitHub issue #52: quick-access row should appear
// below the progress bar with speed/quality/audio-track/sleep-timer buttons.

final class QuickAccessRowUITests: XCTestCase {

    var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--skip-onboarding"]
        app.launch()
    }

    override func tearDown() {
        app = nil
        super.tearDown()
    }

    // MARK: - Quick-access row visibility

    func testQuickAccessSpeedButtonVisibleInPlayer() throws {
        // Open player via deep link
        let playerURL = URL(string: "smarttube://play?v=dQw4w9WgXcQ")!
        app.open(playerURL)

        let player = app.otherElements["player.videoLayer"]
        XCTAssertTrue(player.waitForExistence(timeout: 15),
                      "Player view should appear after deep link")

        // Tap to show controls
        player.tap()

        let speedBtn = app.buttons["player.quickAccess.speed"]
        XCTAssertTrue(speedBtn.waitForExistence(timeout: 5),
                      "Quick-access speed button should be visible below the progress bar")
    }

    func testQuickAccessSpeedButtonOpensPicker() throws {
        let playerURL = URL(string: "smarttube://play?v=dQw4w9WgXcQ")!
        app.open(playerURL)

        let player = app.otherElements["player.videoLayer"]
        XCTAssertTrue(player.waitForExistence(timeout: 15))
        player.tap()

        let speedBtn = app.buttons["player.quickAccess.speed"]
        XCTAssertTrue(speedBtn.waitForExistence(timeout: 5))
        speedBtn.tap()

        let speedPicker = app.otherElements["player.speedPicker"]
        XCTAssertTrue(speedPicker.waitForExistence(timeout: 3),
                      "Tapping quick-access speed button should open the speed picker overlay")
    }

    func testQuickAccessRowHasAccessibilityIdentifier() throws {
        let playerURL = URL(string: "smarttube://play?v=dQw4w9WgXcQ")!
        app.open(playerURL)

        let player = app.otherElements["player.videoLayer"]
        XCTAssertTrue(player.waitForExistence(timeout: 15))
        player.tap()

        let row = app.otherElements["player.quickAccessRow"]
        XCTAssertTrue(row.waitForExistence(timeout: 5),
                      "Quick-access row should have accessibility identifier 'player.quickAccessRow'")
    }

    func testQuickAccessSleepTimerButtonVisible() throws {
        let playerURL = URL(string: "smarttube://play?v=dQw4w9WgXcQ")!
        app.open(playerURL)

        let player = app.otherElements["player.videoLayer"]
        XCTAssertTrue(player.waitForExistence(timeout: 15))
        player.tap()

        let sleepBtn = app.buttons["player.quickAccess.sleepTimer"]
        XCTAssertTrue(sleepBtn.waitForExistence(timeout: 5),
                      "Quick-access sleep timer button should be visible")
    }
}
