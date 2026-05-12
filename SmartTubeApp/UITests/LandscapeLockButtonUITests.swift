import XCTest

// MARK: - LandscapeLockButtonUITests
//
// Verifies the landscape lock button is present in the player controls overlay
// and that the "Landscape Always Play" toggle has been removed from Settings.
//
// Network access is required for the player test (deeplink opens a real video).
// The Settings test is local-only.

final class LandscapeLockButtonUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
        app = nil
    }

    // MARK: - Tests

    /// The landscape lock button should appear in the player top bar after the
    /// controls become visible.
    func testLandscapeLockButtonExistsInPlayer() throws {
        app.launchArguments = [
            "--uitesting",
            "--uitesting-deeplink-video=dQw4w9WgXcQ"
        ]
        app.launch()

        let player = app.otherElements["player.view"].firstMatch
        guard player.waitForExistence(timeout: 20) else {
            throw XCTSkip("Player did not open within 20 s — network unavailable or video inaccessible")
        }

        // Tap to make controls visible if they are hidden.
        player.tap()

        let lockButton = app.buttons["player.landscapeLockButton"].firstMatch
        XCTAssertTrue(lockButton.waitForExistence(timeout: 5),
                      "Landscape lock button must appear in the player controls overlay")
        XCTAssertTrue(lockButton.isHittable,
                      "Landscape lock button must be tappable")
    }

    /// Tapping the lock button should not crash or dismiss the player.
    func testLandscapeLockButtonToggles() throws {
        app.launchArguments = [
            "--uitesting",
            "--uitesting-deeplink-video=dQw4w9WgXcQ"
        ]
        app.launch()

        let player = app.otherElements["player.view"].firstMatch
        guard player.waitForExistence(timeout: 20) else {
            throw XCTSkip("Player did not open within 20 s — network unavailable or video inaccessible")
        }

        player.tap()

        let lockButton = app.buttons["player.landscapeLockButton"].firstMatch
        XCTAssertTrue(lockButton.waitForExistence(timeout: 5),
                      "Landscape lock button must be present before tapping")

        // Tap to lock — should not crash or dismiss the player.
        lockButton.tap()
        XCTAssertTrue(player.waitForExistence(timeout: 3),
                      "Player must remain visible after tapping the landscape lock button")
        XCTAssertEqual(app.state, .runningForeground,
                       "App must remain running after toggling the landscape lock")

        // Tap again to unlock.
        player.tap() // show controls again if hidden
        XCTAssertTrue(lockButton.waitForExistence(timeout: 5),
                      "Lock button must still exist after first tap")
        lockButton.tap()
        XCTAssertTrue(player.waitForExistence(timeout: 3),
                      "Player must remain visible after unlocking")
    }

    /// The "Landscape Always Play" toggle must no longer appear in Settings.
    func testLandscapeAlwaysPlayRemovedFromSettings() {
        app.launchArguments = ["--uitesting"]
        app.launch()

        UITestHelpers.tapTab(named: "Settings", in: app)
        let form = app.collectionViews.firstMatch
        XCTAssertTrue(form.waitForExistence(timeout: 5),
                      "Settings form must appear")

        // Scroll through the entire settings form looking for the removed toggle.
        var found = false
        var lastFrame = CGRect.zero
        for _ in 0..<20 {
            let toggle = form.switches["settings.landscapeAlwaysPlayToggle"].firstMatch
            if toggle.exists {
                found = true
                break
            }
            let currentFrame = form.frame
            if currentFrame == lastFrame { break } // reached the bottom
            lastFrame = currentFrame
            form.swipeUp()
        }

        XCTAssertFalse(found,
                       "settings.landscapeAlwaysPlayToggle must not appear in Settings — it was replaced by the in-player lock button")
    }
}
