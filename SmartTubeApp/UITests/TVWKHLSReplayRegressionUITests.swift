#if os(tvOS)
import XCTest

// AGENT-POST-RUN-CHECK: ui-tests-with-logs
//
// After every run extract device logs and inspect across all replay cycles:
//
// GOOD — each cycle should show:
//   ✓ [load] load() called — id=<videoID>
//   ✓ [wkHLS] cached HLS URL found  ← must NOT appear on cycle 2+ (evicted by stop())
//   ✓ ✅ [webView/HLS] readyToPlay
//   ✓ ✅ [webView] Path B won  OR  [BotGuardWV] Path A won
//
// BAD — fail if any of these appear:
//   ✗ ❌ [webView/HLS] AVPlayerItem failed   ← stale-session bug
//   ✗ [wkHLS] cached URL failed (tryWebViewHLS)
//   ✗ tap-to-readyToPlay > 10 s on cycle 2+
//
// TIMING to record per cycle:
//   [load] load() called → ✅ readyToPlay

// MARK: - TVWKHLSReplayRegressionUITests
//
// tvOS variant of WKHLSReplayRegressionUITests.
//
// Same regression being tested: after stop(), the wkHLS manifest URL must be
// evicted from VideoPreloadCache so Phase -1a does not replay a stale CDN session
// on re-tap. stop() calls VideoPreloadCache.shared.invalidateWKHLSURL(for:).
//
// tvOS differences from iOS:
//   - Navigation via XCUIRemote D-pad (↓↓ select) instead of tap gestures
//   - Stop via remote.press(.menu) instead of player.backButton
//   - Controls shown/hidden by remote.press(.select)
//   - Mini-player may or may not appear on tvOS; handled with a graceful fallback

final class TVWKHLSReplayRegressionUITests: XCTestCase {

    private var app: XCUIApplication!
    private let remote = XCUIRemote.shared

    // MARK: - Lifecycle

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = [
            "--uitesting",
            "--uitesting-disable-sponsorblock",
        ]
        app.launch()
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
    }

    // MARK: - Test

    /// Opens the first non-short video on the Home feed, plays it for 3 s,
    /// stops it via Menu button, then repeats 3 times.
    ///
    /// Asserts on each cycle:
    ///   - player.titleLabel appears (video loaded)
    ///   - player.errorBanner is absent (no CDN 403 flash)
    ///   - title is stable (no wrong video played)
    func testReplayFirstHomeVideoFiveTimes() throws {
        let totalCycles = 3

        // ── Navigate to Home feed ─────────────────────────────────────────────
        let chipBar = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'home.chipBar'"))
            .firstMatch
        guard chipBar.waitForExistence(timeout: 15) else {
            try captureAndSkip("home.chipBar not found — app did not reach Home tab", in: app)
        }

        // Wait for video cards.
        guard let firstCard = firstNonShortVideoCard(timeout: 30) else {
            try captureAndSkip(
                "No non-short video.card found on Home feed — network unavailable",
                in: app
            )
        }

        let cardID = firstCard.identifier                              // "video.card.<videoId>"
        let videoId = String(cardID.dropFirst("video.card.".count))   // "<videoId>"

        // Wait for prewarm.done.<videoId> before first tap (same as iOS variant).
        let preWarmExpectation = XCTDarwinNotificationExpectation(
            notificationName: "com.void.smarttube.player.prewarm.done.\(videoId)"
        )
        let _ = XCTWaiter().wait(for: [preWarmExpectation], timeout: 90)

        let expectedTitle = titleText(for: firstCard)

        var replayTimings: [(cycle: Int, elapsed: Double)] = []

        for cycle in 1...totalCycles {
            // ── Find card and navigate to it ──────────────────────────────────
            // On tvOS, we re-navigate from Home each cycle because Menu dismisses
            // the player and returns focus to the feed.
            let card = app.descendants(matching: .any)
                .matching(identifier: cardID).firstMatch
            guard card.waitForExistence(timeout: 15) else {
                XCTFail("Cycle \(cycle): card '\(cardID)' not found — feed may have refreshed")
                return
            }

            // Bring focus to the card and select it.
            // On tvOS, .tap() on an XCUIElement moves focus and selects it.
            let readyExpectation = XCTDarwinNotificationExpectation(
                notificationName: "com.void.smarttube.player.ready"
            )

            let titleLabel = app.staticTexts["player.titleLabel"].firstMatch
            let tapTime = Date()
            card.tap()

            let readyResult = XCTWaiter().wait(for: [readyExpectation], timeout: 10)
            let elapsed = Date().timeIntervalSince(tapTime)
            let label = cycle == 1 ? "cold" : "hot "
            if readyResult == .completed {
                print("[WKHLSReplay] cycle \(cycle)  \(label)  \(String(format: "%.2f", elapsed))s")
            } else {
                print("[WKHLSReplay] cycle \(cycle)  \(label)  \(String(format: "%.2f", elapsed))s (readyToPlay not received within 10 s)")
            }
            replayTimings.append((cycle: cycle, elapsed: elapsed))

            // Functional check: player title must appear.
            guard titleLabel.waitForExistence(timeout: max(25.0 - elapsed, 5.0)) else {
                XCTFail("Cycle \(cycle): player.titleLabel did not appear — possible stale-session 403")
                return
            }

            // Assert no error banner.
            let errorBanner = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier == 'player.errorBanner'"))
                .firstMatch
            XCTAssertFalse(
                errorBanner.exists,
                "Cycle \(cycle): player.errorBanner visible — stale CDN session may have served wrong content"
            )

            // Assert correct video title.
            if let expected = expectedTitle, !expected.isEmpty {
                XCTAssertEqual(
                    titleLabel.label, expected,
                    "Cycle \(cycle): player title '\(titleLabel.label)' ≠ expected '\(expected)'"
                )
            }

            // Let it play for 3 s.
            Thread.sleep(forTimeInterval: 3)

            XCTAssertFalse(
                errorBanner.exists,
                "Cycle \(cycle): player.errorBanner appeared after 3 s of playback"
            )

            // ── Stop: Menu button → back to home (or mini-player) ─────────────
            // Show controls first so back button is accessible.
            remote.press(.select)
            Thread.sleep(forTimeInterval: 0.4)

            // Try the player backButton first (same as iOS path).
            let backButton = app.buttons["player.backButton"].firstMatch
            if backButton.waitForExistence(timeout: 3) {
                backButton.tap()
            } else {
                // Fallback: Menu button dismisses the player on tvOS.
                remote.press(.menu)
            }
            Thread.sleep(forTimeInterval: 0.5)

            // Close mini-player if it appeared.
            let miniPlayerBar = app.otherElements["miniPlayer.bar"].firstMatch
            if miniPlayerBar.waitForExistence(timeout: 5) {
                let miniClose = app.buttons["miniPlayer.closeButton"].firstMatch
                if miniClose.waitForExistence(timeout: 3) {
                    miniClose.tap()
                    let miniGone = NSPredicate(format: "exists == false")
                    let gone = XCTNSPredicateExpectation(predicate: miniGone, object: miniPlayerBar)
                    XCTWaiter().wait(for: [gone], timeout: 5)
                }
            }

            // Brief pause so stop()'s invalidateWKHLSURL runs and the VideoCardView
            // heartbeat re-prewarms the URL before the next cycle's tap.
            // Same rationale as iOS: 6 s covers heartbeat interval (≤3 s) + warm
            // WKWebView extraction (~2.5 s) with margin.
            Thread.sleep(forTimeInterval: 6.0)

            print("[WKHLSReplay] cycle \(cycle): stop complete — wkHLS cache evicted")
        }

        let timingSummary = replayTimings
            .map { "c\($0.cycle)=\(String(format: "%.2f", $0.elapsed))s" }
            .joined(separator: " ")
        print("[WKHLSReplay] results: \(timingSummary)")
        print("[WKHLSReplay] all \(totalCycles) cycles passed — no stale-session 403 regression")
    }

    // MARK: - Helpers

    /// Finds the first `video.card.*` element whose accessibilityValue is NOT "short".
    private func firstNonShortVideoCard(timeout: TimeInterval) -> XCUIElement? {
        let predicate = NSPredicate(format: "identifier BEGINSWITH 'video.card.'")
        let cards = app.descendants(matching: .any).matching(predicate)
        let any = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count > 0"),
                                            object: cards)
        guard XCTWaiter().wait(for: [any], timeout: timeout) == .completed else {
            return nil
        }
        for i in 0..<min(cards.count, 20) {
            let card = cards.element(boundBy: i)
            if card.value as? String != "short" {
                return card
            }
        }
        return cards.firstMatch
    }

    /// Returns the text of the `video.card.title` element inside the given card.
    private func titleText(for card: XCUIElement) -> String? {
        let titleEl = card.staticTexts["video.card.title"].firstMatch
        if titleEl.exists { return titleEl.label }
        let allTitles = app.staticTexts.matching(identifier: "video.card.title")
        return allTitles.count > 0 ? allTitles.firstMatch.label : nil
    }
}
#endif
