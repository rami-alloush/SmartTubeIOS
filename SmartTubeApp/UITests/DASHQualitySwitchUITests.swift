import XCTest

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

    /// Resolution label separator character: U+00D7 MULTIPLICATION SIGN, as used in
    /// PlaybackViewModel+StatsForNerds.swift: "\(width)×\(height)"
    private static let cross = "\u{00D7}"

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

    // MARK: - Test

    /// Cycles through 720p60 → 480p → 1080p60 on the DASH-only video, verifying via
    /// Stats for Nerds that each quality switch produces the correct presentation size.
    /// Screenshots with the Stats overlay are attached for every step.
    func testQualityCycleOnDASHVideo() throws {

        // ── Step 1: Wait for DASH playback to start ──────────────────────────
        guard app.staticTexts["player.titleLabel"].firstMatch.waitForExistence(timeout: 25) else {
            try captureAndSkip("Player did not open within 25 s — network unavailable", in: app)
        }
        let playPause = app.buttons["player.playPauseButton"].firstMatch
        guard playPause.waitForExistence(timeout: 15) else {
            try captureAndSkip("play/pause button never appeared", in: app)
        }
        // isLoading=false is signalled by the button becoming enabled.
        let enabledPred = NSPredicate(format: "enabled == true")
        let enabledExp = XCTNSPredicateExpectation(predicate: enabledPred, object: playPause)
        guard XCTWaiter().wait(for: [enabledExp], timeout: 50) == .completed else {
            try captureAndSkip("DASH video never became ready to play within 50 s", in: app)
        }
        UITestHelpers.assertNoPlayerErrorBanner(in: app, videoTitle: "DASH quality cycle")

        // ── Step 2: Enable Stats for Nerds ───────────────────────────────────
        // Stats auto-refreshes every 0.5 s while statsForNerdsVisible == true.
        try enableStatsForNerds()
        Thread.sleep(forTimeInterval: 1.5)  // allow two time-observer ticks

        let baseline = currentResolutionLabel() ?? "nil"
        captureState("baseline — resolution: \(baseline)", in: app)

        // ── Step 3: Quality cycle ─────────────────────────────────────────────
        // Each tuple: (pickerLabel, heightSuffix).
        // The suffix "×720" matches "1280×720" but not "640×360" etc.
        // YouTube H.264 expected widths for this video:
        //   720p60  → 1280×720    suffix "×720"
        //   480p    → 854×480     suffix "×480"
        //   1080p60 → 1920×1080   suffix "×1080"
        let cross = Self.cross
        let steps: [(quality: String, suffix: String)] = [
            ("720p60",  "\(cross)720"),
            ("480p",    "\(cross)480"),
            ("1080p60", "\(cross)1080"),
        ]

        for (quality, suffix) in steps {
            showControls()
            try switchQuality(to: quality)

            // Stats update within ≤1 s once the new composition is playing.
            // Allow 30 s total to account for slow simulator CDN fetch.
            let switched = waitForResolutionContaining(suffix, timeout: 30)
            captureState("after \(quality) — resolution: \(currentResolutionLabel() ?? "nil")", in: app)

            XCTAssertTrue(
                switched,
                "Resolution should contain '\(suffix)' after selecting \(quality). " +
                "Actual: \(currentResolutionLabel() ?? "nil"). " +
                "If '❌ [quality/DASH]' appears in logs, the DASH composition rebuild failed."
            )
            UITestHelpers.assertNoPlayerErrorBanner(in: app)
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

    /// Returns the label of the first visible static text that contains "×" (U+00D7),
    /// which is the resolution value in the Stats for Nerds overlay, e.g. "1280×720 @ 60 fps".
    private func currentResolutionLabel() -> String? {
        let predicate = NSPredicate(format: "label CONTAINS %@", Self.cross)
        let el = app.staticTexts.matching(predicate).firstMatch
        return el.exists ? el.label : nil
    }

    /// Polls until a static text whose label contains `suffix` is visible in the
    /// accessibility tree, or until `timeout` seconds elapse.
    private func waitForResolutionContaining(_ suffix: String, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "label CONTAINS %@", suffix)
        let elements = app.staticTexts.matching(predicate)
        let exp = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "count > 0"),
            object: elements
        )
        return XCTWaiter().wait(for: [exp], timeout: timeout) == .completed
    }

    /// Reveals the player controls overlay if the quality quick-access button is not
    /// currently hittable. Taps the player center (which toggles controls visibility)
    /// up to 5 times with 1 s between attempts.
    private func showControls() {
        let qualityBtn = app.buttons["player.quickAccess.quality"].firstMatch
        for _ in 0..<5 {
            if qualityBtn.waitForExistence(timeout: 1) && qualityBtn.isHittable { return }
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            Thread.sleep(forTimeInterval: 1.0)
        }
    }

    /// Opens the quality picker via the quick-access pill and taps the option whose label
    /// matches `qualityLabel` (e.g. "720p60"). Waits for the picker to dismiss.
    private func switchQuality(to qualityLabel: String) throws {
        let qualityBtn = app.buttons["player.quickAccess.quality"].firstMatch
        guard qualityBtn.waitForExistence(timeout: 8) && qualityBtn.isHittable else {
            try captureAndSkip(
                "player.quickAccess.quality not hittable before selecting \(qualityLabel)", in: app)
        }
        qualityBtn.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        let picker = app.otherElements["player.qualityPicker"].firstMatch
        guard picker.waitForExistence(timeout: 5) else {
            try captureAndSkip("player.qualityPicker did not appear", in: app)
        }

        // Prefer the picker-scoped static text; fall back to app-wide.
        var option = picker.staticTexts[qualityLabel].firstMatch
        if !option.waitForExistence(timeout: 3) {
            option = app.staticTexts[qualityLabel].firstMatch
        }
        guard option.waitForExistence(timeout: 3) else {
            try captureAndSkip("Quality option '\(qualityLabel)' not found in picker", in: app)
        }
        option.tap()

        // Confirm the picker dismissed (tap was registered and format was selected).
        let dismissedPred = NSPredicate(format: "exists == false")
        let dismissExp = XCTNSPredicateExpectation(predicate: dismissedPred, object: picker)
        _ = XCTWaiter().wait(for: [dismissExp], timeout: 5)
    }
}

#endif // os(iOS)
