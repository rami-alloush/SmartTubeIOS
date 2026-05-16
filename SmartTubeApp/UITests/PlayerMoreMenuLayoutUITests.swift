import XCTest

final class PlayerMoreMenuLayoutUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = [
            "--uitesting",
            "--uitesting-deeplink-video=dQw4w9WgXcQ",
            "--uitesting-open-more-menu"
        ]
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
        app = nil
    }

    func testMoreMenuIsScrollableAndUsableInLandscape() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        app.launch()
        let player = app.otherElements["player.view"].firstMatch
        guard player.waitForExistence(timeout: 20) else {
            throw XCTSkip("Player did not open within 20 s — network unavailable or video inaccessible")
        }

        let landscapePredicate = NSPredicate { [app] _, _ in
            app!.frame.size.width > app!.frame.size.height
        }
        let landscapeExpectation = XCTNSPredicateExpectation(predicate: landscapePredicate, object: nil)
        XCTAssertEqual(
            XCTWaiter().wait(for: [landscapeExpectation], timeout: 5),
            .completed,
            "Player must rotate to landscape before checking compact more-menu layout. frame was \(app.frame.size)"
        )

        let speedRow = app.buttons["player.moreMenu.speedRow"].firstMatch
        XCTAssertTrue(speedRow.waitForExistence(timeout: 10),
                      "More menu should open and show the first row in landscape")
        XCTAssertTrue(speedRow.isHittable,
                      "Top of more menu should remain tappable in landscape")

        let scrollView = app.scrollViews["player.moreMenu.scrollView"].firstMatch
        XCTAssertTrue(scrollView.waitForExistence(timeout: 5),
                      "More menu should expose a scroll view in landscape")

        let cancelButton = app.buttons["player.moreMenu.cancel"].firstMatch
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline && !cancelButton.isHittable {
            scrollView.swipeUp()
        }
        XCTAssertTrue(cancelButton.exists,
                      "Cancel row should remain in the accessibility tree")
        XCTAssertTrue(cancelButton.isHittable,
                      "Bottom of more menu should be reachable by scrolling in landscape")
        XCTAssertEqual(app.state, .runningForeground,
                       "App must remain running while interacting with the landscape more menu")
    }

    func testMoreMenuWidthIsConstrainedInPortrait() throws {
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        let player = app.otherElements["player.view"].firstMatch
        guard player.waitForExistence(timeout: 20) else {
            throw XCTSkip("Player did not open within 20 s — network unavailable or video inaccessible")
        }

        let scrollView = app.scrollViews["player.moreMenu.scrollView"].firstMatch
        XCTAssertTrue(scrollView.waitForExistence(timeout: 10),
                      "More menu scroll view must appear in portrait")

        // The menu must be ≤ 80 % of portrait screen width (moreMenuPortraitWidth).
        // Allow ±5 % tolerance for safe-area / padding rounding.
        let screenWidth = app.frame.size.width
        let menuWidth = scrollView.frame.size.width
        let expectedMax = screenWidth * 0.85
        XCTAssertLessThanOrEqual(menuWidth, expectedMax,
                                 "More menu width (\(menuWidth)pt) must be ≤ 85 % of screen width " +
                                 "(\(screenWidth)pt) — task #44 constraint")
        XCTAssertGreaterThan(menuWidth, screenWidth * 0.5,
                             "More menu width (\(menuWidth)pt) must be reasonable (> 50 % of screen)")

        let speedRow = app.buttons["player.moreMenu.speedRow"].firstMatch
        XCTAssertTrue(speedRow.isHittable, "Speed row must be tappable in portrait")
    }

    /// Regression for #94: the portrait more menu must fit all items without
    /// requiring the user to scroll (moreMenuMaxHeight reduced from 520→380 pt).
    func testMoreMenuDoesNotRequireScrollInPortrait() throws {
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        let player = app.otherElements["player.view"].firstMatch
        guard player.waitForExistence(timeout: 20) else {
            throw XCTSkip("Player did not open within 20 s — network unavailable or video inaccessible")
        }

        let cancelButton = app.buttons["player.moreMenu.cancel"].firstMatch
        XCTAssertTrue(cancelButton.waitForExistence(timeout: 10),
                      "Cancel button must be accessible in the portrait more menu")

        // Cancel is the bottom-most item. If it is immediately hittable without
        // any scrolling the menu fits fully in the portrait frame.
        XCTAssertTrue(cancelButton.isHittable,
                      "Cancel button must be hittable without scrolling in portrait — " +
                      "menu should fit entirely within portrait height (moreMenuMaxHeight = 380 pt)")
    }
}
