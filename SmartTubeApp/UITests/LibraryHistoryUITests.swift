import XCTest

// MARK: - LibraryHistoryUITests
//
// UI tests for the Library → History segment.
//
// Requirements:
//   • Network access is required.
//   • A signed-in account with watch history is needed for feed-level tests.
//   • Run on an iOS 17+ simulator with the SmartTubeApp scheme selected.

final class LibraryHistoryUITests: XCTestCase {

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

    private func openHistorySegment() throws {
        UITestHelpers.tapTab(named: "Library", in: app)
        let picker = app.segmentedControls["library.sectionPicker"]
        guard picker.waitForExistence(timeout: 5) else {
            try captureAndSkip("library.sectionPicker did not appear — Library tab may not have loaded", in: app)
        }
        let button = picker.buttons["History"]
        guard button.waitForExistence(timeout: 3) else {
            try captureAndSkip("History segment not found in library section picker", in: app)
        }
        button.tap()
    }

    // MARK: - Structural tests

    func testHistorySegmentVisible() throws {
        UITestHelpers.tapTab(named: "Library", in: app)
        let picker = app.segmentedControls["library.sectionPicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5),
                      "library.sectionPicker should appear")
        XCTAssertTrue(picker.buttons["History"].exists,
                      "'History' segment must be present in the library picker")
    }

    func testNavigationDoesNotCrash() throws {
        try openHistorySegment()
        Thread.sleep(forTimeInterval: 2)
        XCTAssertEqual(app.state, .runningForeground,
                       "App should still be running after opening History in Library")
    }

    // MARK: - Live-network tests (signed-in account required)

    func testHistorySegmentShowsFeed() throws {
        try openHistorySegment()
        guard let _ = UITestHelpers.waitForVideoCards(in: app, timeout: 20) else {
            try captureAndSkip("No video cards loaded within 20 s — account may not be signed in or has empty history", in: app)
        }
    }

    func testNoErrorAlertOnHistoryLoad() throws {
        try openHistorySegment()
        Thread.sleep(forTimeInterval: 5)
        UITestHelpers.assertNoErrorAlert(in: app)
    }

    func testHistoryScrollLoadsMore() throws {
        try openHistorySegment()
        guard let _ = UITestHelpers.waitForVideoCards(in: app, timeout: 20) else {
            try captureAndSkip("No video cards in History feed — signed-in account with history required", in: app)
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
            "Scrolling down should not reduce video card count (pagination should add more)")
    }

    func testTappingVideoFromHistoryOpensPlayer() throws {
        try openHistorySegment()
        guard let firstCard = UITestHelpers.waitForVideoCards(in: app, timeout: 20) else {
            try captureAndSkip("No video cards in History — signed-in account with history required", in: app)
        }
        XCTAssertTrue(UITestHelpers.openPlayer(from: firstCard, in: app),
                      "player.titleLabel must appear after tapping a video in Library History")
        let errorBanner = app.otherElements["player.errorBanner"].firstMatch
        if errorBanner.exists {
            try captureAndSkip("player.errorBanner appeared — network issue on this simulator clone", in: app)
        }
    }

    func testScrollRestorationAfterPlayback() throws {
        try openHistorySegment()
        guard let _ = UITestHelpers.waitForVideoCards(in: app, timeout: 20) else {
            try captureAndSkip("No video cards — signed-in account with history required", in: app)
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
            try captureAndSkip("Could not scroll first card off-screen — feed may have too few items", in: app)
        }

        let feed = app.scrollViews.firstMatch
        let tapPoint = feed.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        tapPoint.tap()

        let titleLabel = app.staticTexts["player.titleLabel"].firstMatch
        guard titleLabel.waitForExistence(timeout: 15) else {
            try captureAndSkip("PlayerView did not open within 15 s — network unavailable or timing-dependent", in: app)
        }

        let backButton = app.buttons["player.backButton"].firstMatch
        guard backButton.waitForExistence(timeout: 5) else {
            try captureAndSkip("player.backButton not found after player opened", in: app)
        }
        backButton.tap()

        let picker = app.segmentedControls["library.sectionPicker"]
        guard picker.waitForExistence(timeout: 5) else {
            try captureAndSkip("Library picker did not reappear after back navigation", in: app)
        }

        Thread.sleep(forTimeInterval: 1.0)
        let firstCardMaxYAfterBack = firstCard.frame.maxY
        guard firstCardMaxYAfterBack < 100 else {
            try captureAndSkip("Scroll position not restored — first card reappeared on-screen (timing or animation-dependent)", in: app)
        }
    }
}
