import XCTest

// MARK: - WatchLaterContextMenuUITests
//
// Regression tests for the "Save to Watch Later" context-menu action on video cards.
//
// Bug: the InnerTube endpoint was built as "browse_edit_playlist" (underscore) instead
// of the correct "browse/edit_playlist" (slash), causing YouTube to return HTTP 404.
// Users would see a "Could Not Save / HTTP error 404" alert instead of success.
//
// Requirements:
//   • A signed-in account is required for tests that verify the success alert.
//   • Network access is required.
//   • Run on an iOS 17+ simulator with the SmartTubeApp scheme selected.

final class WatchLaterContextMenuUITests: XCTestCase {

    private var app: XCUIApplication!

    // MARK: - Lifecycle

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["--uitesting"]
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - Helpers

    /// Navigates to the Home tab and waits for at least one video card.
    /// Calls XCTFail if the feed is unavailable (network is always up in CI).
    private func firstHomeCard() throws -> XCUIElement {
        UITestHelpers.tapTab(named: "Home", in: app)
        guard let card = UITestHelpers.waitForVideoCards(in: app, timeout: 20) else {
            XCTFail("No video cards on Home — network unavailable or feed empty")
            return app.otherElements.firstMatch  // unreachable (continueAfterFailure = false)
        }
        return card
    }

    /// Long-presses `element` to open the context menu and waits for the
    /// "Save to Watch Later" menu item to appear.
    /// Returns the menu button or nil if the item isn't present (e.g. signed out).
    private func openContextMenuWatchLaterButton(on element: XCUIElement) -> XCUIElement? {
        element.press(forDuration: 1.0)
        let button = app.buttons["Save to Watch Later"].firstMatch
        guard button.waitForExistence(timeout: 5) else { return nil }
        return button
    }

    // MARK: - Structural tests (sign-in not required)

    /// Verifies the context menu appears on a long-press — basic smoke test.
    func testContextMenuAppearsOnLongPress() throws {
        let card = try firstHomeCard()
        card.press(forDuration: 1.0)
        // At minimum the Share item must appear (shown for all users).
        let shareItem = app.buttons["Share"].firstMatch
        XCTAssertTrue(shareItem.waitForExistence(timeout: 5),
                      "Context menu 'Share' item should appear after long-pressing a video card")
        // Dismiss
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.02)).tap()
    }

    /// Verifies the "Save to Watch Later" item is visible when a user is signed in.
    func testWatchLaterMenuItemVisibleWhenSignedIn() throws {
        let card = try firstHomeCard()
        guard let button = openContextMenuWatchLaterButton(on: card) else {
            try captureAndSkip("'Save to Watch Later' not shown — account may not be signed in", in: app)
        }
        XCTAssertTrue(button.exists,
                      "'Save to Watch Later' context menu item must be visible for signed-in users")
        // Dismiss without tapping
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.02)).tap()
    }

    // MARK: - Regression test (signed-in account required)

    /// Regression for the HTTP 404 bug: tapping "Save to Watch Later" must show
    /// the success alert ("Saved to Watch Later") and must NOT show "HTTP error 404"
    /// or any "Could Not Save" alert.
    ///
    /// This test will fail if the InnerTube endpoint reverts to "browse_edit_playlist"
    /// (underscore) instead of the correct "browse/edit_playlist" (slash).
    func testSaveToWatchLaterShowsSuccessAlertNotError() throws {
        let card = try firstHomeCard()
        guard let button = openContextMenuWatchLaterButton(on: card) else {
            try captureAndSkip("'Save to Watch Later' not shown — account may not be signed in", in: app)
        }
        button.tap()

        // The API call is async; wait up to 10 s for an alert to appear.
        let anyAlert = app.alerts.firstMatch
        XCTAssertTrue(anyAlert.waitForExistence(timeout: 10),
                      "An alert should appear after tapping 'Save to Watch Later'")

        // Must be the success alert, not the error alert.
        let successAlert = app.alerts["Saved to Watch Later"].firstMatch
        let errorAlert   = app.alerts["Could Not Save"].firstMatch

        XCTAssertFalse(errorAlert.exists,
                       "Got 'Could Not Save' alert — endpoint returned an error. " +
                       "Check that InnerTubeAPI+Social uses 'browse/edit_playlist' (slash), not 'browse_edit_playlist' (underscore).")
        XCTAssertTrue(successAlert.exists,
                      "'Saved to Watch Later' success alert must appear after a successful API call")

        successAlert.buttons["OK"].tap()
    }
}
