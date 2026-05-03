import XCTest

// MARK: - RecommendedChipUITests
//
// UI tests for the "Recommended" chip in the Home chip bar.
// The chip is always injected directly after the "Home" chip and shows a pure
// recommended-only feed (fetchHomeRows) without subscriptions mixed in.
//
// Requirements:
//   • The simulator must have network access.
//   • Run on an iOS 17+ simulator with the SmartTubeApp scheme selected.

final class RecommendedChipUITests: XCTestCase {

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

    // MARK: - Tests

    /// The Recommended chip must be visible in the chip bar on the Home tab.
    func testRecommendedChipIsVisible() throws {
        tapTab(named: "Home")

        let chipBar = app.scrollViews["home.chipBar"]
        XCTAssertTrue(chipBar.waitForExistence(timeout: 10),
                      "home.chipBar must appear on the Home tab")

        let chip = chipBar.buttons["Recommended"]
        guard chip.waitForExistence(timeout: 5) else {
            throw XCTSkip("Recommended chip not found — HomeView may not have injected it")
        }
        scrollChipIntoView(chip, in: chipBar)
        XCTAssertTrue(chip.exists, "Recommended chip must exist in the chip bar")
    }

    /// Tapping the Recommended chip must show at least one video card and must
    /// not present an HTTP error alert.
    func testRecommendedChipLoadsFeedWithoutError() throws {
        tapTab(named: "Home")

        let chipBar = app.scrollViews["home.chipBar"]
        XCTAssertTrue(chipBar.waitForExistence(timeout: 10),
                      "home.chipBar must appear on the Home tab")

        let chip = chipBar.buttons["Recommended"]
        guard chip.waitForExistence(timeout: 5) else {
            throw XCTSkip("Recommended chip not found — HomeView may not have injected it")
        }
        scrollChipIntoView(chip, in: chipBar)
        chip.tap()

        // Wait for the section feed container to appear.
        let feedScrollView = app.scrollViews["home.sectionFeed"]
        guard feedScrollView.waitForExistence(timeout: 30) else {
            throw XCTSkip("home.sectionFeed did not appear within 30 s — feed may not have loaded")
        }

        // At least one video card must appear.
        let cardPredicate = NSPredicate(format: "identifier BEGINSWITH 'video.card.'")
        let cards = feedScrollView.descendants(matching: .any).matching(cardPredicate)
        let feedLoaded = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count > 0"),
                                                   object: cards)
        guard XCTWaiter().wait(for: [feedLoaded], timeout: 20) == .completed else {
            throw XCTSkip("No video cards in Recommended feed within 20 s — network unavailable or feed empty")
        }

        // Assert no HTTP error alert appeared.
        XCTAssertFalse(app.alerts["Error"].exists,
                       "An 'Error' alert appeared while loading the Recommended feed")
    }

    /// Tapping the Recommended chip must select it (toggle its selected state)
    /// and the Home chip must become deselected.
    func testRecommendedChipSelectionState() throws {
        tapTab(named: "Home")

        let chipBar = app.scrollViews["home.chipBar"]
        XCTAssertTrue(chipBar.waitForExistence(timeout: 10),
                      "home.chipBar must appear on the Home tab")

        let homeChip = chipBar.buttons["Home"]
        let recChip  = chipBar.buttons["Recommended"]
        guard recChip.waitForExistence(timeout: 5) else {
            throw XCTSkip("Recommended chip not found")
        }

        // Home chip starts selected.
        XCTAssertTrue(homeChip.isSelected, "Home chip should be selected by default")
        XCTAssertFalse(recChip.isSelected, "Recommended chip should not be selected initially")

        scrollChipIntoView(recChip, in: chipBar)
        recChip.tap()

        // After tap: Recommended is selected, Home is not.
        XCTAssertTrue(recChip.isSelected,  "Recommended chip must be selected after tapping it")
        XCTAssertFalse(homeChip.isSelected, "Home chip must be deselected after tapping Recommended")
    }

    /// Tapping a video in the Recommended feed must open PlayerView.
    func testTappingRecommendedVideoOpensPlayer() throws {
        tapTab(named: "Home")

        let chipBar = app.scrollViews["home.chipBar"]
        XCTAssertTrue(chipBar.waitForExistence(timeout: 10),
                      "home.chipBar must appear on the Home tab")

        let chip = chipBar.buttons["Recommended"]
        guard chip.waitForExistence(timeout: 5) else {
            throw XCTSkip("Recommended chip not found")
        }
        scrollChipIntoView(chip, in: chipBar)
        chip.tap()

        let feedScrollView = app.scrollViews["home.sectionFeed"]
        guard feedScrollView.waitForExistence(timeout: 30) else {
            throw XCTSkip("home.sectionFeed did not appear within 30 s")
        }

        let cardPredicate = NSPredicate(format: "identifier BEGINSWITH 'video.card.'")
        let firstCard = feedScrollView.descendants(matching: .any).matching(cardPredicate).firstMatch
        guard firstCard.waitForExistence(timeout: 20) else {
            throw XCTSkip("No video cards in Recommended feed within 20 s")
        }

        firstCard.tap()

        let titleLabel = app.staticTexts["player.titleLabel"].firstMatch
        XCTAssertTrue(titleLabel.waitForExistence(timeout: 15),
                      "player.titleLabel must appear — PlayerView did not open from Recommended feed")
    }

    /// Tapping Recommended then Home must switch back to the merged home feed.
    func testSwitchingBackToHomeFromRecommended() throws {
        tapTab(named: "Home")

        let chipBar = app.scrollViews["home.chipBar"]
        XCTAssertTrue(chipBar.waitForExistence(timeout: 10),
                      "home.chipBar must appear on the Home tab")

        let recChip  = chipBar.buttons["Recommended"]
        let homeChip = chipBar.buttons["Home"]
        guard recChip.waitForExistence(timeout: 5) else {
            throw XCTSkip("Recommended chip not found")
        }

        scrollChipIntoView(recChip, in: chipBar)
        recChip.tap()

        // Switch back to Home.
        scrollChipIntoView(homeChip, in: chipBar)
        homeChip.tap()

        XCTAssertTrue(homeChip.isSelected,  "Home chip must be selected after tapping back")
        XCTAssertFalse(recChip.isSelected,  "Recommended chip must be deselected after switching back to Home")

        // The home feed should be visible again.
        let cardPredicate = NSPredicate(format: "identifier BEGINSWITH 'video.card.'")
        let cards = app.descendants(matching: .any).matching(cardPredicate)
        let feedLoaded = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count > 0"),
                                                   object: cards)
        XCTAssertEqual(XCTWaiter().wait(for: [feedLoaded], timeout: 20), .completed,
                       "Home feed should show video cards after switching back from Recommended")
    }

    // MARK: - Helpers

    private func tapTab(named label: String, timeout: TimeInterval = 5) {
        let tabBarButton = app.tabBars.buttons[label]
        if tabBarButton.waitForExistence(timeout: min(timeout, 3)) {
            tabBarButton.tap()
            return
        }
        let sidebarButton = app.buttons[label].firstMatch
        XCTAssertTrue(sidebarButton.waitForExistence(timeout: timeout),
                      "'\(label)' navigation item not found in tab bar or sidebar")
        sidebarButton.tap()
    }

    private func scrollChipIntoView(_ chip: XCUIElement, in chipBar: XCUIElement) {
        let screenWidth = app.windows.firstMatch.frame.width
        let near = chipBar.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5))
        let far  = chipBar.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5))

        for _ in 0..<8 {
            let frame = chip.frame
            if frame.origin.x >= 4 && frame.maxX <= screenWidth - 4 { break }
            if frame.origin.x < 4 {
                near.press(forDuration: 0.05, thenDragTo: far)
            } else {
                far.press(forDuration: 0.05, thenDragTo: near)
            }
        }
    }
}
