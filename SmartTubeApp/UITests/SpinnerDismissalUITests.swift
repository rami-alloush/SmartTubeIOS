import XCTest

// MARK: - SpinnerDismissalUITests
//
// Regression tests for task #92:
//   Three fallback paths in PlaybackViewModel+Fallback.swift previously omitted
//   `isLoading = false` in their `.readyToPlay` handlers, leaving the loading
//   spinner permanently visible and all player controls permanently disabled.
//
// Fix: added `self.isLoading = false` after `self.loadAudioTracks(from:)` in:
//   • Android client fallback (~line 61)
//   • Adaptive composition fallback (~line 167)
//   • 403 recovery fallback (~line 242)
//
// Proof strategy:
//   The video Dy9ki9Q5nXs reliably triggers the Android client fallback on the
//   iOS Simulator because iOS HLS manifest URLs are IP-bound and the simulator's
//   AVPlayer download IP differs from the URLSession IP.  This is the same video
//   used by VideoPlaybackRegressionUITests.
//
//   After opening the player via deeplink we poll for `player.playPauseButton`
//   to become enabled within 30 s.  The button is wrapped in `.disabled(vm.isLoading)`,
//   so `isEnabled == true` is the exact, one-to-one signal that the
//   `isLoading = false` line executed in the fallback `.readyToPlay` handler.
//
//   A secondary assertion checks the button is hittable (i.e. not covered or at
//   zero opacity), confirming the controls overlay is fully interactive.
//
//   These tests must be run multiple times to confirm the fix is not flaky.

final class SpinnerDismissalUITests: XCTestCase {

    // The video ID that reliably triggers the Android client fallback on the
    // iOS Simulator.  Chosen because the primary iOS HLS path returns 404 due
    // to IP-binding (see VideoPlaybackRegressionUITests for full explanation).
    private static let fallbackVideoID = "Dy9ki9Q5nXs"

    private var app: XCUIApplication!

    // MARK: - Lifecycle

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = [
            "--uitesting",
            "--uitesting-deeplink-video=\(Self.fallbackVideoID)"
        ]
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - Helpers

    private var playPauseButton: XCUIElement {
        app.buttons["player.playPauseButton"].firstMatch
    }

    private var titleLabel: XCUIElement {
        app.staticTexts["player.titleLabel"].firstMatch
    }

    /// Taps the player surface to reveal the controls overlay.
    /// Retries up to 6 times with 1.5 s gaps to account for tap-gesture-recogniser
    /// setup timing and the UIKit `require(toFail: pan)` delay.
    private func showControls() {
        for _ in 0..<6 {
            if playPauseButton.exists { return }
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            Thread.sleep(forTimeInterval: 1.5)
        }
    }

    /// Polls `playPauseButton.isEnabled` until it becomes true or `timeout` elapses.
    /// Returns `true` if the button became enabled within the deadline.
    private func waitForPlayPauseEnabled(timeout: TimeInterval = 30) -> Bool {
        let enabledPredicate = NSPredicate(format: "enabled == true")
        let expectation = XCTNSPredicateExpectation(predicate: enabledPredicate,
                                                    object: playPauseButton)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    // MARK: - Tests

    /// Core #92 regression:
    /// `player.playPauseButton` must become enabled within 30 s of the player
    /// opening.  The button is `.disabled(vm.isLoading)`, so enabled == true
    /// proves `isLoading` was set to false in the fallback `.readyToPlay` handler.
    func testPlayPauseButtonBecomesEnabledAfterFallbackPath() throws {
        guard titleLabel.waitForExistence(timeout: 20) else {
            throw XCTSkip("player.titleLabel did not appear — network unavailable or deeplink did not fire")
        }

        // Show controls once so the element is in the accessibility tree.
        showControls()

        guard waitForPlayPauseEnabled(timeout: 30) else {
            XCTFail(
                "player.playPauseButton remained disabled 30 s after the player opened. " +
                "This indicates vm.isLoading was never set to false — regression of task #92. " +
                "Video: \(Self.fallbackVideoID)"
            )
            return
        }

        // Confirm the button is also hittable (opacity == 1.0, not obscured).
        XCTAssertTrue(
            playPauseButton.isHittable,
            "player.playPauseButton is enabled but not hittable — controls may be at 30% opacity (isLoading still true in UI). " +
            "Video: \(Self.fallbackVideoID)"
        )
    }

    /// Proves the fix is end-to-end: after the fallback path completes, the
    /// play/pause button must physically respond to a tap without crashing.
    func testPlayPauseButtonIsInteractableAfterFallbackPath() throws {
        guard titleLabel.waitForExistence(timeout: 20) else {
            throw XCTSkip("player.titleLabel did not appear — network unavailable or deeplink did not fire")
        }

        // Wait for the fallback path to complete (isLoading → false).
        showControls()
        guard waitForPlayPauseEnabled(timeout: 30) else {
            throw XCTSkip("player.playPauseButton did not become enabled within 30 s — network slow or fallback stalled")
        }

        // Tap the button — it must not crash and the app must still be running.
        playPauseButton.tap()
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(app.state, .runningForeground,
                       "App must still be running after tapping play/pause following the Android fallback")

        // Re-show controls and tap again to restore original state.
        showControls()
        if playPauseButton.waitForExistence(timeout: 5) {
            playPauseButton.tap()
        }
        XCTAssertEqual(app.state, .runningForeground,
                       "App must still be running after second play/pause tap")
    }

    /// Confirms no persistent loading spinner is present after fallback playback
    /// starts.  The ProgressView is rendered as an activity indicator in the
    /// accessibility tree; after `isLoading = false` it is removed from the hierarchy.
    func testNoLoadingSpinnerAfterFallbackPlaybackStarts() throws {
        guard titleLabel.waitForExistence(timeout: 20) else {
            throw XCTSkip("player.titleLabel did not appear — network unavailable or deeplink did not fire")
        }

        // Wait for the fallback path to complete (isLoading → false).
        showControls()
        guard waitForPlayPauseEnabled(timeout: 30) else {
            throw XCTSkip("player.playPauseButton did not become enabled — cannot assess spinner state")
        }

        // Give the transition animation 0.3 s (easeInOut 0.2 s + margin) to complete.
        Thread.sleep(forTimeInterval: 0.3)

        // The ProgressView (.circular) is the only activity indicator in the player.
        // After isLoading = false it is removed from SwiftUI's view tree entirely.
        // Note: the system status-bar network indicator is a separate element type and
        // does not appear as activityIndicators in XCTest on modern iOS.
        let spinners = app.activityIndicators
        XCTAssertEqual(spinners.count, 0,
                       "Expected 0 activity indicators after fallback playback starts, found \(spinners.count). " +
                       "The loading spinner may still be present — regression of task #92.")
    }

    /// Confirms no error banner appeared during the fallback playback session.
    /// Paired with the spinner tests to give a complete picture of the fallback path.
    func testNoErrorBannerDuringFallbackPlayback() throws {
        guard titleLabel.waitForExistence(timeout: 20) else {
            throw XCTSkip("player.titleLabel did not appear — network unavailable or deeplink did not fire")
        }

        showControls()
        _ = waitForPlayPauseEnabled(timeout: 30)

        UITestHelpers.assertNoPlayerErrorBanner(in: app, videoTitle: Self.fallbackVideoID)
    }
}
