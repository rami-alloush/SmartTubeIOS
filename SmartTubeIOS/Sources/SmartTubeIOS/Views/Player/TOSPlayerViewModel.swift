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
        case .embeddingDisabled, .notFound: return true
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
        // Allow autoplay without user gesture on the main frame (embed URL, not an iframe).
        config.mediaTypesRequiringUserActionForPlayback = []

        let contentController = WKUserContentController()
        let proxyHandler = ScriptMessageProxy()
        // Register in .page world so the WKUserScript (also .page) can call it.
        contentController.add(proxyHandler, contentWorld: .page, name: "ytCallback")

        // Inject state-detection JS at document-end into YouTube's embed page.
        let detectionScript = WKUserScript(
            source: Self.stateDetectionJS,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true,
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
            // Force muted playback. YouTube's embed page sets autoplay=1&mute=1 via URL
            // params but WKWebView finds the <video> element before YouTube's own JS calls
            // play() — so we nudge it here to avoid getting stuck in paused state.
            eval("var v=document.querySelector('video');if(v){v.muted=true;v.play();}")
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
            if newState == .playing && playerState != .playing {
                tosLog.notice("[ytCallback] tick detected playing state — firing notification")
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
            tosLog.warning("[ytCallback] error code=\(code)")
            switch code {
            case 101, 150: playerError = .embeddingDisabled
            case 100:      playerError = .notFound
            default:       playerError = .iframeError(code)
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
            URLQueryItem(name: "mute",           value: "1"),  // muted = unconditional autoplay
            URLQueryItem(name: "controls",       value: "1"),
            URLQueryItem(name: "playsinline",    value: "1"),
            URLQueryItem(name: "rel",            value: "0"),
            URLQueryItem(name: "modestbranding", value: "1"),
            URLQueryItem(name: "iv_load_policy", value: "3"),
            URLQueryItem(name: "start",          value: "\(Int(startTime))"),
        ]
        let url = comps.url!
        tosLog.notice("[loadEmbed] loading \(url)")
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName("com.void.smarttube.tosplayer.loadstarted" as CFString),
            nil, nil, true
        )
        webView.load(URLRequest(url: url))
    }

    // MARK: - State-detection WKUserScript (injected into YouTube embed page)

    /// JavaScript injected at document-end into the YouTube embed page.
    /// Polls the `<video>` element and relays state via `window.webkit.messageHandlers.ytCallback`.
    private static let stateDetectionJS: String = """
    (function() {
        try {
            window.webkit.messageHandlers.ytCallback.postMessage('{"type":"ping"}');
        } catch(e) {}

        var _prevState = -2;

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
                try {
                    window.webkit.messageHandlers.ytCallback.postMessage(
                        JSON.stringify({type: 'ready', duration: video.duration || 0})
                    );
                } catch(e) {}
                _prevState = s;
            }

            try {
                window.webkit.messageHandlers.ytCallback.postMessage(
                    JSON.stringify({type: 'tick', t: t, state: s})
                );
            } catch(e) {}

            if (s !== _prevState) {
                _prevState = s;
                try {
                    window.webkit.messageHandlers.ytCallback.postMessage(
                        JSON.stringify({type: 'stateChange', state: s})
                    );
                } catch(e) {}
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

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName("com.void.smarttube.tosplayer.navfinished" as CFString),
            nil, nil, true
        )
        tosLog.notice("[nav] navigation finished")
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
