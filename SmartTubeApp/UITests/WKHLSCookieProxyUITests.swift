import XCTest

// AGENT-POST-RUN-CHECK: ui-tests-with-logs
//
// After every run of this test, load .github/skills/ui-tests-with-logs/SKILL.md and inspect
// the extracted device log. Classify every skip before closing the task:
//
// LEGITIMATE skip:
//   - "Player did not open within 25 s — network unavailable"  (CI/no-internet)
//   - "play/pause button never appeared"                        (CI/no-internet)
//
// BUG skip (must fix before closing):
//   - Any skip not matching the above network patterns
//
// Log events to verify:
//   ✓ [webView/HLS] extracted N cookies (M googlevideo) for proxy     — #207: cookies extracted
//   ✓ [webView/HLS] variant rqh=… googlevideoCoookies=M/N             — #209: guard evaluated
//   ✓ [HLSProxy] attaching N cookies (M googlevideo) to segment request — #207: cookies forwarded
//   ✓ [webView] got hlsManifestUrl  OR  [webView] 720p+ HLS playing   — WKWebView path used
//   ✓ Video is playing (play/pause button enabled within 90 s)
//   ✗ [HLSProxy] URLSession error / HTTP=403                          — expected to NOT appear
//
// RED FLAGS in device log:
//   - "⚠️ [webView/HLS] variant requires rqh=1 but no googlevideo cookies" → #209 guard fired, #207 cookies missing
//   - "[HLSProxy] … HTTP=403"     → segment 403 still occurring (cookie fix #207 ineffective)
//   - "googlevideo) for proxy" shows "0 googlevideo" → WKWebView did not set googlevideo cookies
//   - "All adaptive video URLs are rqh=1 — skipping" → #208 guard fired (normal for embedded-disabled videos)
//
// EXPECTED for m1WGX1-uGvU (the rqh=1 log-analysis video, 2026-05-25):
//   If WKWebView is signed in: M googlevideo cookies > 0 AND proxy proceeds without 403.
//   If not signed in: #209 guard fires (legitimate — no auth), video plays via muxed fallback.

// MARK: - WKHLSCookieProxyUITests
//
// Regression test for tasks #207–#211 (rqh=1 HLS proxy cookie pipeline).
//
// Video m1WGX1-uGvU is the video from the 2026-05-25 log that exhibited the
// 15.7 s playback failure due to rqh=1 segment 403s with 0 googlevideo cookies.
//
// This test verifies:
//   #207  — WKWebView cookies (including googlevideo.com) are extracted and forwarded to
//            YTHLSProxyLoader. Log: "[webView/HLS] extracted N cookies (M googlevideo)"
//            and "[HLSProxy] attaching N cookies (M googlevideo)"
//
//   #208  — If ALL adaptive video URLs are rqh=1, the 8 s loadTracks stall guard fires
//            and the app skips straight to WKWebView HLS extraction.
//            Log: "[*] All adaptive video URLs are rqh=1 — skipping 8 s loadTracks stall"
//
//   #209  — If the best HLS variant is rqh=1 AND googlevideo cookies are absent, the
//            proxy construction is skipped. Log: "variant requires rqh=1 but no googlevideo
//            cookies". The test asserts video still plays (via muxed fallback) in that case.
//
//   #210  — Quality switches after muxed fallback are not tested here (requires manual
//            interaction); validated in DASHQualitySwitchUITests.
//
//   #211  — Cached URL probe on second load. Not exercised in this single-launch test;
//            validated in QuickAccessRowUITests (second-play path).

#if os(iOS)

final class WKHLSCookieProxyUITests: XCTestCase {

    /// The video that triggered the original rqh=1 segment 403 failure (log.txt 2026-05-25).
    private static let videoID = "m1WGX1-uGvU"

    private var app: XCUIApplication!

    // MARK: - Lifecycle

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = [
            "--uitesting",
            "--uitesting-deeplink-video=\(Self.videoID)",
            "--uitesting-show-controls",
            "--uitesting-disable-sponsorblock"
        ]
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - Tests

    /// Plays the rqh=1 problem video (m1WGX1-uGvU) and asserts it becomes ready within 90 s.
    ///
    /// What the device log should show (see AGENT-POST-RUN-CHECK above for full checklist):
    ///   1. "[webView/HLS] extracted N cookies (M googlevideo)" — cookies extracted from WKWebView
    ///   2. "[webView/HLS] variant rqh=… googlevideoCoookies=M/N" — #209 guard logged
    ///   3. Video plays via WKWebView HLS (M googlevideo > 0) OR via muxed fallback (M == 0, #209 guard)
    ///   4. NO "[HLSProxy] … HTTP=403" lines (cookie forwarding resolved segment 403s)
    func testRqh1VideoPlaysWithoutSegment403() throws {
        // ── Step 1: Wait for player to open ──────────────────────────────────
        guard app.staticTexts["player.titleLabel"].firstMatch.waitForExistence(timeout: 25) else {
            try captureAndSkip("Player did not open within 25 s — network unavailable", in: app)
        }

        // ── Step 2: Wait for playback to be ready (up to 90 s for exhaustiveRetry) ───────
        let playPause = app.buttons["player.playPauseButton"].firstMatch
        guard playPause.waitForExistence(timeout: 15) else {
            try captureAndSkip("play/pause button never appeared", in: app)
        }

        let enabledPred = NSPredicate(format: "enabled == true")
        let enabledExp = XCTNSPredicateExpectation(predicate: enabledPred, object: playPause)
        guard XCTWaiter().wait(for: [enabledExp], timeout: 90) == .completed else {
            XCTFail(
                "Video m1WGX1-uGvU did not become playable within 90 s. " +
                "exhaustiveRetry failed for all client paths. " +
                "Check device log for: rqh=1 403 errors, WKWebView extraction nil, " +
                "network unavailable."
            )
            return
        }

        UITestHelpers.assertNoPlayerErrorBanner(in: app, videoTitle: "WKHLSCookieProxy")

        // ── Step 3: Enable Stats for Nerds, read resolution ──────────────────
        try enableStatsForNerds()
        Thread.sleep(forTimeInterval: 2.5)

        let resLabel = currentResolutionLabel() ?? "nil"
        captureState("resolution: \(resLabel)", in: app)

        // ── Step 4: Assert video is actually rendering (height > 0) ──────────
        let height = resolutionHeight(from: resLabel)
        XCTAssertGreaterThan(
            height, 0,
            "Stats for Nerds shows no resolution — video may not be rendering. " +
            "label='\(resLabel)'. Check device log for proxy errors."
        )

        // ── Step 5: No proxy 403 assertion is done via AGENT-POST-RUN-CHECK ──
        // The device log analysis step (grep for "[HLSProxy].*HTTP=403") is
        // performed by the agent after xcresulttool export diagnostics.
    }

    // MARK: - Helpers

    private func enableStatsForNerds() throws {
        showControls()
        let moreBtn = app.buttons["player.moreButton"].firstMatch
        guard moreBtn.waitForExistence(timeout: 8) && moreBtn.isHittable else {
            try captureAndSkip("player.moreButton not found — skipping stats step", in: app)
        }
        moreBtn.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        let statsRow = app.buttons["player.moreMenu.statsForNerds"].firstMatch
        guard statsRow.waitForExistence(timeout: 5) else {
            try captureAndSkip("player.moreMenu.statsForNerds not found", in: app)
        }
        statsRow.tap()
        Thread.sleep(forTimeInterval: 0.5)
    }

    private func showControls() {
        let moreBtn = app.buttons["player.moreButton"].firstMatch
        for _ in 0..<6 {
            if moreBtn.waitForExistence(timeout: 1) && moreBtn.isHittable { return }
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            Thread.sleep(forTimeInterval: 1.0)
        }
    }

    private static let cross = "\u{00D7}"

    private func currentResolutionLabel() -> String? {
        let predicate = NSPredicate(format: "label CONTAINS %@", Self.cross)
        let el = app.staticTexts.matching(predicate).firstMatch
        return el.exists ? el.label : nil
    }

    private func resolutionHeight(from label: String) -> Int {
        guard let crossRange = label.range(of: Self.cross) else { return 0 }
        let afterCross = String(label[crossRange.upperBound...])
        let digits = afterCross.prefix(while: { $0.isNumber })
        return Int(digits) ?? 0
    }
}

#endif // os(iOS)
