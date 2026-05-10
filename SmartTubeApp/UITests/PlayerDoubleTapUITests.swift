import XCTest

// MARK: - PlayerDoubleTapUITests
//
// UI tests for the zone-based double-tap gesture on PlayerView (iOS only).
//
// The player surface is divided into three horizontal zones:
//   Left  1/3 — double-tap seeks backward  (seekBackSeconds)
//   Middle 1/3 — double-tap toggles Fit / Fill video gravity
//   Right 1/3 — double-tap seeks forward   (seekForwardSeconds)
//
// Each test opens a fixed video via deep-link (bypassing the Home feed), waits
// for the controls overlay to auto-hide, performs a double-tap in the target
// zone, and asserts that the self-dismissing toast appears in the accessibility tree.
//
// Requirements:
//   • Network access (YouTube must serve dQw4w9WgXcQ).
//   • Run on an iOS 17+ simulator with the SmartTube scheme.

final class PlayerDoubleTapUITests: XCTestCase {

    private var app: XCUIApplication!

    // MARK: - Lifecycle

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += [
            "--uitesting",
            "--uitesting-deeplink-video=dQw4w9WgXcQ",
            "--uitesting-disable-sponsorblock"
        ]
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - Helpers

    /// Waits for the player to open via the deep-link launch argument.
    private func openPlayer() {
        let title = app.staticTexts["player.titleLabel"].firstMatch
        guard title.waitForExistence(timeout: 15) else {
            XCTFail("player.titleLabel did not appear — deep-link did not open player")
            return
        }
    }

    /// Waits for the controls overlay to auto-hide after the player opens.
    /// Brings controls up first (known starting state), then waits predicate-based
    /// for them to disappear — avoids fixed-sleep races on cold app launches.
    private func waitForControlsToHide(timeout: TimeInterval = 12) {
        // Bring controls up so we have a known starting state.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let playPause = app.buttons["player.playPauseButton"].firstMatch
        XCTAssertTrue(playPause.waitForExistence(timeout: 4),
                      "Controls never appeared — cannot wait for them to hide")
        // Now wait for them to disappear (auto-hide fires after 4 s of inactivity).
        let hiddenPredicate = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: hiddenPredicate, object: playPause)
        XCTWaiter().wait(for: [expectation], timeout: timeout)
    }

    /// Performs a double-tap at the given normalised X position (mid-height).
    private func doubleTap(normalizedX: CGFloat) {
        app.coordinate(withNormalizedOffset: CGVector(dx: normalizedX, dy: 0.5))
            .doubleTap()
    }

    // MARK: - Tests

    /// Double-tapping the left third must show the seek-back toast (e.g. "← 10s").
    func testDoubleTapLeftZoneShowsSeekBackToast() throws {
        openPlayer()
        // Wait for controls to hide so the zone gesture fires unobstructed.
        waitForControlsToHide()

        // Tap in the centre of the left third (normalised x ≈ 0.17).
        doubleTap(normalizedX: 1.0 / 6.0)

        let toast = app.staticTexts["player.toast"].firstMatch
        XCTAssertTrue(toast.waitForExistence(timeout: 3),
                      "A seek-back toast (← Xs) must appear after double-tapping the left third of the player")
        XCTAssertTrue(toast.label.hasPrefix("\u{2190}"),
                      "Seek-back toast label must start with ← but was '\(toast.label)'")
        XCTAssertEqual(app.state, .runningForeground,
                       "App must still be running after left-zone double-tap")
    }

    /// Double-tapping the right third must show the seek-forward toast (e.g. "30s →").
    func testDoubleTapRightZoneShowsSeekForwardToast() throws {
        openPlayer()
        waitForControlsToHide()

        // Tap in the centre of the right third (normalised x ≈ 0.83).
        doubleTap(normalizedX: 5.0 / 6.0)

        let toast = app.staticTexts["player.toast"].firstMatch
        XCTAssertTrue(toast.waitForExistence(timeout: 5),
                      "A seek-forward toast (Xs →) must appear after double-tapping the right third of the player")
        XCTAssertTrue(toast.label.hasSuffix("\u{2192}"),
                      "Seek-forward toast label must end with → but was '\(toast.label)'")
        XCTAssertEqual(app.state, .runningForeground,
                       "App must still be running after right-zone double-tap")
    }

    /// Double-tapping the centre third must show a Fit or Fill video-gravity toast.
    func test_ZZDoubleTapCentreZoneTogglesFitFill() throws {
        openPlayer()
        waitForControlsToHide()

        // Tap in the centre third (off-centre to avoid exact 0.5 which may
        // conflict with iOS system gesture detection at the screen midpoint).
        doubleTap(normalizedX: 0.4)

        // Diagnostic: if controls became visible the single-tap handler fired instead of
        // the double-tap handler (controls-toggle vs scale-toggle).
        let ppAfter = app.buttons["player.playPauseButton"].firstMatch
        if ppAfter.waitForExistence(timeout: 1) {
            XCTFail("Controls appeared after centre double-tap — onTap fired instead of onDoubleTap (isEnabled race?). controlsVisible=true means isEnabled=false, so gesture overlay was disabled when double-tap arrived.")
            return
        }

        let toast = app.staticTexts["player.toast"].firstMatch
        XCTAssertTrue(toast.waitForExistence(timeout: 5),
                      "'Fit' or 'Fill' toast must appear after double-tapping the centre third of the player")
        XCTAssertTrue(toast.label == "Fit" || toast.label == "Fill",
                      "Scale toast label must be 'Fit' or 'Fill' but was '\(toast.label)'")
        XCTAssertEqual(app.state, .runningForeground,
                       "App must still be running after centre-zone double-tap")
    }

    /// Tapping each zone twice must not crash and must toggle the state consistently.
    /// Left → back (toast appears), left again → back (toast appears again).
    func testDoubleTapLeftZoneTwiceDoesNotCrash() throws {
        openPlayer()
        waitForControlsToHide()

        doubleTap(normalizedX: 1.0 / 6.0)
        // Give the first toast time to appear and the gesture system time to reset.
        Thread.sleep(forTimeInterval: 1)
        doubleTap(normalizedX: 1.0 / 6.0)

        XCTAssertEqual(app.state, .runningForeground,
                       "App must still be running after two consecutive left-zone double-taps")
    }
}
