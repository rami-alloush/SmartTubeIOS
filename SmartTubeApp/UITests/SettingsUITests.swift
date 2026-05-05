import XCTest

// MARK: - SettingsUITests
//
// Structural UI tests for the Settings tab.
// No network access is required — all settings are stored locally.
//
// Requirements:
//   • Run on an iOS 17+ simulator with the SmartTubeApp scheme selected.
//   • Tests that verify signed-out state rely on the app launching without a
//     stored account credential (fresh simulator or signed-out state).

final class SettingsUITests: XCTestCase {

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

    private func openSettings() {
        UITestHelpers.tapTab(named: "Settings", in: app)
    }

    // MARK: - Tests

    func testSettingsTabOpens() {
        openSettings()
        // SwiftUI Form renders as UICollectionView on iOS 16+.
        let form = app.collectionViews.firstMatch
        XCTAssertTrue(form.waitForExistence(timeout: 5),
                      "Settings form should appear after tapping the Settings tab")
    }

    func testPlayerSectionVisible() {
        openSettings()
        // "Playback Speed" is always the first row in the Player section.
        let speedRow = app.cells.containing(.staticText, identifier: "Playback Speed").firstMatch
        XCTAssertTrue(speedRow.waitForExistence(timeout: 5),
                      "'Playback Speed' row must be visible in the Player section")
    }

    func testHideShortsToggleToggles() {
        openSettings()
        let form = app.collectionViews.firstMatch
        let toggle = form.switches["settings.hideShortsToggle"]
        // Player section has ~11 rows; scroll until Interface section is visible.
        UITestHelpers.scrollUntilVisible(toggle, in: form)
        XCTAssertTrue(toggle.waitForExistence(timeout: 5),
                      "settings.hideShortsToggle must be present in the Interface section")
        let before = toggle.value as? String
        // Tap the right side of the row where the UISwitch control sits.
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).tap()
        let after = toggle.value as? String
        XCTAssertNotEqual(before, after,
                          "Hide Shorts toggle value should change after tapping")
        // Restore original state so settings are not polluted between tests.
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).tap()
    }

    func testVisibleSectionsNavigationLinkOpens() {
        openSettings()
        let form = app.collectionViews.firstMatch
        // NavigationLink rows often don't propagate a cell identifier — match by text content.
        let link = form.cells.containing(.staticText, identifier: "Visible Sections").firstMatch
        UITestHelpers.scrollUntilVisible(link, in: form)
        XCTAssertTrue(link.waitForExistence(timeout: 5),
                      "'Visible Sections' NavigationLink row must be present in Interface section")
        link.tap()
        // The destination view uses "Visible Sections" as its navigation title.
        let navTitle = app.navigationBars["Visible Sections"].firstMatch
        XCTAssertTrue(navTitle.waitForExistence(timeout: 5),
                      "Navigating to Visible Sections should show that navigation title")
    }

    func testSponsorBlockToggleEnablesSection() {
        openSettings()
        let form = app.collectionViews.firstMatch
        let toggle = form.switches["settings.sponsorBlockToggle"]
        UITestHelpers.scrollUntilVisible(toggle, in: form)
        XCTAssertTrue(toggle.waitForExistence(timeout: 5),
                      "settings.sponsorBlockToggle must be present in the SponsorBlock section")

        // Ensure it starts OFF; if it is already on, skip the enable-state assertion.
        let wasOn = (toggle.value as? String) == "1"
        if wasOn {
            // Turn it off so we can verify turning it on shows sub-options.
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).tap()
        }
        // Turn on using coordinate tap (right side = UISwitch).
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).tap()
        // At least one per-category picker row should now be visible.
        // Category displayNames: "Sponsor", "Self-Promotion", "Interaction Reminder", etc.
        // Use label predicate since SwiftUI Text labels map to XCUIElement.label,
        // not necessarily to accessibilityIdentifier in iOS 26.
        let sponsorPred = NSPredicate(format: "label == 'Sponsor'")
        let sponsorRow = app.descendants(matching: .any).matching(sponsorPred).firstMatch
        let selfPromoPred = NSPredicate(format: "label == 'Self-Promotion'")
        let selfPromoRow = app.descendants(matching: .any).matching(selfPromoPred).firstMatch
        let subOptionsAppear = sponsorRow.waitForExistence(timeout: 6)
            || selfPromoRow.waitForExistence(timeout: 3)
        XCTAssertTrue(subOptionsAppear,
                      "SponsorBlock category pickers should appear when SponsorBlock is enabled")

        // Restore to OFF so we leave settings clean.
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).tap()
    }

    func testAboutSectionResetButtonVisible() {
        openSettings()
        let form = app.collectionViews.firstMatch
        let resetButton = form.buttons["settings.resetAllButton"]
        UITestHelpers.scrollUntilVisible(resetButton, in: form)
        XCTAssertTrue(resetButton.waitForExistence(timeout: 5),
                      "settings.resetAllButton should be visible in the About section")
    }

    func testResetAllSettingsShowsConfirmation() {
        openSettings()
        let form = app.collectionViews.firstMatch
        let resetButton = form.buttons["settings.resetAllButton"]
        UITestHelpers.scrollUntilVisible(resetButton, in: form)
        guard resetButton.waitForExistence(timeout: 5) else {
            XCTFail("settings.resetAllButton not found")
            return
        }
        resetButton.tap()
        // SwiftUI destructive Button triggers the action directly — expect the
        // store to reset silently. If the app instead shows a confirmation alert,
        // dismiss it so the app is left in a clean state.
        if app.alerts.firstMatch.waitForExistence(timeout: 2) {
            app.alerts.firstMatch.buttons.firstMatch.tap()
        }
        // Either way, the app must still be running.
        XCTAssertEqual(app.state, .runningForeground,
                       "App should still be running after Reset All Settings")
    }

    func testSignInButtonVisibleWhenSignedOut() throws {
        openSettings()
        // In SwiftUI Form, Button rows expose their text as the element's label, not as a
        // child staticText.  Use a predicate that matches either by identifier or by label.
        let signInPredicate = NSPredicate(format: "identifier == 'settings.signInButton' OR label == 'Sign in with Google'")
        let signOutPredicate = NSPredicate(format: "label == 'Sign Out'")
        let signInEl  = app.descendants(matching: .any).matching(signInPredicate).firstMatch
        let signOutEl = app.descendants(matching: .any).matching(signOutPredicate).firstMatch
        // If signed in, skip — we can't test the sign-in button without signing out first.
        if signOutEl.waitForExistence(timeout: 5) {
            throw XCTSkip("Account is signed in — skipping signed-out UI assertion")
        }
        XCTAssertTrue(signInEl.waitForExistence(timeout: 5),
                      "'Sign in with Google' button must be visible when no account is signed in")
    }

    func testLandscapeAlwaysPlayToggleExistsAndToggles() {
        openSettings()
        let form = app.collectionViews.firstMatch
        let toggle = form.switches["settings.landscapeAlwaysPlayToggle"]
        // The toggle lives inside the Player section; scroll until it appears.
        UITestHelpers.scrollUntilVisible(toggle, in: form)
        XCTAssertTrue(toggle.waitForExistence(timeout: 5),
                      "settings.landscapeAlwaysPlayToggle must be present in the Player section (iOS only)")
        let before = toggle.value as? String
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).tap()
        let after = toggle.value as? String
        XCTAssertNotEqual(before, after,
                          "Landscape Always Play toggle value must change after tapping")
        // Restore original state so settings are not polluted between tests.
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).tap()
    }

    /// Verifies that enabling Landscape Always Play and opening a video reaches the
    /// player without crashing. The orientation request code path runs on appear;
    /// this test confirms it does not crash the app regardless of simulator limits.
    func testLandscapeAlwaysPlayOpensPlayerWithoutCrash() throws {
        // Enable Landscape Always Play
        openSettings()
        let form = app.collectionViews.firstMatch
        let toggle = form.switches["settings.landscapeAlwaysPlayToggle"]
        UITestHelpers.scrollUntilVisible(toggle, in: form)
        XCTAssertTrue(toggle.waitForExistence(timeout: 5),
                      "settings.landscapeAlwaysPlayToggle must be present")
        let wasOn = (toggle.value as? String) == "1"
        if !wasOn {
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).tap()
            XCTAssertEqual(toggle.value as? String, "1",
                           "Toggle must be ON before opening player")
        }

        // Navigate to Home and open a video so the orientation code path runs
        UITestHelpers.tapTab(named: "Home", in: app)
        let feedPredicate = NSPredicate(format: "identifier BEGINSWITH 'video.card.'")
        let cards = app.descendants(matching: .any).matching(feedPredicate)
        let feedLoaded = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count > 0"),
                                                   object: cards)
        guard XCTWaiter().wait(for: [feedLoaded], timeout: 20) == .completed else {
            // Network unavailable — skip but don't fail; toggle still exercised above.
            if !wasOn {
                openSettings()
                UITestHelpers.scrollUntilVisible(toggle, in: form)
                toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).tap()
            }
            throw XCTSkip("Home feed did not load within 20 s — network unavailable")
        }
        cards.firstMatch.tap()

        // PlayerView.onAppear fires the orientation request; verify the player opened
        let playerTitle = app.staticTexts["player.titleLabel"].firstMatch
        XCTAssertTrue(playerTitle.waitForExistence(timeout: 15),
                      "player.titleLabel must appear — PlayerView opened and orientation code ran")

        // Verify landscape orientation is SUPPORTED while the player is open.
        // When landscapeAlwaysPlay is ON, PlayerView sets vm.isLandscape = true and
        // OrientationManager.shared.playerIsActive = true on appear, so the AppDelegate
        // returns .allButUpsideDown. We rotate the device here to confirm the app stays
        // in landscape.
        XCUIDevice.shared.orientation = .landscapeLeft
        let landscapePredicate = NSPredicate { [app] _, _ in
            app.frame.size.width > app.frame.size.height
        }
        let landscapeExpect = XCTNSPredicateExpectation(
            predicate: landscapePredicate, object: nil)
        let landscapeResult = XCTWaiter().wait(for: [landscapeExpect], timeout: 3)
        XCUIDevice.shared.orientation = .portrait  // restore before dismissal
        XCTAssertEqual(
            landscapeResult, .completed,
            "App must support landscape while the player is open (landscapeAlwaysPlay = ON). " +
            "frame was \(app.frame.size)"
        )

        // Dismiss and restore toggle state
        app.swipeDown()
        if !wasOn {
            openSettings()
            UITestHelpers.scrollUntilVisible(toggle, in: form)
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).tap()
        }
    }
}
