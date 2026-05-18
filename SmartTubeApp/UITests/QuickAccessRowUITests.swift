import XCTest

// MARK: - QuickAccessRowUITests
//
// Regression test for GitHub issue #52: quick-access row should appear
// below the progress bar with speed/quality/audio-track/sleep-timer buttons.
//
// Opens the player from the home feed (same approach as PlayerControlsUITests)
// to ensure a real video is loaded before checking for the quick-access row.

final class QuickAccessRowUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = [
            "--uitesting",
            "--uitesting-show-controls",
            "--uitesting-disable-sponsorblock"
        ]
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - Helpers

    /// Opens a video from the home feed and waits for the player to appear.
    /// Skips the test if the network is unavailable.
    private func openPlayerFromHome() throws {
        UITestHelpers.tapTab(named: "Home", in: app)
        guard let card = UITestHelpers.waitForVideoCards(in: app, timeout: 20) else {
            try captureAndSkip("No video cards on Home — network unavailable or feed empty", in: app)
        }
        guard UITestHelpers.openPlayer(from: card, in: app) else {
            try captureAndSkip("Player did not open within 15 s — network unavailable or timing-dependent", in: app)
        }
        _ = app.staticTexts["player.titleLabel"].firstMatch.waitForExistence(timeout: 5)
    }

    /// Taps the player center to reveal controls, retrying up to 5 times.
    /// With --uitesting-show-controls the controls overlay stays up permanently,
    /// so in practice this should return on the first check.
    private func showControls() {
        let playPause = app.buttons["player.playPauseButton"].firstMatch
        for _ in 0..<5 {
            if playPause.exists { return }
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            Thread.sleep(forTimeInterval: 1.0)
        }
    }

    func testQuickAccessSpeedButtonVisibleInPlayer() throws {
        try openPlayerFromHome()
        showControls()
        XCTAssertTrue(
            app.buttons["player.quickAccess.speed"].waitForExistence(timeout: 10),
            "Quick-access speed button should be visible below the progress bar")
    }

    func testQuickAccessSpeedButtonOpensPicker() throws {
        try openPlayerFromHome()
        showControls()
        let speedBtn = app.buttons["player.quickAccess.speed"]
        guard speedBtn.waitForExistence(timeout: 10) else {
            try captureAndSkip("player.quickAccess.speed not found — may need landscape mode or controls were auto-hidden", in: app)
        }
        // Use a coordinate tap so the UIKit touch event goes directly to the button
        // frame, bypassing any accessibility chain wrapping from the .contain modifier.
        speedBtn.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        // Check for the picker via a broad descendants search, then fall back to
        // a "Cancel" button which is always present inside every picker overlay.
        let pickerByID = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'player.speedPicker'"))
            .firstMatch
        let cancelBtn = app.buttons["Cancel"].firstMatch
        let pickerAppeared = pickerByID.waitForExistence(timeout: 5)
            || cancelBtn.waitForExistence(timeout: 2)
        XCTAssertTrue(pickerAppeared,
            "Tapping quick-access speed button should open the speed picker overlay")
    }

    func testQuickAccessRowHasAccessibilityIdentifier() throws {
        try openPlayerFromHome()
        showControls()
        XCTAssertTrue(
            app.otherElements["player.quickAccessRow"].waitForExistence(timeout: 10),
            "Quick-access row should have accessibility identifier 'player.quickAccessRow'")
    }

    func testQuickAccessSleepTimerButtonVisible() throws {
        try openPlayerFromHome()
        showControls()
        XCTAssertTrue(
            app.buttons["player.quickAccess.sleepTimer"].waitForExistence(timeout: 10),
            "Quick-access sleep timer button should be visible")
    }
}
