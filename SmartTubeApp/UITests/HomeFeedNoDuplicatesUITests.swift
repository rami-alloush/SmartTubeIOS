import XCTest

/// Verifies that the Home feed does not contain duplicate video IDs or blank
/// (zero-height) cells after initial load and after scrolling to trigger
/// pagination.  Duplicate IDs cause SwiftUI's ForEach to render blank cells
/// because it cannot reconcile two views with the same identity.
final class HomeFeedNoDuplicatesUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["--uitesting", "--uitesting-reset-settings"]
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - Helpers

    /// Collects all currently visible `video.card.*` element identifiers.
    private func visibleCardIdentifiers() -> [String] {
        let predicate = NSPredicate(format: "identifier BEGINSWITH 'video.card.'")
        let cards = app.descendants(matching: .any).matching(predicate)
        return (0..<cards.count).map { cards.element(boundBy: $0).identifier }
    }

    /// Returns any identifiers that appear more than once in `ids`.
    private func duplicates(in ids: [String]) -> [String] {
        var seen = Set<String>()
        var dupes = [String]()
        for id in ids {
            if !seen.insert(id).inserted {
                dupes.append(id)
            }
        }
        return dupes
    }

    // MARK: - Tests

    /// After the initial Home feed loads there must be no duplicate `video.card.*`
    /// identifiers in the accessibility tree.  Duplicates are produced when the
    /// view-model passes an array with repeated video IDs to ForEach.
    func test_InitialHomeLoad_NoDuplicateCards() throws {
        // Wait for the Home tab feed to populate.
        guard UITestHelpers.waitForVideoCards(in: app, timeout: 25) != nil else {
            throw XCTSkip("Home feed did not load any cards — likely a network issue.")
        }
        // Allow the grid to finish settling.
        Thread.sleep(forTimeInterval: 1.0)

        let ids = visibleCardIdentifiers()
        XCTAssertFalse(ids.isEmpty, "Expected at least one video card on the Home feed")

        let dupes = duplicates(in: ids)
        XCTAssertTrue(dupes.isEmpty,
                      "Duplicate video.card IDs found after initial load: \(dupes.prefix(5)). " +
                      "This means the Home feed contains repeated video IDs, which causes blank cells.")
    }

    /// After scrolling the Home feed far enough to trigger pagination (loadMore),
    /// there must still be no duplicate cards in the full accessibility tree.
    func test_AfterPagination_NoDuplicateCards() throws {
        guard UITestHelpers.waitForVideoCards(in: app, timeout: 25) != nil else {
            throw XCTSkip("Home feed did not load any cards — likely a network issue.")
        }
        Thread.sleep(forTimeInterval: 1.0)

        // Scroll down several times to trigger loadMore.
        let scrollView = app.scrollViews.firstMatch
        let hasScrollView = scrollView.waitForExistence(timeout: 5)
        let target = hasScrollView ? scrollView : app.windows.firstMatch

        for _ in 0..<5 {
            target.swipeUp(velocity: .fast)
            Thread.sleep(forTimeInterval: 0.8)
        }
        // Allow the next page to arrive and render.
        Thread.sleep(forTimeInterval: 2.0)

        let ids = visibleCardIdentifiers()
        XCTAssertFalse(ids.isEmpty, "Expected video cards to still be present after pagination")

        let dupes = duplicates(in: ids)
        XCTAssertTrue(dupes.isEmpty,
                      "Duplicate video.card IDs found after pagination: \(dupes.prefix(5)). " +
                      "This means loadMore is appending videos that are already in the feed.")
    }

    /// Every visible `video.card.*` element must have a non-empty title text.
    /// A blank title indicates a cell rendered with a duplicate ID where SwiftUI
    /// failed to resolve the correct model.
    func test_AllCards_HaveNonEmptyTitles() throws {
        guard UITestHelpers.waitForVideoCards(in: app, timeout: 25) != nil else {
            throw XCTSkip("Home feed did not load any cards — likely a network issue.")
        }
        Thread.sleep(forTimeInterval: 1.0)

        let predicate = NSPredicate(format: "identifier BEGINSWITH 'video.card.'")
        let cards = app.descendants(matching: .any).matching(predicate)
        let count = cards.count

        XCTAssertGreaterThan(count, 0, "Expected at least one card")

        var blankCardIds = [String]()
        for i in 0..<count {
            let card = cards.element(boundBy: i)
            let titlePredicate = NSPredicate(format: "identifier == 'video.card.title'")
            let titleElements = card.descendants(matching: .staticText).matching(titlePredicate)
            let hasTitle = titleElements.count > 0 && !(titleElements.firstMatch.label.isEmpty)
            if !hasTitle {
                blankCardIds.append(card.identifier)
            }
        }

        XCTAssertTrue(blankCardIds.isEmpty,
                      "Cards with blank/missing titles: \(blankCardIds.prefix(5)). " +
                      "Blank cells usually mean duplicate video IDs reached ForEach.")
    }
}
