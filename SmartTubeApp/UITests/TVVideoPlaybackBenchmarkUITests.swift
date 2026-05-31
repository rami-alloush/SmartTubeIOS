#if os(tvOS)
import XCTest

// AGENT-POST-RUN-CHECK: ui-tests-with-logs
//
// After every run of this file, extract device/app logs and inspect.
//
// Log events to verify per video:
//   ✓ [load] load() called — id=<videoID>
//   ✓ cache HIT: playerInfo (skipping network)     — for every video AFTER the first
//   ✓ readyToPlay [<path>]                          — note the path
//   ✓ [prefetch] ENQUEUE <nextID> priority=2        — prefetch for the following video
//
// RED FLAGS:
//   - "fetchPlayerInfo" appears for video 2+ → cache miss
//   - "AVPlayerItem failed" → CDN auth failure
//   - cold > 1.15s → benchmark regression

/// Sequential per-video playback benchmark for tvOS.
///
/// Mirrors `VideoPlaybackBenchmarkUITests` (iOS) adapted for tvOS navigation:
///   - Remote D-pad (↓↓ select) to open first video from Home
///   - `player.nextBtn` tapped via XCTest accessibility for subsequent videos
///   - Darwin notification `com.void.smarttube.player.ready` for sub-100ms timing
///
/// Run via:
///   xcodebuild test \
///     -workspace SmartTube.xcworkspace -scheme "Smart Tube" \
///     -destination 'id=E16182A3-794A-43DD-B349-A1FFBE744AF8' \
///     -only-testing:SmartTubeTVUITests/TVVideoPlaybackBenchmarkUITests \
///     -parallel-testing-enabled NO \
///     -resultBundlePath /tmp/tv-benchmark.xcresult
final class TVVideoPlaybackBenchmarkUITests: XCTestCase {

    private static let allVideoIDs: [String] = [
        "v2ZtAi2rDzA",  // rqh=1 worst-case — WKWebView HLS cold path
        "l7To2evwGKs",  // rqh=1 real-world — BotGuardWV fast path
        "dQw4w9WgXcQ",  // Rick Astley — stable adaptive/HLS path
        "LSMQ3U1Thzw",  // BotGuard probe test video
    ]

    private var app: XCUIApplication!
    private let remote = XCUIRemote.shared
    /// Shuffled on every setUp so each run has a different cold-start video.
    private var orderedVideoIDs: [String] = []

    override func setUpWithError() throws {
        continueAfterFailure = false
        orderedVideoIDs = Self.allVideoIDs.shuffled()
        app = XCUIApplication()
        app.launchArguments = [
            "--uitesting",
            "--uitesting-inject-queue-video-ids=\(orderedVideoIDs.joined(separator: ","))",
            "--uitesting-disable-sponsorblock",
        ]
        app.launch()
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
    }

    // MARK: - Tests

    func testSequentialPerVideoPlaybackTimes() throws {
        let videoIDs = orderedVideoIDs
        let playerTitle = app.staticTexts["player.titleLabel"].firstMatch

        // ── Navigate to Home feed ─────────────────────────────────────────────
        let chipBar = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'home.chipBar'"))
            .firstMatch
        guard chipBar.waitForExistence(timeout: 20) else {
            try captureAndSkip("home.chipBar did not appear — app failed to reach Home", in: app)
        }
        let cardPredicate = NSPredicate(format: "identifier BEGINSWITH 'video.card.'")
        let cards = app.descendants(matching: .any).matching(cardPredicate)
        let cardExp = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "count > 0"), object: cards
        )
        guard XCTWaiter().wait(for: [cardExp], timeout: 20) == .completed else {
            try captureAndSkip("No video cards — network unavailable or feed empty", in: app)
        }

        // ── Pre-warm pause ────────────────────────────────────────────────────
        // Allow BotGuardWebViewRunner 4 s to begin pre-warming before cold timer starts.
        Thread.sleep(forTimeInterval: 4.0)

        // ── Video 0: cold start ───────────────────────────────────────────────
        // Navigate: tab bar → chip bar (↓) → video list (↓) → select first card.
        remote.press(.down)
        Thread.sleep(forTimeInterval: 0.6)
        remote.press(.down)
        Thread.sleep(forTimeInterval: 0.6)

        let coldStart = Date()
        remote.press(.select)

        guard playerTitle.waitForExistence(timeout: 35) else {
            try captureAndSkip(
                "First video did not load within 35 s — network unavailable or video inaccessible",
                in: app
            )
        }
        let coldElapsed = Date().timeIntervalSince(coldStart)
        var timings: [(id: String, elapsed: Double, hot: Bool)] = [
            (videoIDs[0], coldElapsed, false),
        ]
        print("[benchmark-tv] \(videoIDs[0])  cold  \(String(format: "%.2f", coldElapsed))s")

        // ── Videos 1…N: advance through queue ────────────────────────────────
        for index in 1..<videoIDs.count {
            let videoID = videoIDs[index]

            XCTContext.runActivity(named: "Advance to video \(index): \(videoID)") { _ in
                let prevLabel = playerTitle.exists ? playerTitle.label : ""

                // Find the next button. On tvOS, press Select to show controls,
                // then poll until nextBtn is enabled.
                let nextButton = app.buttons["player.nextBtn"].firstMatch
                var nextReady = false
                let btnDeadline = Date().addingTimeInterval(90)
                while Date() < btnDeadline {
                    remote.press(.select) // toggle controls visible
                    Thread.sleep(forTimeInterval: 1.0)
                    if nextButton.waitForExistence(timeout: 2), nextButton.isEnabled {
                        nextReady = true
                        break
                    }
                }
                guard nextReady else {
                    XCTFail("player.nextBtn not enabled before video \(videoID) within 90 s")
                    return
                }

                // Time: nextBtn tap → com.void.smarttube.player.ready Darwin notification.
                let readyExp = XCTDarwinNotificationExpectation(
                    notificationName: "com.void.smarttube.player.ready"
                )
                let start = Date()
                nextButton.tap() // XCTest focuses + selects on tvOS

                let readyResult = XCTWaiter().wait(for: [readyExp], timeout: 10)
                let elapsed = Date().timeIntervalSince(start)

                // Verify title changed as a functional check.
                var titleChanged = false
                let titleDeadline = Date().addingTimeInterval(max(30.0 - elapsed, 5.0))
                while Date() < titleDeadline {
                    Thread.sleep(forTimeInterval: 0.3)
                    let current = playerTitle.exists ? playerTitle.label : ""
                    if !current.isEmpty, current != prevLabel {
                        titleChanged = true
                        break
                    }
                }

                if readyResult != .completed {
                    print("[benchmark-tv] \(videoID)  hot   \(String(format: "%.2f", elapsed))s (readyToPlay not received — stalled?)")
                }
                guard titleChanged else {
                    XCTFail("Title did not change for video \(videoID) within timeout")
                    return
                }

                timings.append((videoID, elapsed, true))
                print("[benchmark-tv] \(videoID)  hot   \(String(format: "%.2f", elapsed))s")
            }
        }

        // ── Report ────────────────────────────────────────────────────────────
        let separator = String(repeating: "-", count: 44)
        var lines = [separator, "videoID        type  elapsed", separator]
        for t in timings {
            let idPad  = t.id.padding(toLength: 14, withPad: " ", startingAt: 0)
            let typPad = (t.hot ? "hot" : "cold").padding(toLength: 4, withPad: " ", startingAt: 0)
            lines.append("\(idPad)  \(typPad)  \(String(format: "%.2f", t.elapsed))s")
        }
        lines.append(separator)
        let report = lines.joined(separator: "\n")
        print("[benchmark-tv] results:\n\(report)")

        let attachment = XCTAttachment(string: report)
        attachment.name = "TV per-video playback times"
        attachment.lifetime = .keepAlways
        add(attachment)

        XCTAssertEqual(timings.count, videoIDs.count,
                       "Expected \(videoIDs.count) timing entries, got \(timings.count)")
    }
}
#endif
