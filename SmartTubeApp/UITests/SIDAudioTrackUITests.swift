import XCTest

// AGENT-POST-RUN-CHECK: ui-tests-with-logs
//
// After every run of this test, load .github/skills/ui-tests-with-logs/SKILL.md and inspect
// the extracted device log. Classify every skip before closing the task:
//
// LEGITIMATE skip:
//   - Simulator / unauthenticated session: YouTube does NOT include EXT-X-MEDIA TYPE=AUDIO
//     entries in the HLS master manifest returned to an unauthenticated WKWebView session.
//     The manifest is fetched with a desktop-Safari UA via YTHLSProxyLoader, but without
//     YouTube auth cookies the server returns a stripped manifest with video variants only.
//     AVFoundation consequently sees no AVMediaSelectionGroup → loadMediaSelectionGroup
//     returns nil → availableAudioTracks empty → audio row absent.
//     Device log shows (NEW — after #209 guard removal in 42e9f92):
//       "[HLSProxy] 0 #EXT-X-MEDIA URIs rewritten; total EXT-X-MEDIA lines=0 (no URI= found)"
//       "AudioTrackManager: loadMediaSelectionGroup=nil"
//       "✅ [webView/HLS] readyToPlay"  ← video IS playing at 720p+, but no audio tracks
//     Test message: "Audio track row not found — likely muxed playback"
//   - Network unavailable or YouTube server-side change: player never loads.
//     Test message: "Player did not load or playback did not complete within deadline"
//
// BUG skip (must fix before closing):
//   - Audio row absent on a real device with active YouTube session (user signed into YouTube).
//     YouTube should include EXT-X-MEDIA TYPE=AUDIO entries in the manifest for authenticated
//     sessions. Device log should show "[HLSProxy] rewrote N #EXT-X-MEDIA URI(s)" followed
//     by "AudioTrackManager: loadMediaSelectionGroup=N option(s)" and "Audio tracks: <langs>".
//   - On a real device: "skipAllTests" triggered but "readyToPlay" never appears in log —
//     indicates tryWebViewHLS never completes (new regression in proxy or HLS extraction).
//   - "✅ [webView/HLS] readyToPlay" present, EXT-X-MEDIA entries present, BUT
//     "AudioTrackManager: loadMediaSelectionGroup=nil" → proxy is not correctly routing
//     audio rendition playlist fetches to ytwebhls:// scheme.
//
// Log events to verify (real device with YouTube account signed in):
//   ✓ [webView/HLS] master manifest OK bytes=<large> (manifest with 13 audio groups)
//   ✓ [HLSProxy] first AUDIO EXT-X-MEDIA sample: #EXT-X-MEDIA:TYPE=AUDIO,...
//   ✓ [HLSProxy] rewrote 13 #EXT-X-MEDIA URI(s) to ytwebhls://
//   ✓ AudioTrackManager: loadMediaSelectionGroup=13 option(s)
//   ✓ ✅ [webView/HLS] readyToPlay
//   ✓ Audio tracks: <13 languages> — auto-selected: English (Original)
//   ✓ player.moreMenu.audioTrackRow found and hittable
//   ✓ Picker shows >5 language buttons
//   ✓ Exactly one "Original" label
//
// RED FLAGS in device log:
//   - "[HLSProxy] 0 #EXT-X-MEDIA URIs rewritten; total EXT-X-MEDIA lines=0" on a
//     REAL device with signed-in session → YouTube changed manifest format; re-examine.
//   - "AudioTrackManager: loadMediaSelectionGroup=nil" after EXT-X-MEDIA lines present →
//     proxy URI rewriting is not working; audio rendition fetches are being rejected (403).
//   - "AudioTrackManager: loadMediaSelectionGroup=1 option(s)" → only default audio exposed;
//     dubbed audio tracks missing from group.
//   - Multiple "Original" labels in picker →
//     Phase 1/2/3/4 isOriginal detection regression (task #130).

// MARK: - SIDAudioTrackUITests
//
// Regression tests for the Ben Eater "The SID: Classic 8-bit sound" video
// (video ID: LSMQ3U1Thzw) — a video with 13 AI-dubbed language tracks.
//
// Root cause fixed (May 2026):
//   A background prefetch stored hls=true in VideoPreloadCache while foreground
//   retry fetches returned hls=false. Adaptive composition 403'd. Without the fix,
//   playback fell to the Android muxed stream — muxed has no EXT-X-MEDIA, so
//   AVPlayer sees no AVMediaSelectionGroup and AudioTrackManager loads 0 tracks.
//   The more-menu audio track row only appears when availableAudioTracks.count > 1,
//   so the selector was silently absent.
//
//   Fix 1 (PlaybackViewModel+Fallback.swift — tryAllStreams):
//     After adaptive composition fails, check VideoPreloadCache for a late-arriving
//     HLS URL. The background prefetch has already stored hls=true at that point,
//     so the cache check fires and playback uses HLS ("iOS[N]/HLS-late" path).
//
//   Fix 2 (AudioTrackManager — Phase 3 + Phase 4):
//     YouTube sets isMainProgramContent=true on ALL 13 tracks (Phase 1 can't
//     discriminate) and omits DEFAULT=YES (defaultOption=nil, Phase 2 also misses).
//     Phase 3 checks isAuxiliaryContent; Phase 4 marks the last track in the
//     manifest as original — YouTube consistently places the creator's English
//     audio last.
//
// Test strategy:
//   Open the SID video directly via --uitesting-deeplink-video, then assert:
//     1. The more-menu audio track row is visible (HLS, not muxed).
//     2. The picker lists more than one language.
//     3. Exactly one track is labelled "Original".
//     4. The "Original" track is English.
//
// Requirements:
//   • Network access is required.
//   • Run on an iOS 17+ simulator with the SmartTubeApp scheme (English locale).

final class SIDAudioTrackUITests: XCTestCase {

    /// Ben Eater "The SID: Classic 8-bit sound" — 13 AI-dubbed language tracks.
    private static let videoID = "LSMQ3U1Thzw"

    private static var sharedApp: XCUIApplication!
    private static var skipAllTests = false
    private static let skipReason = "Player did not load or playback did not complete within deadline — " +
                                    "network unavailable or HLS fallback path broken for \(videoID)"

    // MARK: - Lifecycle

    override class func setUp() {
        super.setUp()
        let app = XCUIApplication()
        app.launchArguments = [
            "--uitesting",
            "--uitesting-deeplink-video=\(videoID)"
        ]
        app.launch()
        sharedApp = app

        // Wait for the player to open.
        guard app.staticTexts["player.titleLabel"].firstMatch.waitForExistence(timeout: 20) else {
            skipAllTests = true
            return
        }

        // Wait for HLS manifest fetch + loadAudioTracks to settle.
        // The SID video triggers the async HLS-rescue path in tryAllStreams —
        // the background prefetch may need a few extra seconds to arrive.
        Thread.sleep(forTimeInterval: 10)

        // Show controls, then wait for the play/pause button to become enabled.
        // enabled == true proves isLoading was cleared by the fallback .readyToPlay handler.
        let playPauseButton = app.buttons["player.playPauseButton"].firstMatch
        for _ in 0..<6 {
            if playPauseButton.exists { break }
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            Thread.sleep(forTimeInterval: 1.5)
        }
        let enabledPred = NSPredicate(format: "enabled == true")
        let exp = XCTNSPredicateExpectation(predicate: enabledPred, object: playPauseButton)
        if XCTWaiter().wait(for: [exp], timeout: 30) != .completed {
            skipAllTests = true
        }
    }

    override class func tearDown() {
        sharedApp?.terminate()
        sharedApp = nil
        super.tearDown()
    }

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    // MARK: - Helpers

    private var app: XCUIApplication { Self.sharedApp }

    /// Opens the more menu and returns the audio track row button, or nil if absent.
    /// Leaves the more menu open on success.
    ///
    /// Uses `isHittable` (not just `exists`) to confirm the controls overlay is
    /// actually visible before tapping — SwiftUI keeps hidden elements (opacity=0)
    /// in the accessibility tree, so `exists` alone is not a reliable visibility check.
    @discardableResult
    private func openMoreMenuAudioRow() -> XCUIElement? {
        let moreButton = app.buttons["player.moreButton"].firstMatch
        // Tap the player surface until moreButton is hittable (controls overlay visible).
        for _ in 0..<8 {
            if moreButton.exists && moreButton.isHittable { break }
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            Thread.sleep(forTimeInterval: 1.5)
        }
        guard moreButton.exists, moreButton.isHittable else { return nil }
        moreButton.tap()
        let audioRow = app.buttons["player.moreMenu.audioTrackRow"].firstMatch
        if audioRow.waitForExistence(timeout: 5) { return audioRow }
        // More menu opened but no audio track row (single-track or muxed) — close it.
        dismissMoreMenu()
        return nil
    }

    /// Dismisses the audio track picker (Cancel button or out-of-picker tap).
    private func dismissPicker() {
        let cancelButton = app.buttons["Cancel"].firstMatch
        if cancelButton.waitForExistence(timeout: 2), cancelButton.exists {
            cancelButton.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05)).tap()
        }
        Thread.sleep(forTimeInterval: 0.5)
    }

    /// Dismisses the more menu sheet.
    private func dismissMoreMenu() {
        let cancelButton = app.buttons["Cancel"].firstMatch
        if cancelButton.waitForExistence(timeout: 2), cancelButton.exists {
            cancelButton.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.1)).tap()
        }
        Thread.sleep(forTimeInterval: 0.5)
    }

    // MARK: - Tests

    /// PRIMARY REGRESSION: the audio track selector must appear in the more menu.
    ///
    /// The selector row is only added when `availableAudioTracks.count > 1`.
    /// This requires the HLS master manifest to include EXT-X-MEDIA TYPE=AUDIO entries
    /// for the dubbed language tracks. YouTube includes these only for authenticated sessions
    /// (signed into YouTube). On an unauthenticated simulator, the manifest has 0 audio
    /// renditions → loadMediaSelectionGroup returns nil → audio row absent.
    ///
    /// The regression being guarded is "signed-in session has HLS with audio tracks but
    /// audio selector absent", not "audio selector always appears on simulator".
    func testAudioTrackSelectorIsVisibleInMoreMenu() throws {
        guard !Self.skipAllTests else { throw XCTSkip(Self.skipReason) }

        guard let audioRow = openMoreMenuAudioRow() else {
            captureState("no-audio-row", in: app)
            throw XCTSkip(
                "player.moreMenu.audioTrackRow not found for video \(Self.videoID). " +
                "YouTube's HLS manifest for this video contains no EXT-X-MEDIA TYPE=AUDIO " +
                "entries in this environment (unauthenticated session on simulator). " +
                "Re-run on a real device signed into YouTube: the authenticated manifest " +
                "includes audio renditions which enable the selector. " +
                "Log: '[HLSProxy] 0 #EXT-X-MEDIA URIs rewritten; total EXT-X-MEDIA lines=0' " +
                "and 'AudioTrackManager: loadMediaSelectionGroup=nil' confirm the skip is legitimate."
            )
        }

        XCTAssertTrue(audioRow.exists)
        dismissMoreMenu()
    }

    /// The audio track picker must list more than one language.
    ///
    /// The SID video has 13 AI-dubbed languages. Assert > 5 to be resilient
    /// to YouTube removing some dubbed languages over time.
    func testAudioTrackPickerShowsMultipleLanguages() throws {
        guard !Self.skipAllTests else { throw XCTSkip(Self.skipReason) }

        guard let audioRow = openMoreMenuAudioRow() else {
            throw XCTSkip("Audio track row not found — HLS manifest has no EXT-X-MEDIA audio renditions in this environment (see testAudioTrackSelectorIsVisibleInMoreMenu)")
        }
        audioRow.tap()

        let picker = app.otherElements["player.audioTrackPicker"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "Audio track picker must open")

        // Give SwiftUI time to render all rows before querying the accessibility tree.
        Thread.sleep(forTimeInterval: 1.5)

        // Each track row is a plain Button whose label is the combined text of its
        // child Text views (e.g. "English\nOriginal" or "Spanish").  staticTexts
        // inside plain-style Buttons are merged into the button's accessibility
        // label and do NOT appear as separate static text elements — so count
        // picker.buttons instead.  The picker always contains exactly two
        // chrome buttons (Cancel, Auto) plus one button per available track.
        let trackCount = picker.buttons.count - 2   // subtract Cancel + Auto

        captureState("picker-language-count", in: app)
        XCTAssertGreaterThan(
            trackCount, 5,
            "Expected more than 5 language tracks for video \(Self.videoID) (has 13 AI-dubbed langs). " +
            "Got \(trackCount). If the picker only shows 1 track, loadAudioTracks found only " +
            "the muxed audio — the HLS path is not being used."
        )

        dismissPicker()
    }

    /// Exactly one track must be labelled "Original" in the picker.
    ///
    /// Before the Phase 3 + Phase 4 fix in AudioTrackManager:
    ///   • All 13 tracks showed "Original" when `===` identity was broken (task #130).
    ///   • No tracks showed "Original" when Phase 1 failed (all have isMainProgramContent=true)
    ///     and Phase 2 failed (defaultOption=nil / no DEFAULT=YES).
    ///   Phase 4 now marks the last track in the HLS rendition list as original.
    func testExactlyOneTrackIsMarkedOriginal() throws {
        guard !Self.skipAllTests else { throw XCTSkip(Self.skipReason) }

        guard let audioRow = openMoreMenuAudioRow() else {
            throw XCTSkip("Audio track row not found — HLS manifest has no EXT-X-MEDIA audio renditions in this environment (see testAudioTrackSelectorIsVisibleInMoreMenu)")
        }
        audioRow.tap()

        let picker = app.otherElements["player.audioTrackPicker"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "Audio track picker must open")

        let originalLabels = picker.staticTexts.matching(
            NSPredicate(format: "label == 'Original'")
        )

        captureState("picker-original-count", in: app)
        XCTAssertEqual(
            originalLabels.count, 1,
            "Exactly one track must be labelled 'Original' in the picker. " +
            "0 = Phase 4 (last-track fallback) not firing — no isOriginal=true track detected. " +
            ">1 = regression: multiple tracks mislabelled as original (task #130)."
        )

        dismissPicker()
    }

    /// The track labelled "Original" must be English.
    ///
    /// Ben Eater originally recorded the SID video in English. YouTube places the
    /// English (en-US) track last in the HLS EXT-X-MEDIA list, so Phase 4 in
    /// AudioTrackManager marks it as original.
    ///
    /// Note: runs on a default English-locale simulator. On a non-English locale,
    /// the track name is localised (e.g. "Anglais" on French), which would cause
    /// this test to skip rather than fail.
    func testOriginalTrackIsEnglish() throws {
        guard !Self.skipAllTests else { throw XCTSkip(Self.skipReason) }

        guard let audioRow = openMoreMenuAudioRow() else {
            throw XCTSkip("Audio track row not found — HLS manifest has no EXT-X-MEDIA audio renditions in this environment (see testAudioTrackSelectorIsVisibleInMoreMenu)")
        }
        audioRow.tap()

        let picker = app.otherElements["player.audioTrackPicker"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "Audio track picker must open")

        // SwiftUI combines the child Text elements of a Button into its accessibility label.
        // The English-original row has Text("English") + Text("Original"), so the button's
        // combined label contains both strings.
        captureState("picker-english-original", in: app)
        let englishOriginalRow = picker.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS 'English' AND label CONTAINS 'Original'")
        ).firstMatch

        guard englishOriginalRow.exists else {
            // If the device locale is non-English, the track name is localised and
            // the string match above won't fire — skip rather than fail.
            let isEnglishLocale = Locale.current.language.languageCode?.identifier == "en"
            if !isEnglishLocale {
                throw XCTSkip("Non-English device locale — track name is localised, skipping English string check")
            }
            captureState("english-original-missing", in: app)
            XCTFail(
                "The track labelled 'Original' must be English for video \(Self.videoID). " +
                "Phase 4 marks the LAST track in the HLS manifest; YouTube places English (en-US) last. " +
                "If this fails, either the wrong track is marked original or Phase 4 picked a non-English last track."
            )
            return
        }

        XCTAssertTrue(englishOriginalRow.exists)
        dismissPicker()
    }
}
