import XCTest

// MARK: - VideoPlaybackRegressionUITests
//
// Regression test for video playback failures caused by IP-bound HLS manifests.
// YouTube's iOS client returns HLS manifest URLs that are locked to the fetching
// IP address. On the iOS Simulator, AVPlayer's download IP can differ from the
// URLSession IP used by InnerTubeAPI, producing HTTP 404 errors.
//
// The fix uses the Android InnerTube client as a fallback, which returns direct
// CDN videoplayback URLs that are not subject to the same IP-binding restriction.
//
// This test verifies that video Dy9ki9Q5nXs ("Reviewing Every Themed Tourist Trap
// Restaurant") opens and plays without a player error banner.

final class VideoPlaybackRegressionUITests: XCTestCase {

    private static let targetVideoID = "Dy9ki9Q5nXs"

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

    /// Navigates to the History tab, taps video Dy9ki9Q5nXs, and asserts it
    /// plays without showing the player error banner.
    func testSpecificVideoPlaysFromHistory() throws {
        // 1. Navigate to History tab.
        tapTab(named: "History")

        // 2. Wait for the History feed to populate.
        let predicate = NSPredicate(format: "identifier BEGINSWITH 'video.card.'")
        let cards = app.descendants(matching: .any).matching(predicate)
        let feedLoaded = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "count > 0"),
            object: cards
        )
        guard XCTWaiter().wait(for: [feedLoaded], timeout: 20) == .completed else {
            throw XCTSkip("History feed did not load within 20 s — network unavailable or history empty")
        }

        // 3. Try to find the specific video card by its accessibility ID.
        //    Multiple sub-elements (Image, StaticTexts) share the same identifier, so use
        //    firstMatch to avoid "multiple matching elements" errors when tapping.
        let targetPredicate = NSPredicate(format: "identifier == 'video.card.\(Self.targetVideoID)'")
        let targetCard = app.descendants(matching: .any).matching(targetPredicate).firstMatch

        if !targetCard.waitForExistence(timeout: 3) {
            // Scroll down the feed to find the target video (it may not be first).
            scrollToFindVideo(videoId: Self.targetVideoID, in: cards)
        }

        guard targetCard.waitForExistence(timeout: 5) else {
            throw XCTSkip("Video \(Self.targetVideoID) not found in History — it may have been removed from watch history")
        }

        targetCard.tap()

        // 4. Wait for PlayerView to open.
        let titleLabel = app.staticTexts["player.titleLabel"].firstMatch
        XCTAssertTrue(
            titleLabel.waitForExistence(timeout: 15),
            "player.titleLabel must appear after tapping the video — PlayerView did not open"
        )

        let videoTitle = titleLabel.label

        // 5. Give the stream 12 s to fetch player info and begin buffering.
        //    The Android-client fallback adds ~1 extra round-trip if the primary HLS fails.
        Thread.sleep(forTimeInterval: 12)

        // 6. Assert no player error banner appeared.
        let errorBanner = app.otherElements["player.errorBanner"].firstMatch
        XCTAssertFalse(
            errorBanner.exists,
            "player.errorBanner appeared during playback of '\(videoTitle)' (\(Self.targetVideoID)) — " +
            "PlaybackViewModel.error was set. The Android-client fallback may not be working."
        )

        // 7. Assert no feed-level error alert appeared.
        XCTAssertFalse(
            app.alerts["Error"].exists,
            "An 'Error' alert appeared during or after opening '\(videoTitle)'"
        )

        // 8. Confirm the player is still open.
        XCTAssertTrue(
            titleLabel.exists,
            "player.titleLabel disappeared — PlayerView was dismissed unexpectedly"
        )
    }

    // MARK: - Helpers

    /// Taps the named tab, supporting both the bottom tab bar (iPhone) and the
    /// iPadOS 18 sidebar where tab items appear as standalone buttons.
    private func tapTab(named label: String, timeout: TimeInterval = 5) {
        let tabBarButton = app.tabBars.buttons[label]
        if tabBarButton.waitForExistence(timeout: min(timeout, 3)) {
            tabBarButton.tap()
            return
        }
        let sidebarButton = app.buttons[label].firstMatch
        XCTAssertTrue(
            sidebarButton.waitForExistence(timeout: timeout),
            "'\(label)' navigation item not found in tab bar or sidebar"
        )
        sidebarButton.tap()
    }

    /// Scrolls the feed until the card with `videoId` becomes visible.
    private func scrollToFindVideo(videoId: String, in cards: XCUIElementQuery, maxScrolls: Int = 8) {
        let targetId = "video.card.\(videoId)"
        for _ in 0..<maxScrolls {
            let target = app.descendants(matching: .any)[targetId]
            if target.exists { break }
            app.swipeUp()
        }
    }
}
