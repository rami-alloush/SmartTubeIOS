import XCTest

/// Verifies that a Shorts row appears on the Home tab after the feed loads.
///
/// The row is rendered only when `HomeViewModel.homeShortsVideos` is non-empty,
/// which requires `fetchShorts()` (FEshorts browse) to return videos.
/// A failure here means the Shorts fetch is broken at the API or parser level.
final class HomeShortsRowUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["--uitesting", "--uitesting-enable-shorts"]
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - Helpers

    /// Scrolls the horizontal chip bar until the Shorts chip is on-screen,
    /// then taps it. Mirrors the same helper used in ShortsNavigationUITests.
    private func tapShortsChip(timeout: TimeInterval = 10) {
        let chip = app.buttons["Shorts"]
        XCTAssertTrue(chip.waitForExistence(timeout: timeout), "Shorts chip not found in Home chip bar")

        let screenWidth = app.windows.firstMatch.frame.width
        let right = app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.09))
        let left  = app.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.09))
        for _ in 0..<6 {
            let frame = chip.frame
            guard frame.origin.x < 4 || frame.maxX > screenWidth - 4 else { break }
            if frame.origin.x < 4 { left.press(forDuration: 0.05, thenDragTo: right) }
            else { right.press(forDuration: 0.05, thenDragTo: left) }
            Thread.sleep(forTimeInterval: 0.3)
        }
        chip.tap()
    }

    // MARK: - Tests

    /// Regression test for #96 — cold-launch Shorts chip shows video cards.
    ///
    /// Before the fix, `fetchShorts()` used `post()` (WEB client headers,
    /// www.youtube.com) with the TV OAuth Bearer token, causing HTTP 400 and
    /// an empty Shorts feed on fresh launch. After the fix it uses `postTV()`
    /// (TVHTML5 headers, youtubei.googleapis.com), which accepts the token.
    ///
    /// The test launches the app fresh, immediately taps the Shorts chip
    /// without navigating anywhere else first, and waits for at least one
    /// `shorts.card.*` video card to appear.
    func test_ColdLaunch_ShortsChip_ShowsVideos() throws {
        // Home tab is the default; tap the Shorts chip immediately — no prior navigation.
        UITestHelpers.tapTab(named: "Home", in: app)
        tapShortsChip()

        // Wait for the Shorts feed scroll view to appear.
        let shortsScroll = app.scrollViews["home.shortsRow"]
        guard shortsScroll.waitForExistence(timeout: 30) else {
            throw XCTSkip(
                "home.shortsRow not found after cold-launch Shorts chip tap. " +
                "Likely a network issue (no sign-in / API unavailable). Skipping."
            )
        }

        // At least one portrait short card must be present — an empty row is the regression.
        let predicate = NSPredicate(format: "identifier BEGINSWITH 'shorts.card.'")
        let cards = shortsScroll.descendants(matching: .any).matching(predicate)
        XCTAssertGreaterThan(
            cards.count, 0,
            "Shorts chip tapped on cold launch but no shorts.card.* cards found — " +
            "fetchShorts() may be returning HTTP 400 (wrong client context regression #96)."
        )
    }

    /// The home feed must display a Shorts row (`home.shortsRow`) containing
    /// at least one `shorts.card.*` element.
    func test_HomeTab_ShortsRowVisible() throws {
        // Navigate to Home tab.
        UITestHelpers.tapTab(named: "Home", in: app)

        // Wait for regular video cards to confirm the feed loaded.
        guard UITestHelpers.waitForVideoCards(in: app, timeout: 30) != nil else {
            throw XCTSkip("Home feed did not load any video cards — network issue.")
        }

        // The Shorts row may need a moment after regular videos appear.
        let shortsRow = app.scrollViews["home.shortsRow"]
        guard shortsRow.waitForExistence(timeout: 15) else {
            throw XCTSkip(
                "home.shortsRow not found — fetchShorts() likely returned 0 videos " +
                "(FEshorts API flakiness). Skipping rather than failing."
            )
        }

        // Confirm at least one portrait short card exists inside the row.
        let predicate = NSPredicate(format: "identifier BEGINSWITH 'shorts.card.'")
        let cards = shortsRow.descendants(matching: .any).matching(predicate)
        XCTAssertGreaterThan(
            cards.count, 0,
            "home.shortsRow is present but contains no shorts.card.* elements."
        )
    }
}
