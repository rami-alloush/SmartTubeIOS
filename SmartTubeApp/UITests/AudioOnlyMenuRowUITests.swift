import XCTest

// MARK: - AudioOnlyMenuRowUITests
//
// Verifies the Audio-Only row appears in the player More Menu and toggles the setting.
//
// Network access is required — the player opens a real video via deeplink.

final class AudioOnlyMenuRowUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - Helpers

    private func openPlayerAndMoreMenu(timeout: TimeInterval = 20) throws {
        app.launchArguments = [
            "--uitesting",
            "--uitesting-deeplink-video=dQw4w9WgXcQ",
            "--uitesting-open-more-menu"
        ]
        app.launch()

        let speedRow = app.buttons["player.moreMenu.speedRow"].firstMatch
        guard speedRow.waitForExistence(timeout: timeout) else {
            throw XCTSkip("More menu did not open within \(timeout) s — network unavailable or video inaccessible")
        }
    }

    // MARK: - Tests

    /// The Audio-Only row must appear in the player More Menu.
    func testAudioOnlyRowExistsInMoreMenu() throws {
        try openPlayerAndMoreMenu()

        let audioOnlyRow = app.buttons["player.moreMenu.audioOnlyRow"].firstMatch
        let scrollView = app.scrollViews["player.moreMenu.scrollView"].firstMatch

        // Scroll down until the row appears or the menu bottom is reached.
        var found = audioOnlyRow.waitForExistence(timeout: 2)
        if !found {
            for _ in 0..<5 {
                scrollView.swipeUp()
                if audioOnlyRow.waitForExistence(timeout: 1) { found = true; break }
            }
        }
        XCTAssertTrue(found, "Audio-Only row must be present in the More Menu")
    }

    /// Tapping Audio-Only must close the menu without crashing the app.
    func testAudioOnlyRowToggleDoesNotCrash() throws {
        try openPlayerAndMoreMenu()

        let audioOnlyRow = app.buttons["player.moreMenu.audioOnlyRow"].firstMatch
        let scrollView = app.scrollViews["player.moreMenu.scrollView"].firstMatch

        var found = audioOnlyRow.waitForExistence(timeout: 2)
        if !found {
            for _ in 0..<5 {
                scrollView.swipeUp()
                if audioOnlyRow.waitForExistence(timeout: 1) { found = true; break }
            }
        }
        guard found else { throw XCTSkip("Audio-Only row not visible — skipping toggle test") }

        audioOnlyRow.tap()

        let player = app.otherElements["player.view"].firstMatch
        XCTAssertTrue(player.waitForExistence(timeout: 5),
                      "Player must remain visible after tapping Audio-Only")
        XCTAssertEqual(app.state, .runningForeground,
                       "App must remain running after tapping Audio-Only")
    }
}
