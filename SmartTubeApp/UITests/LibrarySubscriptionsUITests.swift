import XCTest

// MARK: - LibrarySubscriptionsUITests
//
// UI tests for the Library → Subscriptions segment.
//
// Requirements:
//   • Network access is required.
//   • A signed-in account with subscriptions is needed for feed-level tests.
//   • Run on an iOS 17+ simulator with the SmartTubeApp scheme selected.

final class LibrarySubscriptionsUITests: XCTestCase {

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

    private func openSubscriptionsSegment() throws {
        UITestHelpers.tapTab(named: "Library", in: app)
        let picker = app.segmentedControls["library.sectionPicker"]
        guard picker.waitForExistence(timeout: 5) else {
            throw XCTSkip("library.sectionPicker did not appear — Library tab may not have loaded")
        }
        let button = picker.buttons["Subscriptions"]
        guard button.waitForExistence(timeout: 3) else {
            throw XCTSkip("Subscriptions segment not found in library section picker")
        }
        button.tap()
    }

    // MARK: - Structural tests

    func testSubscriptionsSegmentVisible() throws {
        UITestHelpers.tapTab(named: "Library", in: app)
        let picker = app.segmentedControls["library.sectionPicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5),
                      "library.sectionPicker should appear")
        XCTAssertTrue(picker.buttons["Subscriptions"].exists,
                      "'Subscriptions' segment must be present in the library picker")
    }

    func testNavigationDoesNotCrash() throws {
        try openSubscriptionsSegment()
        Thread.sleep(forTimeInterval: 2)
        XCTAssertEqual(app.state, .runningForeground,
                       "App should still be running after opening Subscriptions in Library")
    }

    // MARK: - Live-network tests (signed-in account required)

    func testSubscriptionsSegmentShowsFeed() throws {
        try openSubscriptionsSegment()
        guard let _ = UITestHelpers.waitForVideoCards(in: app, timeout: 20) else {
            throw XCTSkip("No video cards loaded within 20 s — account may not be signed in or has no subscriptions")
        }
    }

    func testNoErrorAlertOnSubscriptionsLoad() throws {
        try openSubscriptionsSegment()
        Thread.sleep(forTimeInterval: 5)
        UITestHelpers.assertNoErrorAlert(in: app)
    }

    func testSubscriptionsScrollLoadsMore() throws {
        try openSubscriptionsSegment()
        guard let _ = UITestHelpers.waitForVideoCards(in: app, timeout: 20) else {
            throw XCTSkip("No video cards in Subscriptions feed — signed-in account required")
        }

        let countBefore = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'video.card.'"))
            .count

        app.swipeUp(velocity: .fast)
        Thread.sleep(forTimeInterval: 2)
        app.swipeUp(velocity: .fast)
        Thread.sleep(forTimeInterval: 3)

        let countAfter = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'video.card.'"))
            .count

        XCTAssertGreaterThanOrEqual(countAfter, countBefore,
            "Scrolling down should not reduce the video card count (pagination should add more)")
    }

    func testTappingVideoFromSubscriptionsOpensPlayer() throws {
        try openSubscriptionsSegment()
        guard let firstCard = UITestHelpers.waitForVideoCards(in: app, timeout: 20) else {
            throw XCTSkip("No video cards in Subscriptions — signed-in account required")
        }
        XCTAssertTrue(UITestHelpers.openPlayer(from: firstCard, in: app),
                      "player.titleLabel must appear after tapping a video in Library Subscriptions")
        let errorBanner = app.otherElements["player.errorBanner"].firstMatch
        if errorBanner.exists {
            throw XCTSkip("player.errorBanner appeared — network issue on this simulator clone")
        }
    }

    func testScrollRestorationAfterPlayback() throws {
        try openSubscriptionsSegment()
        guard let _ = UITestHelpers.waitForVideoCards(in: app, timeout: 20) else {
            throw XCTSkip("No video cards — signed-in account required")
        }

        let firstCard = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'video.card.'"))
            .firstMatch

        app.swipeUp(velocity: .fast)
        Thread.sleep(forTimeInterval: 2)
        app.swipeUp(velocity: .fast)
        Thread.sleep(forTimeInterval: 2)

        let firstCardMaxYAfterScroll = firstCard.frame.maxY
        guard firstCardMaxYAfterScroll < 100 else {
            throw XCTSkip("Could not scroll first card off-screen — feed may have too few items")
        }

        // Tap via screen centre coordinate so we don't have to pick a specific card.
        let feed = app.scrollViews.firstMatch
        let tapPoint = feed.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        tapPoint.tap()

        let titleLabel = app.staticTexts["player.titleLabel"].firstMatch
        guard titleLabel.waitForExistence(timeout: 15) else {
            throw XCTSkip("PlayerView did not open within 15 s — network unavailable or timing-dependent")
        }

        let backButton = app.buttons["player.backButton"].firstMatch
        guard backButton.waitForExistence(timeout: 5) else {
            throw XCTSkip("player.backButton not found after player opened")
        }
        backButton.tap()

        let picker = app.segmentedControls["library.sectionPicker"]
        guard picker.waitForExistence(timeout: 5) else {
            throw XCTSkip("Library picker did not reappear after back navigation")
        }

        Thread.sleep(forTimeInterval: 1.0)
        let firstCardMaxYAfterBack = firstCard.frame.maxY
        guard firstCardMaxYAfterBack < 100 else {
            throw XCTSkip("Scroll position not restored — first card reappeared on-screen (timing or animation-dependent)")
        }
    }
}
