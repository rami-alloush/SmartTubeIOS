#if os(macOS)
import Foundation
import CoreFoundation
import WebKit
import SmartTubeIOSCore
import os

private let tosLog = Logger(subsystem: "com.void.smarttube.app", category: "TOSPlayer")

// MARK: - YTPlayerState

/// Maps the numeric state code returned by the YouTube IFrame API.
enum YTPlayerState: Int {
    case unstarted  = -1
    case ended      =  0
    case playing    =  1
    case paused     =  2
    case buffering  =  3
    case cued       =  5
    case unknown    = 999

    init(raw: Int) {
        self = YTPlayerState(rawValue: raw) ?? .unknown
    }
}

// MARK: - TOSPlayerError

enum TOSPlayerError: Equatable {
    /// Video does not allow embedding (IFrame error 101 / 150).
    case embeddingDisabled
    /// Video not found (IFrame error 100).
    case notFound
    /// Generic IFrame player error.
    case iframeError(Int)
    /// WKWebView failed to load the player HTML.
    case webViewLoadFailed

    var isFatal: Bool {
        switch self {
        case .embeddingDisabled, .notFound: return true
        default: return false
        }
    }
}

// MARK: - TOSPlayerViewModel

/// State owner for the macOS IFrame-based TOS-compliant player.
///
/// Responsibilities:
/// - Owns and configures the `WKWebView` instance with the YouTube IFrame HTML.
/// - Receives JS callbacks via `WKScriptMessageHandler` ("ytCallback").
/// - Exposes playback state (isPlaying, currentTime, duration, speed).
/// - Fetches and applies SponsorBlock skips via JS `seekTo()`.
/// - Exposes `playerError` so `TOSPlayerView` can fall back to `PlayerView`.
///
/// All mutation is `@MainActor`. The `WKScriptMessageHandler` bridge posts
/// messages back to main actor using `Task { @MainActor in ... }`.
@MainActor
@Observable
final class TOSPlayerViewModel: NSObject {

    // MARK: - Public state

    var playerState: YTPlayerState = .unstarted
    var currentTime: Double = 0
    var duration: Double = 0
    var playbackRate: Double = 1.0
    var isReady: Bool = false
    /// Non-nil when the player encounters an error that requires falling back.
    var playerError: TOSPlayerError? = nil

    // MARK: - SponsorBlock

    var sponsorSegments: [SponsorSegment] = []
    /// The segment currently showing a skip toast, if any.
    var currentToastSegment: SponsorSegment? = nil

    // MARK: - Dependencies

    /// Updated from `TOSPlayerView` via `updateSettings(_:)` on `.onAppear` and
    /// `.onChange(of: store.settings)`, mirroring the `PlaybackViewModel` pattern.
    private(set) var settings: AppSettings = AppSettings()
    private let sponsorService = SponsorBlockService()

    // MARK: - Internal

    let webView: WKWebView
    private let videoId: String
    /// Guards against re-triggering a skip within the same segment.
    private var activeSkipEnd: Double? = nil
    /// Strong reference to the WKWebView's navigation delegate (WKWebView retains it weakly).
    private var navigationDelegate: TOSNavigationDelegate?
    /// Fires the "tickstarted" Darwin notification on the first tick received.
    private var hasReceivedFirstTick = false

    // MARK: - Init

    init(videoId: String, startTime: Double = 0) {
        self.videoId = videoId

        let config = WKWebViewConfiguration()
        // Allow autoplay without a user gesture.
        config.mediaTypesRequiringUserActionForPlayback = []
        // macOS WKWebView enables PiP natively for HTML5 video — no extra config needed.

        let contentController = WKUserContentController()
        // Message handler name must match `window.webkit.messageHandlers.ytCallback`
        // in the IFrame HTML. We register a proxy here then set the real handler after
        // super.init because self is not available before init completes.
        let proxyHandler = ScriptMessageProxy()
        // Use .pageWorld explicitly so the handler is available to page-context JS
        // (the default add(_:name:) registers in all worlds but on macOS 26 we are explicit).
        contentController.add(proxyHandler, contentWorld: .page, name: "ytCallback")
        config.userContentController = contentController

        self.webView = WKWebView(frame: .zero, configuration: config)
        self.webView.setValue(false, forKey: "drawsBackground")  // transparent bg

        super.init()

        proxyHandler.target = self

        // Navigation delegate: separate NSObject so actor isolation doesn't
        // interfere with Objective-C delegate dispatch on macOS 26 / Swift 6.
        let navDel = TOSNavigationDelegate()
        self.webView.navigationDelegate = navDel
        // Retain the delegate strongly — WKWebView only holds it weakly.
        self.navigationDelegate = navDel

        loadHTML(videoId: videoId, startTime: startTime)
    }

    deinit {
        // Remove the message handler to break the retain cycle WKWebView ↔ handler.
        // Must match the contentWorld used when adding (pageWorld).
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "ytCallback", contentWorld: .page)
    }

    // MARK: - Settings update

    /// Called from `TOSPlayerView.onAppear` and `onChange(of: store.settings)`.
    /// Mirrors `PlaybackViewModel.updateSettings(_:)`.
    func updateSettings(_ newSettings: AppSettings) {
        settings = newSettings
    }

    // MARK: - JS Commands

    func play() {
        eval("play()")
    }

    func pause() {
        eval("pause()")
    }

    func seekTo(_ seconds: Double) {
        eval("seekTo(\(seconds))")
    }

    func setPlaybackRate(_ rate: Double) {
        eval("setRate(\(rate))")
    }

    // MARK: - JS Message Handling

    /// Called from `ScriptMessageProxy` (main thread guaranteed by WKWebView).
    func handleScriptMessage(_ body: String) {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String
        else {
            tosLog.debug("[ytCallback] unparseable message: \(body)")
            return
        }

        switch type {
        case "ping":
            tosLog.notice("[ytCallback] JS<->Swift bridge ping received")
            CFNotificationCenterPostNotification(
                CFNotificationCenterGetDarwinNotifyCenter(),
                CFNotificationName("com.void.smarttube.tosplayer.bridge" as CFString),
                nil, nil, true
            )

        case "ready":
            isReady = true
            duration = (json["duration"] as? Double) ?? 0
            tosLog.notice("[ytCallback] ready — duration=\(self.duration, format: .fixed(precision: 1))s")
            // Signal UI tests that onPlayerReady fired (JS <-> Swift bridge is working).
            CFNotificationCenterPostNotification(
                CFNotificationCenterGetDarwinNotifyCenter(),
                CFNotificationName("com.void.smarttube.tosplayer.ready" as CFString),
                nil, nil, true
            )
            // Muted playback bypasses cross-origin iframe autoplay restrictions in WKWebView.
            // onPlayerReady in JS also calls mute()+playVideo(), but we repeat from Swift
            // as a belt-and-suspenders in case the JS call was suppressed.
            eval("ytPlayer.mute(); ytPlayer.playVideo();")
            Task { await self.fetchSponsorSegments() }

        case "stateChange":
            let raw = (json["state"] as? Int) ?? 999
            playerState = YTPlayerState(raw: raw)
            tosLog.debug("[ytCallback] stateChange → \(raw)")
            if playerState == .playing {
                // Notify UI tests that the IFrame player has started playback.
                // Mirrors com.void.smarttube.player.ready used by AVPlayer path.
                CFNotificationCenterPostNotification(
                    CFNotificationCenterGetDarwinNotifyCenter(),
                    CFNotificationName("com.void.smarttube.tosplayer.playing" as CFString),
                    nil, nil, true
                )
            }

        case "rateChange":
            playbackRate = (json["rate"] as? Double) ?? 1.0

        case "tick":
            let t = (json["t"] as? Double) ?? 0
            let s = (json["state"] as? Int) ?? 999
            currentTime = t
            let newState = YTPlayerState(raw: s)
            // Diagnostics: fire tickstarted on first tick, playing on state=1.
            if !hasReceivedFirstTick {
                hasReceivedFirstTick = true
                tosLog.notice("[ytCallback] first tick received — state=\(s) t=\(t, format: .fixed(precision: 2))s")
                CFNotificationCenterPostNotification(
                    CFNotificationCenterGetDarwinNotifyCenter(),
                    CFNotificationName("com.void.smarttube.tosplayer.tickstarted" as CFString),
                    nil, nil, true
                )
            }
            if newState == .playing && playerState != .playing {
                tosLog.notice("[ytCallback] tick detected playing state — firing notification")
                CFNotificationCenterPostNotification(
                    CFNotificationCenterGetDarwinNotifyCenter(),
                    CFNotificationName("com.void.smarttube.tosplayer.playing" as CFString),
                    nil, nil, true
                )
            }
            if newState == .buffering && playerState != .buffering {
                tosLog.notice("[ytCallback] tick detected buffering state")
            }
            if newState != playerState {
                tosLog.notice("[ytCallback] tick state changed: \(self.playerState.rawValue) → \(s) at t=\(t, format: .fixed(precision: 1))s")
            }
            playerState = newState
            checkSponsorSkip(at: t)

        case "error":
            let code = (json["code"] as? Int) ?? -1
            tosLog.warning("[ytCallback] error code=\(code)")
            switch code {
            case 101, 150:
                playerError = .embeddingDisabled
            case 100:
                playerError = .notFound
            default:
                playerError = .iframeError(code)
            }

        default:
            break
        }
    }

    // MARK: - SponsorBlock

    private func fetchSponsorSegments() async {
        guard settings.sponsorBlockEnabled,
              !settings.activeSponsorCategories.isEmpty
        else { return }

        let segments = await sponsorService.fetchSegments(
            videoId: videoId,
            categories: settings.activeSponsorCategories
        )
        sponsorSegments = segments
        tosLog.notice("[SponsorBlock] loaded \(segments.count) segment(s) for \(self.videoId)")
    }

    private func checkSponsorSkip(at time: Double) {
        guard settings.sponsorBlockEnabled else {
            currentToastSegment = nil
            return
        }

        // Clear active skip guard when we've passed the skip end point.
        if let end = activeSkipEnd, time >= end { activeSkipEnd = nil }

        guard let seg = sponsorSegments.first(where: { time >= $0.start && time < $0.end }) else {
            currentToastSegment = nil
            return
        }

        switch settings.sponsorAction(for: seg.category) {
        case .skip:
            guard activeSkipEnd == nil else { return }
            activeSkipEnd = seg.end
            currentToastSegment = nil
            seekTo(seg.end)
            tosLog.notice("[SponsorBlock] auto-skip \(seg.category.rawValue) → \(seg.end, format: .fixed(precision: 1))s")

        case .showToast:
            currentToastSegment = seg

        case .nothing:
            currentToastSegment = nil
        }
    }

    // MARK: - Private helpers

    private func eval(_ js: String) {
        webView.evaluateJavaScript(js) { _, error in
            if let error {
                tosLog.debug("[eval] \(js) → \(error)")
            }
        }
    }

    private func loadHTML(videoId: String, startTime: Double) {
        let html = Self.buildHTML(videoId: videoId, startTime: startTime)
        // Use nil baseURL: a remote baseURL (e.g. https://www.youtube.com) causes
        // macOS WebKit to deny window.webkit.messageHandlers access for security.
        // The IFrame API script uses an absolute URL so no baseURL is needed.
        tosLog.notice("[loadHTML] calling loadHTMLString — navigation should fire didFinish shortly")
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName("com.void.smarttube.tosplayer.loadstarted" as CFString),
            nil, nil, true
        )
        webView.loadHTMLString(html, baseURL: nil)
    }

    // MARK: - HTML template

    private static func buildHTML(videoId: String, startTime: Double) -> String {
        // Language from current locale (BCP-47 short code).
        let lang = Locale.current.language.languageCode?.identifier ?? "en"
        let startSecs = Int(startTime)
        // controls:1 = Phase 1 (YouTube's own chrome visible).
        // This is intentional for the experiment — we evaluate behaviour before
        // hiding controls and painting our own overlay in Phase 2.
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta name="viewport" content="width=device-width, initial-scale=1, user-scalable=no">
        <style>
          * { margin: 0; padding: 0; box-sizing: border-box; }
          body, html { width: 100%; height: 100%; background: #000; overflow: hidden; }
          #player { position: absolute; top: 0; left: 0; width: 100%; height: 100%; }
        </style>
        </head>
        <body>
        <div id="player"></div>
        <script>
          var tag = document.createElement('script');
          tag.src = "https://www.youtube.com/iframe_api";
          tag.onerror = function() {
            postMessage('error', { code: -999 }); // iframe_api failed to load
          };
          document.head.appendChild(tag);

          var ytPlayer;

          function onYouTubeIframeAPIReady() {
            ytPlayer = new YT.Player('player', {
              videoId: '\(videoId)',
              playerVars: {
                controls: 1,
                playsinline: 1,
                rel: 0,
                modestbranding: 1,
                autoplay: 1,
                start: \(startSecs),
                hl: '\(lang)',
                iv_load_policy: 3
              },
              events: {
                onReady:             onPlayerReady,
                onStateChange:       onPlayerStateChange,
                onError:             onPlayerError,
                onPlaybackRateChange: onPlaybackRateChange
              }
            });
          }

          function onPlayerReady(e) {
            // Muted autoplay works on all browsers/WKWebView; unmuted autoplay
            // is blocked by macOS WKWebView cross-origin iframe autoplay policy.
            ytPlayer.mute();
            ytPlayer.playVideo();
            postMessage('ready', { duration: ytPlayer.getDuration() });
            startPolling();
          }
          function onPlayerStateChange(e) {
            postMessage('stateChange', { state: e.data });
          }
          function onPlayerError(e) {
            postMessage('error', { code: e.data });
          }
          function onPlaybackRateChange(e) {
            postMessage('rateChange', { rate: e.data });
          }

          // Poll currentTime at 250 ms intervals for SponsorBlock.
          function startPolling() {
            setInterval(function() {
              if (ytPlayer && ytPlayer.getCurrentTime) {
                postMessage('tick', {
                  t: ytPlayer.getCurrentTime(),
                  state: ytPlayer.getPlayerState()
                });
              }
            }, 250);
          }

          function postMessage(type, data) {
            var payload = JSON.stringify(Object.assign({ type: type }, data));
            window.webkit.messageHandlers.ytCallback.postMessage(payload);
          }

          // Immediately ping Swift to verify the JS<->Swift message bridge is working.
          // This fires before the iframe_api script loads, so it tells us if the bridge
          // is broken even when YouTube's script fails to load.
          (function() {
            try { postMessage('ping', {}); } catch(e) {}
          })();

          // Commands called from Swift via evaluateJavaScript.
          function play()       { if (ytPlayer) ytPlayer.playVideo(); }
          function pause()      { if (ytPlayer) ytPlayer.pauseVideo(); }
          function seekTo(t)    { if (ytPlayer) ytPlayer.seekTo(t, true); }
          function setRate(r)   { if (ytPlayer) ytPlayer.setPlaybackRate(r); }
          function setVolume(v) { if (ytPlayer) ytPlayer.setVolume(v); }
        </script>
        </body>
        </html>
        """
    }
}

// MARK: - TOSNavigationDelegate

/// Separate NSObject navigation delegate to ensure Objective-C dispatch works
/// correctly when the view model is a `@MainActor @Observable` actor-isolated class.
/// WKWebView holds a weak reference — TOSPlayerViewModel retains this strongly.
private final class TOSNavigationDelegate: NSObject, WKNavigationDelegate {

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Signal navigation completion for diagnostics.
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName("com.void.smarttube.tosplayer.navfinished" as CFString),
            nil, nil, true
        )
        tosLog.notice("[nav] HTML navigation finished — probing bridge via evaluateJavaScript")
        // Probe the bridge from the Swift side: if window.webkit.messageHandlers.ytCallback
        // is available, posting a ping here will fire the Darwin "bridge" notification.
        let js = """
        (function() {
            try {
                window.webkit.messageHandlers.ytCallback.postMessage('{"type":"ping"}');
            } catch(e) {}
        })();
        """
        webView.evaluateJavaScript(js) { result, error in
            if let error { tosLog.warning("[nav] evaluateJavaScript ping error: \(error)") }
        }
    }

    func webView(_ webView: WKWebView,
                 didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        tosLog.error("[nav] provisional navigation failed: \(error)")
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName("com.void.smarttube.tosplayer.navfinished" as CFString),
            nil, nil, true
        )
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        tosLog.error("[nav] navigation failed: \(error)")
    }
}

// MARK: - ScriptMessageProxy

/// Breaks the retain cycle: `WKUserContentController` retains its handlers strongly.
/// This lightweight proxy holds a `weak` reference to the real handler target so
/// `TOSPlayerViewModel` is not kept alive by the web view's content controller.
private final class ScriptMessageProxy: NSObject, WKScriptMessageHandler, @unchecked Sendable {
    weak var target: TOSPlayerViewModel?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? String else { return }
        Task { @MainActor [weak target] in
            target?.handleScriptMessage(body)
        }
    }
}

#endif // os(macOS)
