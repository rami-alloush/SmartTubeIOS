import XCTest

/// Regression tests for task #217: Quality and Audio Track rows must not appear
/// in the overflow ("…") menu when the fullscreen quick-access pills are already
/// visible below the scrubber (`vm.controlsVisible == true`).
///
/// When controls are hidden the rows must reappear so the user always has access.
final class PlayerMoreMenuDuplicationUITests: XCTestCase {

    // MARK: - Helpers

    private func launchApp(showControls: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        var args: [String] = [
            "--uitesting",
            "--uitesting-deeplink-video=dQw4w9WgXcQ",
            "--uitesting-open-more-menu"
        ]
        if showControls { args.append("--uitesting-show-controls") }
        app.launchArguments = args
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        return app
    }

    // MARK: - Tests

    /// When pills are visible (`controlsVisible == true`) the Quality row must
    /// not appear in the overflow menu — it is already accessible via the pill.
    func testQualityRowAbsentFromMoreMenuWhenControlsVisible() throws {
        let app = launchApp(showControls: true)
        defer { app.terminate() }

        let menu = app.scrollViews["player.moreMenu.scrollView"].firstMatch
        guard menu.waitForExistence(timeout: 20) else {
            try captureAndSkip("More menu did not appear — network unavailable or video inaccessible", in: app)
        }

        // Give the menu a moment to fully render all rows.
        _ = app.buttons["player.moreMenu.cancel"].firstMatch.waitForExistence(timeout: 5)

        XCTAssertFalse(
            app.buttons["player.moreMenu.qualityRow"].firstMatch.exists,
            "Quality row must NOT appear in the overflow menu when fullscreen pills are visible (task #217)"
        )
    }

    /// When controls are hidden (`controlsVisible == false`) the Quality row
    /// must appear in the overflow menu so the user can still access quality settings.
    func testQualityRowPresentInMoreMenuWhenControlsHidden() throws {
        let app = launchApp(showControls: false)
        defer { app.terminate() }

        let menu = app.scrollViews["player.moreMenu.scrollView"].firstMatch
        guard menu.waitForExistence(timeout: 20) else {
            try captureAndSkip("More menu did not appear — network unavailable or video inaccessible", in: app)
        }

        // Give the menu a moment to fully render all rows.
        _ = app.buttons["player.moreMenu.cancel"].firstMatch.waitForExistence(timeout: 5)

        // Quality row must be present when controls are hidden (no pills visible).
        XCTAssertTrue(
            app.buttons["player.moreMenu.qualityRow"].firstMatch.waitForExistence(timeout: 5),
            "Quality row must appear in the overflow menu when fullscreen pills are hidden (task #217)"
        )
    }
}
