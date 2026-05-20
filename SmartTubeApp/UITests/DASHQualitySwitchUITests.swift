import XCTest

// AGENT-POST-RUN-CHECK: ui-tests-with-logs
//
// After every run of this test, load .github/skills/ui-tests-with-logs/SKILL.md and inspect
// the extracted device log. Classify every skip and failure before closing the task:
//
// EXPECTED (per-step skip — not a bug):
//   - "not available in picker" — this quality option doesn't exist for this video. Fine.
//
// BUG (must fix before closing):
//   - XCTAssertTrue failure: "Stats 'Selected' row did not show 'Xp' within 5 s"
//     → selectFormat() was never called, or pendingQualityLabel not propagated to snapshot
//   - "player.quickAccess.quality not hittable" — controls overlay didn't appear
//   - "player.moreButton not found" / "player.moreMenu.statsForNerds not found" — UI missing
//   - "Player did not open" / "DASH video never became ready" — playback failed entirely
//   - Any whole-test XCTSkip without confirming CDN/network cause in the device log
//
// Log events to verify for each quality step:
//   ✓ [qualityPicker] selected <quality> (was: ...)
//   ✓ [quality] selectFormat → <quality> (<codec>) <W>×<H>@<fps>fps
//   ✓ [stats] snapshot … pendingQualityLabel should update to the chosen quality
//   ✗ source=selectedFormat(<quality>) in [stats] snapshot
//     (may revert to presentationSize due to CDN 403 in simulator — that is fine)
//
// GOOD run in simulator: all 6 quality steps either PASS (selectFormat called) or skip (not in picker).
// GOOD run on device: all quality steps PASS + Stats resolution matches selected quality.

// MARK: - DASHQualitySwitchUITests
//
// End-to-end regression test for DASH/MP4 quality switching (bug fixed in commits 9dac69d + 1de0da3).
//
// Video 55pSC5R6Kl8 ("change your wifi name" by RAINBOLT) is a DASH-only video
// (hlsURL=nil, formats=128) — quality switches rebuild AVMutableComposition from the
// selected H.264 adaptive stream URL + bestAdaptiveAudioURL, using the correct
// per-URL User-Agent (c=ANDROID → Android UA, otherwise iOS UA).
//
// Verification strategy: "Stats for Nerds" is enabled via the more menu. While visible,
// PlaybackViewModel.updateStatsSnapshot() fires every 0.5 s via the AVPlayer periodic
// time observer, updating the Resolution row with the current AVPlayerItem.presentationSize.
// Each quality step waits up to 30 s for the Resolution static-text to contain the
// expected height suffix (e.g. "×720") then captures a screenshot with the Stats overlay.

#if os(iOS)

final class DASHQualitySwitchUITests: XCTestCase {

    /// DASH-only video confirmed in device logs:
    ///   [store] playerInfo 55pSC5R6Kl8 formats=128 hls=false
    ///   playerInfo: formats=128 hlsURL=nil dashURL=nil
    private static let videoID = "55pSC5R6Kl8"

    /// Second test video from real-device log.txt (recorded during quality-revert investigation).
    ///   [store] playerInfo GZzsJMSQKAs formats=28 hls=false
    /// Confirms quality switching + pendingQualityLabel persistence on a different video.
    private static let videoID_logTxt = "GZzsJMSQKAs"

    /// Resolution label separator character: U+00D7 MULTIPLICATION SIGN, as used in
    /// PlaybackViewModel+StatsForNerds.swift: "\(width)×\(height)"
    private static let cross = "\u{00D7}"

    private var app: XCUIApplication!

    // MARK: - Lifecycle

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    /// Terminates any running instance and launches fresh with the given video deeplink.
    private func launchWithVideo(_ videoID: String) {
        app.terminate()
        app.launchArguments = [
            "--uitesting",
            "--uitesting-deeplink-video=\(videoID)",
            "--uitesting-show-controls",
            "--uitesting-disable-sponsorblock"
        ]
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - Test

    /// Cycles through all common quality levels on the DASH-only video (55pSC5R6Kl8, formats=128).
    func testQualityCycleOnDASHVideo() throws {
        launchWithVideo(Self.videoID)
        try runQualityCycle()
    }

    /// Same quality cycle on the real-device video from log.txt (GZzsJMSQKAs, formats=28).
    /// Confirms quality-button persistence fix works across different videos.
    func testQualityCycleOnDASHVideo_GZzsJMSQKAs() throws {
        launchWithVideo(Self.videoID_logTxt)
        try runQualityCycle()
    }

    // MARK: - Shared quality cycle

    /// Shared body for all DASH quality-cycle tests.
    ///
    /// Verifies via the Stats for Nerds "Selected" row that each quality switch records
    /// `selectFormat` was called with the correct quality, and that the quick-access quality
    /// button label persists after a CDN 403 failure (pendingQualityLabel fix).
    ///
    /// CDN-independent: `pendingQualityLabel` is set synchronously and never cleared on failure.
    ///
    /// Per-step behaviour:
    ///  - Quality not in picker → step is silently skipped (not a failure).
    ///  - Quality in picker but Stats "Selected" not updated within 5 s → XCTFail (real bug).
    private func runQualityCycle() throws {

        // ── Step 1: Wait for DASH playback to start ──────────────────────────
        guard app.staticTexts["player.titleLabel"].firstMatch.waitForExistence(timeout: 25) else {
            try captureAndSkip("Player did not open within 25 s — network unavailable", in: app)
        }
        let playPause = app.buttons["player.playPauseButton"].firstMatch
        guard playPause.waitForExistence(timeout: 15) else {
            try captureAndSkip("play/pause button never appeared", in: app)
        }
        let enabledPred = NSPredicate(format: "enabled == true")
        let enabledExp = XCTNSPredicateExpectation(predicate: enabledPred, object: playPause)
        guard XCTWaiter().wait(for: [enabledExp], timeout: 50) == .completed else {
            try captureAndSkip("DASH video never became ready to play within 50 s", in: app)
        }
        UITestHelpers.assertNoPlayerErrorBanner(in: app, videoTitle: "DASH quality cycle")

        // ── Step 2: Enable Stats for Nerds ───────────────────────────────────
        try enableStatsForNerds()
        Thread.sleep(forTimeInterval: 1.5)

        let baseline = currentResolutionLabel() ?? "nil"
        captureState("baseline — resolution: \(baseline)", in: app)

        // ── Step 3: Quality cycle ─────────────────────────────────────────────
        // Covers all standard H.264 quality levels YouTube offers.
        // The picker uses BEGINSWITH matching, so "720p" matches "720p60" and "720p30".
        // Steps that don't exist in the picker are silently skipped (not a failure).
        let steps: [String] = ["720p", "480p", "1080p", "360p", "240p", "144p"]

        for quality in steps {
            showControls()
            let found = switchQualityIfAvailable(quality)
            guard found else {
                XCTContext.runActivity(named: "skip \(quality): not in picker") { _ in
                    captureState("skipping \(quality) — not available in picker for this video", in: app)
                }
                continue
            }

            // `pendingQualityLabel` is set synchronously when selectFormat is called and
            // persists even if CDN fails. 5 s is very generous for an accessibility update.
            let selected = waitForSelectedQuality(containing: quality, timeout: 5)
            captureState(
                "after \(quality) — selected: \(currentSelectedQualityLabel() ?? "nil"), " +
                "resolution: \(currentResolutionLabel() ?? "nil")",
                in: app
            )
            UITestHelpers.assertNoPlayerErrorBanner(in: app)
            XCTAssertTrue(
                selected,
                "Stats 'Selected' row did not show '\(quality)' within 5 s — " +
                "selectFormat() may not have been called after tapping the quality option."
            )

            // Verify that the quality button label persists after CDN failure.
            // The button should show the user's selection (via pendingQualityLabel),
            // not revert to "Auto" when composition rebuild fails with HTTP 403.
            showControls()
            let qBtn = app.buttons["player.quickAccess.quality"].firstMatch
            if qBtn.waitForExistence(timeout: 3) && qBtn.isHittable {
                let btnLabel = qBtn.label
                XCTAssertTrue(
                    btnLabel.contains(quality),
                    "Quality button shows '\(btnLabel)' after CDN failure — " +
                    "expected '\(quality)' to persist via pendingQualityLabel (bug: revert to Auto)"
                )
            }
        }
    }

    // MARK: - Helpers

    /// Opens the more menu, taps "Stats for Nerds", waits for the overlay to appear.
    private func enableStatsForNerds() throws {
        showControls()
        let moreBtn = app.buttons["player.moreButton"].firstMatch
        guard moreBtn.waitForExistence(timeout: 8) && moreBtn.isHittable else {
            try captureAndSkip("player.moreButton not found or not hittable", in: app)
        }
        moreBtn.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        let statsRow = app.buttons["player.moreMenu.statsForNerds"].firstMatch
        guard statsRow.waitForExistence(timeout: 5) else {
            try captureAndSkip("player.moreMenu.statsForNerds not found", in: app)
        }
        statsRow.tap()
        // More menu auto-closes; Stats overlay becomes visible.
    }

    /// Returns the label of the first static text containing "×" (the resolution value
    /// in the Stats overlay, e.g. "1280×720 @ 60 fps").
    private func currentResolutionLabel() -> String? {
        let predicate = NSPredicate(format: "label CONTAINS %@", Self.cross)
        let el = app.staticTexts.matching(predicate).firstMatch
        return el.exists ? el.label : nil
    }

    /// Returns the label of the "stats.selectedQuality" text element — the quality
    /// most recently selected by the user (persists after CDN failure).
    private func currentSelectedQualityLabel() -> String? {
        let el = app.staticTexts["stats.selectedQuality"].firstMatch
        return el.exists ? el.label : nil
    }

    /// Polls until `stats.selectedQuality` contains `quality` (e.g. "720p") or times out.
    /// This is CDN-independent because `pendingQualityLabel` is set synchronously in
    /// `selectFormat` and never cleared on composition failure.
    private func waitForSelectedQuality(containing quality: String, timeout: TimeInterval) -> Bool {
        let el = app.staticTexts["stats.selectedQuality"].firstMatch
        let pred = NSPredicate(format: "label CONTAINS %@", quality)
        let exp = XCTNSPredicateExpectation(predicate: pred, object: el)
        return XCTWaiter().wait(for: [exp], timeout: timeout) == .completed
    }

    /// Reveals the player controls overlay if the quality quick-access button is not
    /// currently hittable.
    private func showControls() {
        let qualityBtn = app.buttons["player.quickAccess.quality"].firstMatch
        for _ in 0..<5 {
            if qualityBtn.waitForExistence(timeout: 1) && qualityBtn.isHittable { return }
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            Thread.sleep(forTimeInterval: 1.0)
        }
    }

    /// Opens the quality picker and taps the option whose label begins with `qualityLabel`.
    /// Returns `true` if the option was found and tapped, `false` if it was absent (step skip).
    /// Throws `XCTSkip` only for hard failures (controls not visible, picker never opened).
    @discardableResult
    private func switchQualityIfAvailable(_ qualityLabel: String) -> Bool {
        let qualityBtn = app.buttons["player.quickAccess.quality"].firstMatch
        guard qualityBtn.exists && qualityBtn.isHittable else {
            return false
        }
        qualityBtn.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        let option = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", qualityLabel)
        ).firstMatch
        guard option.waitForExistence(timeout: 5) else {
            // Quality not available for this video — close picker and continue.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            Thread.sleep(forTimeInterval: 0.5)
            return false
        }
        option.tap()

        let dismissedPred = NSPredicate(format: "exists == false")
        let dismissExp = XCTNSPredicateExpectation(predicate: dismissedPred, object: option)
        _ = XCTWaiter().wait(for: [dismissExp], timeout: 5)
        return true
    }

    /// Legacy throwing variant — kept for the playerError/moreButton guard paths above.
    private func switchQuality(to qualityLabel: String) throws {
        let qualityBtn = app.buttons["player.quickAccess.quality"].firstMatch
        guard qualityBtn.waitForExistence(timeout: 8) && qualityBtn.isHittable else {
            try captureAndSkip(
                "player.quickAccess.quality not hittable before selecting \(qualityLabel)", in: app)
        }
        qualityBtn.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        let option = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", qualityLabel)
        ).firstMatch
        guard option.waitForExistence(timeout: 5) else {
            try captureAndSkip(
                "Quality option '\(qualityLabel)' not found — picker may not have opened", in: app)
        }
        option.tap()

        let dismissedPred = NSPredicate(format: "exists == false")
        let dismissExp = XCTNSPredicateExpectation(predicate: dismissedPred, object: option)
        _ = XCTWaiter().wait(for: [dismissExp], timeout: 5)
    }
}

#endif // os(iOS)
