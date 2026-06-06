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
    /// WKWebView failed to load the player page.
    case webViewLoadFailed

    var isFatal: Bool {
        switch self {
        case .embeddingDisabled, .notFound, .webViewLoadFailed: return true
        case .iframeError(153): return true  // Video player configuration error
        default: return false
        }
    }
}

// MARK: - TOSPlayerViewModel

/// State owner for the macOS TOS-compliant YouTube embed player.
///
/// Architecture: loads `https://www.youtube.com/embed/{videoId}` directly in WKWebView
/// (not via the IFrame API in our own HTML), then injects `stateDetectionJS` to poll
/// the `<video>` element and relay state via `window.webkit.messageHandlers.ytCallback`.
///
/// All mutation is `@MainActor`. The `WKScriptMessageHandler` bridge dispatches back
/// to main actor via `Task { @MainActor in ... }`.
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

    private(set) var settings: AppSettings = AppSettings()
    private let sponsorService = SponsorBlockService()

    // MARK: - Internal

    let webView: WKWebView
    private let videoId: String
    private let startTime: Double
    /// Guards against re-triggering a skip within the same segment.
    private var activeSkipEnd: Double? = nil
    /// Strong reference to the WKWebView's navigation delegate (WKWebView retains it weakly).
    private var navigationDelegate: TOSNavigationDelegate?
    /// Fires the "tickstarted" Darwin notification on the first tick received.
    private var hasReceivedFirstTick = false
    /// Prevents loadEmbed from firing in instances SwiftUI creates-then-discards during init.
    private var hasStartedLoading = false

    // MARK: - Init

    init(videoId: String, startTime: Double = 0) {
        self.videoId = videoId
        self.startTime = startTime

        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []

        let contentController = WKUserContentController()
        let proxyHandler = ScriptMessageProxy()
        contentController.add(proxyHandler, contentWorld: .page, name: "ytCallback")

        // Hide window.webkit BEFORE any page script runs. YouTube's embed player
        // checks window.webkit.messageHandlers to detect a WKWebView environment and
        // fires error 153 when found. Hiding it lets the player treat this as a normal
        // browser. The native ytCallback reference is saved as window.__nativeYTCallback
        // for use by stateDetectionJS (injected later at atDocumentEnd).
        let webkitHiderScript = WKUserScript(
            source: Self.webkitHiderJS,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false,
            in: .page
        )
        contentController.addUserScript(webkitHiderScript)

        // Inject state-detection JS into every frame at document-end.
        // The YouTube embed runs inside an <iframe> (see loadEmbed), so
        // forMainFrameOnly: false is required to reach the iframe's document.
        let detectionScript = WKUserScript(
            source: Self.stateDetectionJS,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: false,
            in: .page
        )
        contentController.addUserScript(detectionScript)

        config.userContentController = contentController

        self.webView = WKWebView(frame: .zero, configuration: config)
        self.webView.setValue(false, forKey: "drawsBackground")

        super.init()

        proxyHandler.target = self

        // Separate NSObject navigation delegate avoids Swift 6 @MainActor isolation
        // interfering with Objective-C WKNavigationDelegate dispatch.
        let navDel = TOSNavigationDelegate()
        self.webView.navigationDelegate = navDel
        self.navigationDelegate = navDel

        // loadEmbed is NOT called here — SwiftUI calls View.init() many times during
        // layout (creating and discarding State(initialValue:) values). Only the instance
        // that actually appears calls startIfNeeded() from onAppear.
    }

    /// Called from TOSPlayerView.onAppear. Safe to call multiple times — loads only once.
    func startIfNeeded() {
        guard !hasStartedLoading else { return }
        hasStartedLoading = true
        loadEmbed(videoId: videoId, startTime: startTime)
    }

    deinit {
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: "ytCallback",
            contentWorld: .page
        )
    }

    // MARK: - Settings update

    /// Called from `TOSPlayerView.onAppear`. Mirrors `PlaybackViewModel.updateSettings(_:)`.
    func updateSettings(_ newSettings: AppSettings) {
        settings = newSettings
    }

    // MARK: - JS Commands (operating on YouTube embed page's <video> element)

    func play() {
        eval("var v=document.querySelector('video');if(v)v.play();")
    }

    func pause() {
        eval("var v=document.querySelector('video');if(v)v.pause();")
    }

    func seekTo(_ seconds: Double) {
        eval("var v=document.querySelector('video');if(v)v.currentTime=\(seconds);")
    }

    func setPlaybackRate(_ rate: Double) {
        eval("var v=document.querySelector('video');if(v)v.playbackRate=\(rate);")
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
            CFNotificationCenterPostNotification(
                CFNotificationCenterGetDarwinNotifyCenter(),
                CFNotificationName("com.void.smarttube.tosplayer.ready" as CFString),
                nil, nil, true
            )
            // play() is intentionally NOT called here. "ready" fires only after
            // video.duration > 0, meaning YouTube's MSE stream is initialised.
            // The JS pollVideo() already called video.play() at that point (see
            // stateDetectionJS), so calling it again from Swift would be a no-op or
            // could interrupt the stream seek in progress.
            Task { await self.fetchSponsorSegments() }

        case "stateChange":
            let raw = (json["state"] as? Int) ?? 999
            playerState = YTPlayerState(raw: raw)
            tosLog.debug("[ytCallback] stateChange → \(raw)")
            if playerState == .playing {
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
            if !hasReceivedFirstTick {
                hasReceivedFirstTick = true
                tosLog.notice("[ytCallback] first tick — state=\(s) t=\(t, format: .fixed(precision: 2))s")
                CFNotificationCenterPostNotification(
                    CFNotificationCenterGetDarwinNotifyCenter(),
                    CFNotificationName("com.void.smarttube.tosplayer.tickstarted" as CFString),
                    nil, nil, true
                )
            }
            let wasActivelyPlaying = playerState == .playing || playerState == .buffering
            let isNowActivelyPlaying = newState == .playing || newState == .buffering
            if isNowActivelyPlaying && !wasActivelyPlaying {
                tosLog.notice("[ytCallback] tick detected active playback (state=\(s)) — firing playing notification")
                CFNotificationCenterPostNotification(
                    CFNotificationCenterGetDarwinNotifyCenter(),
                    CFNotificationName("com.void.smarttube.tosplayer.playing" as CFString),
                    nil, nil, true
                )
            }
            if newState != playerState {
                tosLog.notice("[ytCallback] tick state: \(self.playerState.rawValue) → \(s) at t=\(t, format: .fixed(precision: 1))s")
                CFNotificationCenterPostNotification(
                    CFNotificationCenterGetDarwinNotifyCenter(),
                    CFNotificationName("com.void.smarttube.tosplayer.state.\(s)" as CFString),
                    nil, nil, true
                )
            }
            playerState = newState
            checkSponsorSkip(at: t)

        case "error":
            let code = (json["code"] as? Int) ?? -1
            let errText = (json["text"] as? String) ?? ""
            let errName: String
            switch code {
            case 2:        errName = "invalid-param";          playerError = .iframeError(code)
            case 5:        errName = "html5-not-supported";    playerError = .iframeError(code)
            case 100:      errName = "video-not-found";        playerError = .notFound
            case 101, 150: errName = "embedding-disabled";     playerError = .embeddingDisabled
            case 153:      errName = "player-config-error";    playerError = .iframeError(code)
            default:       errName = "unknown(\(code))";       playerError = .iframeError(code)
            }
            tosLog.notice("[ytCallback] ❌ player error \(code) (\(errName)) text='\(errText)' isFatal=\(self.playerError?.isFatal ?? false)")
            CFNotificationCenterPostNotification(
                CFNotificationCenterGetDarwinNotifyCenter(),
                CFNotificationName("com.void.smarttube.tosplayer.error.\(code)" as CFString),
                nil, nil, true
            )

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

    // MARK: - Embed URL loader

    private func loadEmbed(videoId: String, startTime: Double) {
        var comps = URLComponents(string: "https://www.youtube.com/embed/\(videoId)")!
        comps.queryItems = [
            URLQueryItem(name: "autoplay",       value: "1"),
            URLQueryItem(name: "mute",           value: "1"),
            URLQueryItem(name: "controls",       value: "1"),
            URLQueryItem(name: "playsinline",    value: "1"),
            URLQueryItem(name: "rel",            value: "0"),
            URLQueryItem(name: "iv_load_policy", value: "3"),
            URLQueryItem(name: "start",          value: "\(Int(startTime))"),
            URLQueryItem(name: "origin",         value: "https://www.example.com"),
        ]
        let embedURL = comps.url!
        tosLog.notice("[loadEmbed] loading \(embedURL)")
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName("com.void.smarttube.tosplayer.loadstarted" as CFString),
            nil, nil, true
        )
        // Wrap the embed URL in a minimal HTML page so YouTube's JS sees
        // window.parent !== window (iframe context). Loading the embed URL
        // directly as the top-level document makes window.parent === window,
        // which causes YouTube to fire error 153 for all videos.
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
            <meta name="viewport" content="width=device-width,initial-scale=1">
            <style>
                html,body,iframe{margin:0;padding:0;border:0;width:100%;height:100%;background:#000}
                iframe{position:absolute;top:0;left:0}
            </style>
        </head>
        <body>
            <iframe id="yt"
                src="\(embedURL.absoluteString)"
                frameborder="0"
                allow="autoplay; encrypted-media; fullscreen"
                allowfullscreen>
            </iframe>
        </body>
        </html>
        """
        // Use a real baseURL so the parent page has a non-null cross-origin origin.
        // This gives iframe HTTP requests a proper Referer and Sec-Fetch-Site: cross-site
        // header (matching a legitimate third-party embed). nil/about:blank produces
        // Sec-Fetch-Site: none which some YouTube CDN nodes reject.
        // Must not be youtube.com — that would trigger YouTube's self-embed detection.
        webView.loadHTMLString(html, baseURL: URL(string: "https://www.example.com")!)
    }

    // MARK: - WKUserScripts

    /// Injected at atDocumentStart into every frame. Hides window.webkit before any page
    /// script runs so YouTube's player can't detect the WKWebView environment. Stores
    /// the native ytCallback reference as window.__nativeYTCallback for stateDetectionJS.
    private static let webkitHiderJS: String = """
    (function() {
        try {
            var wk = window.webkit;
            if (!wk) return;
            var mh = wk.messageHandlers;
            window.__nativeYTCallback = (mh && mh.ytCallback) ? mh.ytCallback : null;
            Object.defineProperty(window, 'webkit', {
                get: function() { return undefined; },
                set: function() {},
                configurable: true,
                enumerable: false
            });
        } catch(e) {}
    })();
    """

    /// JavaScript injected at document-end into the YouTube embed page.
    /// Polls the `<video>` element and relays state via window.__nativeYTCallback
    /// (saved by webkitHiderJS before window.webkit was hidden).
    private static let stateDetectionJS: String = """
    (function() {
        try {
            var _cb = window.__nativeYTCallback;
            if (_cb) _cb.postMessage('{"type":"ping"}');
        } catch(e) {}

        var _prevState = -2;
        var _playAttempts = 0;

        function postMsg(obj) {
            try {
                var cb = window.__nativeYTCallback;
                if (cb) cb.postMessage(JSON.stringify(obj));
            } catch(e) {}
        }

        // Watch for YouTube's error overlay appearing in the DOM. This fires when
        // the player shows "Error 153 - Video player configuration error" (or similar)
        // instead of loading the video. MutationObserver is used so the check runs
        // asynchronously on DOM changes, not inside the pollVideo hot-path.
        var _errorReported = false;
        function checkErrorOverlay(node) {
            if (_errorReported) return;
            var errEl = node.nodeType === 1 && (
                (node.classList && node.classList.contains('ytp-error')) ||
                node.querySelector && node.querySelector('.ytp-error')
            );
            if (!errEl) return;
            _errorReported = true;
            var txt = (typeof errEl === 'object' ? (errEl.textContent || '') : (node.textContent || ''));
            var m = txt.match(/Error\\s+(\\d+)/i);
            postMsg({type: 'error', code: m ? parseInt(m[1], 10) : 153, text: txt.trim().substring(0, 200)});
        }
        var _observer = new MutationObserver(function(mutations) {
            for (var i = 0; i < mutations.length; i++) {
                var added = mutations[i].addedNodes;
                for (var j = 0; j < added.length; j++) { checkErrorOverlay(added[j]); }
            }
        });
        _observer.observe(document.documentElement, {childList: true, subtree: true});

        function pollVideo() {
            var video = document.querySelector('video');
            if (!video) return;

            var s;
            if (video.ended) {
                s = 0;
            } else if (video.paused) {
                s = 2;
            } else if (video.readyState >= 3) {
                s = 1;
            } else {
                s = 3;
            }

            var t = video.currentTime || 0;

            if (_prevState === -2) {
                _prevState = s;
                postMsg({type: 'ready', duration: video.duration || 0,
                         readyState: video.readyState, buffered: video.buffered.length});
            }

            // Kick off playback if YouTube's own autoplay didn't fire (common in WKWebView).
            // Keep retrying while paused and not yet playing (currentTime=0), up to 20 polls.
            if (video.paused && t === 0 && _playAttempts < 20) {
                _playAttempts++;
                video.muted = true;
                var p = video.play();
                if (p && p['catch']) { p['catch'](function() {}); }
            }

            postMsg({type: 'tick', t: t, state: s});

            if (s !== _prevState) {
                _prevState = s;
                postMsg({type: 'stateChange', state: s});
            }
        }

        setInterval(pollVideo, 250);
    })();
    """
}

// MARK: - TOSNavigationDelegate

/// Separate NSObject navigation delegate to ensure Objective-C dispatch works correctly
/// when the view model is a `@MainActor @Observable` actor-isolated class.
/// WKWebView holds a weak reference — TOSPlayerViewModel retains this strongly.
private final class TOSNavigationDelegate: NSObject, WKNavigationDelegate {

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        // Post navfinished at didCommit (document committed, before resources load).
        // Using didFinish would delay the notification until all subframes (including
        // the YouTube iframe) have loaded, but with iframe wrapping the iframe often
        // finishes after an error fires and the navigation is cancelled. didCommit
        // fires as soon as the main document is ready — reliable for the test gate.
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName("com.void.smarttube.tosplayer.navfinished" as CFString),
            nil, nil, true
        )
        tosLog.notice("[nav] navigation committed (navfinished posted)")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        tosLog.notice("[nav] navigation finished")
    }

    func webView(_ webView: WKWebView,
                 didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        tosLog.error("[nav] provisional navigation failed: \(error)")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        tosLog.error("[nav] navigation failed: \(error)")
    }
}

// MARK: - ScriptMessageProxy

/// Breaks the retain cycle: `WKUserContentController` retains its handlers strongly.
/// This proxy holds a `weak` reference to the real handler target so
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
