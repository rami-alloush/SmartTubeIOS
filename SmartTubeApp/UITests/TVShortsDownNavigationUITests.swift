#if os(tvOS)
import XCTest

// MARK: - TVShortsDownNavigationUITests
//
// Regression test: pressing DOWN from the Shorts row must reach the video grid.
//
// Navigation path (Home chip, Shorts visible):
//   tab-bar  →(↓1)→  chip-bar  →(↓2)→  shorts-row  →(↓3)→  video-grid
//
// Run:
//   xcodebuild test -workspace SmartTube.xcworkspace -scheme "Smart Tube" \
//     -destination "id=<simulator-udid>" \
//     -only-testing:SmartTubeTVUITests/TVShortsDownNavigationUITests

final class TVShortsDownNavigationUITests: XCTestCase {

    private var app: XCUIApplication!
    private let remote = XCUIRemote.shared

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    override func tearDownWithError() throws { app = nil }

    // MARK: - Helpers

    private func focusedIdentifier() -> String? {
        let pred = NSPredicate(format: "hasFocus == true")
        return app.descendants(matching: .any).matching(pred).firstMatch.identifier.nilIfEmpty
    }

    private func anyFocused(prefix: String) -> Bool {
        let pred = NSPredicate(format: "identifier BEGINSWITH '\(prefix)' AND hasFocus == true")
        return app.descendants(matching: .any).matching(pred).count > 0
    }

    private func snap(_ label: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = label; shot.lifetime = .keepAlways; add(shot)
    }

    private func treeSnapshot(_ label: String) {
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = label; tree.lifetime = .keepAlways; add(tree)
    }

    // MARK: - Test

    /// Presses DOWN exactly 3 times from the tab bar and verifies focus reaches
    /// the video grid. Screenshots and an accessibility-tree dump are attached
    /// after every press so failures are immediately diagnosable.
    func test_ThreeDownPresses_LandOnVideoGrid() throws {
        // Wait for home feed to be ready.
        let chipBar = app.descendants(matching: .any)["home.chipBar"]
        guard chipBar.waitForExistence(timeout: 20) else {
            try captureAndSkip("home.chipBar did not appear — Home tab not loaded", in: app)
        }

        // Let the feed fully settle (shorts + video cards both rendered).
        let videoCardPred = NSPredicate(format: "identifier BEGINSWITH 'video.card.'")
        let videoCards = app.descendants(matching: .any).matching(videoCardPred)
        _ = XCTWaiter().wait(
            for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "count > 0"), object: videoCards)],
            timeout: 20
        )

        // Capture initial state and accessibility tree before attempting navigation.
        // This is useful even if shorts are not visible (e.g. not signed in).
        snap("0-initial")
        treeSnapshot("accessibility-tree-initial")

        let shortsPred = NSPredicate(format: "identifier BEGINSWITH 'shorts.card.'")
        let shortsCards = app.descendants(matching: .any).matching(shortsPred)
        let shortsPresent = shortsCards.count > 0
        XCTContext.runActivity(named: "Shorts present: \(shortsPresent) (count=\(shortsCards.count))") { _ in }

        guard shortsPresent else {
            try captureAndSkip("No shorts.card.* elements — Shorts disabled or empty; captured initial state above", in: app)
        }

        // ── DOWN 1 ── tab-bar → chip-bar (or content if no chip-bar focus)
        remote.press(.down)
        Thread.sleep(forTimeInterval: 0.8)
        snap("1-after-first-down")
        let focused1 = focusedIdentifier() ?? "<nothing>"
        XCTContext.runActivity(named: "After DOWN 1 — focused: \(focused1)") { _ in }

        // ── DOWN 2 ── chip-bar → Shorts row
        remote.press(.down)
        Thread.sleep(forTimeInterval: 0.8)
        snap("2-after-second-down")
        let focused2 = focusedIdentifier() ?? "<nothing>"
        XCTContext.runActivity(named: "After DOWN 2 — focused: \(focused2)") { _ in }

        // ── DOWN 3 ── Shorts row → video grid  (the regression trigger)
        remote.press(.down)
        Thread.sleep(forTimeInterval: 0.8)
        snap("3-after-third-down")
        let focused3 = focusedIdentifier() ?? "<nothing>"
        XCTContext.runActivity(named: "After DOWN 3 — focused: \(focused3)") { _ in }

        treeSnapshot("accessibility-tree-after-3-downs")

        // ── Assertions ──
        XCTAssertFalse(
            anyFocused(prefix: "shorts.card."),
            "A Shorts card still has focus after 3 DOWNs — DOWN does NOT escape the Shorts row. " +
            "focused1=\(focused1) focused2=\(focused2) focused3=\(focused3)"
        )
        XCTAssertTrue(
            anyFocused(prefix: "video.card."),
            "No video.card.* gained focus after 3 DOWNs. " +
            "focused1=\(focused1) focused2=\(focused2) focused3=\(focused3)"
        )
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
#endif

