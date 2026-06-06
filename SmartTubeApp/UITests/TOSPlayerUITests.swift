#if os(macOS)
import XCTest

// MARK: - TOSPlayerUITests
//
// Smoke test for the macOS IFrame (TOS-compliant) player.
//
// What it verifies:
//   1. Tapping the first non-short video card opens the TOS player (close button visible).
//   2. The IFrame player starts playing within 30 s (Darwin notification fires + AX state = "playing").
//   3. No crash / close-button disappearance during 5 s of playback.
//   4. Tapping the close button dismisses the player (close button disappears).
//
// Preconditions:
//   - useTOSPlayerOnMac defaults to true on macOS (AppSettings.swift).
//   - The test passes --uitesting-disable-sponsorblock to avoid SponsorBlock skips
//     interfering with the simple "is it playing?" assertion.

final class TOSPlayerUITests: XCTestCase {

    private var app: XCUIApplication!

    // MARK: - Lifecycle

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = [
            "--uitesting",
            "--uitesting-disable-sponsorblock",
        ]
        // Remove saved macOS window state so WindowGroup always opens a fresh window.
        let savedState = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Saved Application State/com.void.smarttube.app.savedState")
        try? FileManager.default.removeItem(at: savedState)
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        _ = app.windows.firstMatch.waitForExistence(timeout: 10)
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
    }

    // MARK: - Test

    func testTOSPlayerPlaysFirstHomeVideo() throws {
        // ── 1. Wait for the home feed ─────────────────────────────────────────
        let predicate = NSPredicate(format: "identifier BEGINSWITH 'video.card.'")
        let cards = app.descendants(matching: .any).matching(predicate)
        let anyCard = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count > 0"), object: cards)
        guard XCTWaiter().wait(for: [anyCard], timeout: 30) == .completed else {
            throw XCTSkip("No video cards found — network unavailable or home feed empty")
        }

        // Find first non-short card.
        guard let card = firstNonShortCard(from: cards, maxCheck: 20) else {
            throw XCTSkip("No non-short video card found in first 20 cards")
        }

        let cardID = card.identifier  // "video.card.<videoId>"
        print("[TOS] clicking card: \(cardID)")

        // ── 2. Register Darwin expectations BEFORE clicking ───────────────────
        // CRITICAL: The navigation often completes (and notifies) during the 1s
        // animation that precedes the close button appearing. Expectations must
        // be created BEFORE the click so they capture notifications that fire
        // before the close button is visible.
        let loadStartNote  = XCTDarwinNotificationExpectation(notificationName: "com.void.smarttube.tosplayer.loadstarted")
        let navNote        = XCTDarwinNotificationExpectation(notificationName: "com.void.smarttube.tosplayer.navfinished")
        let bridgeNote     = XCTDarwinNotificationExpectation(notificationName: "com.void.smarttube.tosplayer.bridge")
        let readyNote      = XCTDarwinNotificationExpectation(notificationName: "com.void.smarttube.tosplayer.ready")
        let tickStartNote  = XCTDarwinNotificationExpectation(notificationName: "com.void.smarttube.tosplayer.tickstarted")
        let playingNote    = XCTDarwinNotificationExpectation(notificationName: "com.void.smarttube.tosplayer.playing")
        // State-transition diagnostics (via tick handler): observe which states are hit
        let stateBuffNote  = XCTDarwinNotificationExpectation(notificationName: "com.void.smarttube.tosplayer.state.3")
        let stateCuedNote  = XCTDarwinNotificationExpectation(notificationName: "com.void.smarttube.tosplayer.state.5")
        let statePauseNote = XCTDarwinNotificationExpectation(notificationName: "com.void.smarttube.tosplayer.state.2")
        let stateEndedNote = XCTDarwinNotificationExpectation(notificationName: "com.void.smarttube.tosplayer.state.0")

        // ── 3. Tap the card — the TOS player should open ──────────────────────
        if !card.isHittable {
            app.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: 100)
            Thread.sleep(forTimeInterval: 0.5)
        }
        card.click()

        // ── 4. Wait for the close button (player appeared) ───────────────────
        let closeBtn = app.buttons["tosPlayer.closeButton"].firstMatch
        XCTAssertTrue(
            closeBtn.waitForExistence(timeout: 15),
            "tosPlayer.closeButton did not appear — TOS player was not opened (check useTOSPlayerOnMac=true)"
        )
        print("[TOS] ✓ player opened — closeButton visible")

        // ── 5. Collect diagnostic notification results ────────────────────────
        // Stage 0a: Was loadHTMLString even called?
        let loadResult = XCTWaiter().wait(for: [loadStartNote], timeout: 1)
        print("[TOS] loadHTMLString called: \(loadResult == .completed ? "✓ YES" : "✗ NO (loadHTML never called)")")

        // Stage 0b: Nav finished — does WKNavigationDelegate.didFinish fire?
        let navResult = XCTWaiter().wait(for: [navNote], timeout: 5)
        if navResult == .completed {
            print("[TOS] ✓ HTML navigation finished (WKNavigationDelegate.didFinish fired)")
        } else {
            print("[TOS] ✗ HTML navigation did NOT finish — didFinish not called within 6s of click")
        }

        // Stage 1: Bridge check — does JS<->Swift messaging work at all?
        let bridgeTimeout: Double = navResult == .completed ? 3 : 0
        let bridgeResult = navResult == .completed
            ? XCTWaiter().wait(for: [bridgeNote], timeout: bridgeTimeout)
            : .timedOut
        if bridgeResult == .completed {
            print("[TOS] ✓ JS<->Swift bridge confirmed working")
        } else {
            print("[TOS] ✗ JS<->Swift bridge NOT working — window.webkit.messageHandlers unavailable")
        }

        // Stage 2: onPlayerReady — did the iframe_api script load?
        let readyTimeout: Double = bridgeResult == .completed ? 30 : 0
        let readyResult = bridgeResult == .completed
            ? XCTWaiter().wait(for: [readyNote], timeout: readyTimeout)
            : .timedOut
        if readyResult == .completed {
            print("[TOS] ✓ onPlayerReady fired — iframe_api loaded")
        } else if bridgeResult == .completed {
            print("[TOS] ✗ onPlayerReady did NOT fire within 30s — iframe_api script may have failed to load")
        }

        // Stage 2.5: Tick poll — is startPolling() running?
        let tickResult = readyResult == .completed
            ? XCTWaiter().wait(for: [tickStartNote], timeout: 3)
            : .timedOut
        if tickResult == .completed {
            print("[TOS] ✓ tick poll received — startPolling() is running")
        } else if readyResult == .completed {
            print("[TOS] ✗ no tick received within 3s of ready — startPolling() may not be called")
        }

        // Stage 3: playing state
        let playingTimeout: Double = readyResult == .completed ? 15 : 0
        let playResult = readyResult == .completed
            ? XCTWaiter().wait(for: [playingNote], timeout: playingTimeout)
            : .timedOut

        // Also poll the AX state label as a secondary check.
        let stateLabel = app.descendants(matching: .any).matching(identifier: "tosPlayer.stateLabel").firstMatch
        let isPlaying: Bool
        if playResult == .completed {
            isPlaying = true
            print("[TOS] ✓ Darwin notification received — player is playing")
        } else {
            // Darwin notification timed out — check AX state (label or value).
            // On macOS 26, SwiftUI Text exposes text content via AXValue (not AXTitle).
            let labelValue = stateLabel.exists ? stateLabel.label : "(not found)"
            let valueStr   = stateLabel.exists ? (stateLabel.value as? String ?? "") : ""
            let stateStr   = labelValue.isEmpty ? valueStr : labelValue
            isPlaying = stateStr == "playing" || stateStr == "buffering"
            // Report which states were observed (helps diagnose autoplay blocking)
            let seenBuffering = XCTWaiter().wait(for: [stateBuffNote],  timeout: 0) == .completed
            let seenCued      = XCTWaiter().wait(for: [stateCuedNote],  timeout: 0) == .completed
            let seenPaused    = XCTWaiter().wait(for: [statePauseNote], timeout: 0) == .completed
            let seenEnded     = XCTWaiter().wait(for: [stateEndedNote], timeout: 0) == .completed
            let statesSeen    = [seenBuffering ? "buffering(3)" : nil,
                                 seenCued      ? "cued(5)"      : nil,
                                 seenPaused    ? "paused(2)"    : nil,
                                 seenEnded     ? "ended(0)"     : nil]
                .compactMap { $0 }.joined(separator: ",")
            print("[TOS] playing notification timed out — stateLabel='\(stateStr)' states=[\(statesSeen.isEmpty ? "none — stuck at -1/unstarted" : statesSeen)]")
        }

        XCTAssertTrue(
            isPlaying,
            "TOS player did not reach 'playing' state within 30 s — check network, baseURL whitelist, and autoplay config"
        )

        // ── 6. Let it play for 5 s and verify no crash ───────────────────────
        Thread.sleep(forTimeInterval: 5)
        XCTAssertTrue(
            closeBtn.exists,
            "tosPlayer.closeButton disappeared during playback — possible crash or view re-render"
        )
        print("[TOS] ✓ 5 s of playback — no crash")

        // ── 7. Close the player ───────────────────────────────────────────────
        closeBtn.click()

        let closedPredicate = NSPredicate(format: "exists == false")
        let closedExpect = XCTNSPredicateExpectation(predicate: closedPredicate, object: closeBtn)
        let closedResult = XCTWaiter().wait(for: [closedExpect], timeout: 5)
        XCTAssertEqual(
            closedResult, .completed,
            "tosPlayer.closeButton still visible after close tap — player did not dismiss"
        )
        print("[TOS] ✓ player dismissed — test complete")
    }

    // MARK: - Helpers

    private func firstNonShortCard(from query: XCUIElementQuery, maxCheck: Int) -> XCUIElement? {
        let count = min(query.count, maxCheck)
        for i in 0..<count {
            let el = query.element(boundBy: i)
            // AX value "short" is set on short cards by VideoCardView.
            if el.value as? String != "short" { return el }
        }
        return nil
    }
}

#endif // os(macOS)
