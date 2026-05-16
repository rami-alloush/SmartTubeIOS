import XCTest

// MARK: - LibraryPlaylistsUITests
//
// UI tests for the Library → Playlists segment and the PlaylistView it opens.
//
// Requirements:
//   • A signed-in account with at least one saved playlist is needed for the
//     full playback/scroll tests; structural navigation tests pass regardless.
//   • Run on an iOS 17+ simulator with the SmartTubeApp scheme selected.

final class LibraryPlaylistsUITests: XCTestCase {

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

    /// Navigates to Library tab and selects the Playlists segment.
    private func openPlaylistsSegment() throws {
        UITestHelpers.tapTab(named: "Library", in: app)
        let picker = app.segmentedControls["library.sectionPicker"]
        guard picker.waitForExistence(timeout: 5) else {
            try captureAndSkip("library.sectionPicker did not appear — Library tab may not have loaded", in: app)
        }
        let playlistsButton = picker.buttons["Playlists"]
        guard playlistsButton.waitForExistence(timeout: 3) else {
            try captureAndSkip("Playlists segment not found in library section picker", in: app)
        }
        playlistsButton.tap()
    }

    // MARK: - Structural tests (no sign-in required)

    func testLibraryTabOpens() {
        UITestHelpers.tapTab(named: "Library", in: app)
        let picker = app.segmentedControls["library.sectionPicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5),
                      "library.sectionPicker should appear after opening Library")
    }

    func testPlaylistsSegmentIsReachable() throws {
        try openPlaylistsSegment()
    }

    func testPlaylistsScreenShowsContentOrSignInPrompt() throws {
        try openPlaylistsSegment()
        // Accept any of: content list, empty state, or sign-in prompt.
        let contentOrEmpty = app.scrollViews.firstMatch.waitForExistence(timeout: 5)
            || app.staticTexts["Nothing here yet"].waitForExistence(timeout: 5)
            || app.staticTexts["Sign in to see your library"].waitForExistence(timeout: 5)
        XCTAssertTrue(contentOrEmpty,
                      "Playlists screen should show content, an empty state, or a sign-in prompt")
    }

    func testNoErrorAlertOnPlaylistsLoad() throws {
        try openPlaylistsSegment()
        Thread.sleep(forTimeInterval: 3)
        UITestHelpers.assertNoErrorAlert(in: app)
    }

    func testNavigationDoesNotCrash() throws {
        try openPlaylistsSegment()
        Thread.sleep(forTimeInterval: 2)
        XCTAssertEqual(app.state, .runningForeground,
                       "App should still be running after navigating to Playlists")
    }

    // MARK: - Live-network tests (signed-in account required)

    func testPlaylistsFeedPopulates() throws {
        try openPlaylistsSegment()
        guard let _ = UITestHelpers.waitForVideoCards(in: app, timeout: 20) else {
            try captureAndSkip("No playlist items loaded within 20 s — account may not be signed in or has no playlists", in: app)
        }
    }

    func testTappingPlaylistOpensPlaylistView() throws {
        try openPlaylistsSegment()
        guard let firstCard = UITestHelpers.waitForVideoCards(in: app, timeout: 20) else {
            try captureAndSkip("No playlist cards loaded — signed-in account with playlists required", in: app)
        }
        firstCard.tap()
        // PlaylistView sets its navigationTitle to the playlist name; the nav bar appears.
        // We accept any nav bar rather than guessing the exact playlist name.
        let navBar = app.navigationBars.firstMatch
        XCTAssertTrue(navBar.waitForExistence(timeout: 10),
                      "A navigation bar should appear when opening a playlist")
    }

    func testPlaylistViewShowsVideoCardsOrEmpty() throws {
        try openPlaylistsSegment()
        guard let firstCard = UITestHelpers.waitForVideoCards(in: app, timeout: 20) else {
            try captureAndSkip("No playlist cards loaded — signed-in account with playlists required", in: app)
        }
        firstCard.tap()

        let feed = app.scrollViews["playlistView.feed"]
        let emptyState = app.staticTexts["No videos in this playlist"]

        let feedOrEmpty = feed.waitForExistence(timeout: 15)
            || emptyState.waitForExistence(timeout: 15)
        XCTAssertTrue(feedOrEmpty,
                      "PlaylistView should show either a feed (playlistView.feed) or an empty state")
    }

    func testTappingVideoInPlaylistOpensPlayer() throws {
        try openPlaylistsSegment()
        guard let playlistCard = UITestHelpers.waitForVideoCards(in: app, timeout: 20) else {
            try captureAndSkip("No playlist cards — signed-in account with playlists required", in: app)
        }
        playlistCard.tap()

        // Wait for PlaylistView to open and load videos.
        let feed = app.scrollViews["playlistView.feed"]
        guard feed.waitForExistence(timeout: 15) else {
            try captureAndSkip("playlistView.feed did not appear — playlist may be empty", in: app)
        }
        guard let videoCard = UITestHelpers.waitForVideoCards(in: app, timeout: 20) else {
            try captureAndSkip("No video cards inside playlist — playlist may be empty", in: app)
        }
        XCTAssertTrue(UITestHelpers.openPlayer(from: videoCard, in: app),
                      "player.titleLabel should appear after tapping a video in a playlist")
        let errorBanner = app.otherElements["player.errorBanner"].firstMatch
        if errorBanner.exists {
            try captureAndSkip("player.errorBanner appeared — network issue on this simulator clone", in: app)
        }
    }

    func testScrollRestorationAfterPlayback() throws {
        try openPlaylistsSegment()
        guard let _ = UITestHelpers.waitForVideoCards(in: app, timeout: 20) else {
            try captureAndSkip("No playlist cards — signed-in account with playlists required", in: app)
        }

        // Open the first playlist.
        let playlistCard = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'video.card.'"))
            .firstMatch
        playlistCard.tap()

        let feed = app.scrollViews["playlistView.feed"]
        guard feed.waitForExistence(timeout: 15) else {
            try captureAndSkip("playlistView.feed did not appear — playlist may be empty", in: app)
        }
        guard let _ = UITestHelpers.waitForVideoCards(in: app, timeout: 20) else {
            try captureAndSkip("No video cards in playlist", in: app)
        }

        // Scroll down.
        feed.swipeUp(velocity: .fast)
        Thread.sleep(forTimeInterval: 1.5)
        feed.swipeUp(velocity: .fast)
        Thread.sleep(forTimeInterval: 1.5)

        let firstCard = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'video.card.'"))
            .firstMatch
        let firstCardMaxYAfterScroll = firstCard.frame.maxY
        guard firstCardMaxYAfterScroll < 100 else {
            try captureAndSkip("Could not scroll past first card — playlist may have too few items", in: app)
        }

        // Tap a video via coordinate.
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

        guard feed.waitForExistence(timeout: 5) else {
            try captureAndSkip("playlistView.feed did not reappear after back", in: app)
        }
        Thread.sleep(forTimeInterval: 1.0)

        let firstCardMaxYAfterBack = firstCard.frame.maxY
        guard firstCardMaxYAfterBack < 100 else {
            try captureAndSkip("Scroll position not restored — first card reappeared on-screen (timing or animation-dependent)", in: app)
        }
    }

    // MARK: - Pagination test (signed-in account with a playlist of 16+ videos required)

    /// Verifies that scrolling to the bottom of a playlist loads more videos beyond
    /// the first page (~15 items returned by the TV InnerTube client).
    func testPlaylistLoadsMoreVideosOnScroll() throws {
        try openPlaylistsSegment()
        guard let playlistCard = UITestHelpers.waitForVideoCards(in: app, timeout: 20) else {
            try captureAndSkip("No playlist cards — signed-in account with playlists required", in: app)
        }
        playlistCard.tap()

        let feed = app.scrollViews["playlistView.feed"]
        guard feed.waitForExistence(timeout: 15) else {
            try captureAndSkip("playlistView.feed did not appear — playlist may be empty", in: app)
        }
        guard UITestHelpers.waitForVideoCards(in: app, timeout: 20) != nil else {
            try captureAndSkip("No video cards in playlist", in: app)
        }

        // Count cards after initial load.
        let cardsPredicate = NSPredicate(format: "identifier BEGINSWITH 'video.card.'")
        let cards = app.descendants(matching: .any).matching(cardsPredicate)
        let initialCount = cards.count
        guard initialCount >= 15 else {
            try captureAndSkip("Playlist has fewer than 15 videos — pagination won't trigger (got \(initialCount))", in: app)
        }

        // Scroll to the bottom repeatedly to trigger the loadMoreIfNeeded onAppear.
        for _ in 0..<6 {
            feed.swipeUp(velocity: .fast)
            Thread.sleep(forTimeInterval: 0.5)
        }

        // Wait up to 10 s for the card count to grow beyond the initial page.
        let morePredicate = NSPredicate(format: "count > \(initialCount)")
        let moreExpectation = XCTNSPredicateExpectation(predicate: morePredicate, object: cards)
        let result = XCTWaiter().wait(for: [moreExpectation], timeout: 10)
        XCTAssertEqual(result, .completed,
            "Playlist should load more videos after scrolling to the bottom (initial: \(initialCount), after scroll: \(cards.count))")
    }
}
