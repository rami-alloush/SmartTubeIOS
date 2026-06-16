#if !os(tvOS)
import Foundation

/// JS source strings and embed-URL/HTML-wrapper helpers shared by the Task 1
/// iframe-src-swap spike (`ShortsEmbedSrcSwapSpikeViewModel`) and, from Task 4
/// onward, `ShortsEmbedPlayerViewModel`.
///
/// `embedURL`/`htmlWrapper` intentionally duplicate what Task 2 extracts as a pure
/// function in `SmartTubeIOSCore` (`ShortsEmbedURL.swift`). Task 1 cannot depend on
/// Task 2 — the spike must be self-contained and runnable first. Once Task 2 lands,
/// `ShortsEmbedPlayerViewModel` (Task 4) uses the `SmartTubeIOSCore` version; these
/// copies remain spike-only.
enum ShortsEmbedJS {

    /// Injected at `.atDocumentStart` into every frame — verbatim copy of
    /// `TOSPlayerViewModel.webkitHiderJS` (TOSPlayerViewModel.swift:460-475). Hides
    /// `window.webkit` before any page script runs so YouTube's player can't detect
    /// the WKWebView environment, and stashes the native `ytCallback` handler as
    /// `window.__nativeYTCallback` for `stateDetectionJS` to use.
    static let webkitHiderJS: String = """
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

    /// Injected at `.atDocumentStart` into every frame. Three-layer defence against
    /// YouTube's Shorts chrome (channel header, Shorts logo, share button, pause
    /// bezel) — runs only in the cross-origin YouTube embed iframe, never in the
    /// wrapper page (`window === window.top` guard prevents blacking out the entire
    /// WKWebView).
    ///
    /// Layer 1 — CSS class names (`ytp-*`): fast path for static player elements.
    /// Layer 2 — Full-viewport black overlay div: class-name-independent cover for
    ///            any Shorts-specific chrome that CSS selectors miss.
    /// Layer 3 — Video elevation: video element is pulled to z-index MAX so it
    ///            renders above the overlay, making only the raw video visible.
    ///
    /// Both a MutationObserver and a 500 ms setInterval reapply layer 3 so
    /// YouTube's JS can't reset the video's position/z-index after we set it.
    static let playerControlsHiderJS: String = """
    (function() {
        // Do nothing in the wrapper page — only run inside the YouTube embed iframe.
        if (window === window.top) return;

        function apply() {
            try {
                // Layer 1: CSS for named player chrome elements
                if (!document.getElementById('__st_css')) {
                    var s = document.createElement('style');
                    s.id = '__st_css';
                    s.textContent =
                        '.ytp-chrome-top,.ytp-chrome-bottom,' +
                        '.ytp-gradient-top,.ytp-gradient-bottom,' +
                        '.ytp-watermark,.ytp-pause-overlay,.ytp-cued-thumbnail-overlay,' +
                        '.ytp-bezel-container,.ytp-bezel,.ytp-player-content,' +
                        '.ytp-endscreen-content,.ytp-ce-element,' +
                        '.ytp-cards-button,.ytp-cards-teaser,' +
                        '#movie_player > *:not(.html5-video-container)' +
                        '{display:none!important}';
                    (document.head || document.documentElement).appendChild(s);
                }
                // Layer 2: Black overlay that covers any chrome not caught above
                if (!document.getElementById('__st_ov')) {
                    var ov = document.createElement('div');
                    ov.id = '__st_ov';
                    ov.style.cssText = 'position:fixed;top:0;left:0;width:100%;height:100%;background:#000;z-index:2147483646;pointer-events:none;';
                    document.documentElement.appendChild(ov);
                }
                // Layer 3: Elevate <video> above the overlay
                var v = document.querySelector('video');
                if (v) {
                    v.style.setProperty('position', 'fixed', 'important');
                    v.style.setProperty('top', '0', 'important');
                    v.style.setProperty('left', '0', 'important');
                    v.style.setProperty('width', '100%', 'important');
                    v.style.setProperty('height', '100%', 'important');
                    v.style.setProperty('z-index', '2147483647', 'important');
                    v.style.setProperty('object-fit', 'cover', 'important');
                    v.style.setProperty('background', '#000', 'important');
                }
            } catch(e) {}
        }

        apply();
        new MutationObserver(apply).observe(document.documentElement, {childList: true, subtree: true});
        setInterval(apply, 500);
    })();
    """

    /// Injected at `.atDocumentEnd` into every frame — verbatim copy of
    /// `TOSPlayerViewModel.stateDetectionJS` (TOSPlayerViewModel.swift:480-587). Polls
    /// the `<video>` element every 250ms and relays `ping`/`ready`/`tick`/`stateChange`/
    /// `autoUnmuted`/`error` via `window.__nativeYTCallback.postMessage`.
    static let stateDetectionJS: String = """
    (function() {
        try {
            var _cb = window.__nativeYTCallback;
            if (_cb) _cb.postMessage('{"type":"ping"}');
        } catch(e) {}

        var _prevState = -2;
        var _playAttempts = 0;
        var _autoUnmuted = false;

        function postMsg(obj) {
            try {
                var cb = window.__nativeYTCallback;
                if (cb) cb.postMessage(JSON.stringify(obj));
            } catch(e) {}
        }

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
                var dur = video.duration || 0;
                if (dur <= 0) {
                    // Metadata not loaded yet on this poll — stay in the "not yet
                    // ready" sentinel state and try again on the next 250ms tick
                    // rather than firing "ready" with a bogus duration of 0.
                    return;
                }
                _prevState = s;
                postMsg({type: 'ready', duration: dur,
                         readyState: video.readyState, buffered: video.buffered.length});
            }

            if (video.paused && t === 0 && _playAttempts < 20) {
                _playAttempts++;
                video.muted = true;
                var p = video.play();
                if (p && p['catch']) { p['catch'](function() {}); }
            }

            if (!_autoUnmuted && !video.paused && t > 0.1) {
                _autoUnmuted = true;
                video.muted = false;
                var ytPlayer = document.getElementById('movie_player');
                if (ytPlayer && typeof ytPlayer.unMute === 'function') { ytPlayer.unMute(); }
                postMsg({type: 'autoUnmuted', t: t, muted: video.muted});
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

    /// Builds `https://www.youtube.com/embed/{videoId}?...` — mirrors
    /// `TOSPlayerViewModel.loadEmbed`'s query items (TOSPlayerViewModel.swift:405-416).
    static func embedURL(videoId: String, startTime: Double = 0) -> URL {
        var comps = URLComponents(string: "https://www.youtube.com/embed/\(videoId)")!
        comps.queryItems = [
            URLQueryItem(name: "autoplay",       value: "1"),
            URLQueryItem(name: "mute",           value: "1"),
            URLQueryItem(name: "controls",       value: "0"),
            URLQueryItem(name: "playsinline",    value: "1"),
            URLQueryItem(name: "rel",            value: "0"),
            URLQueryItem(name: "iv_load_policy", value: "3"),
            URLQueryItem(name: "start",          value: "\(Int(startTime))"),
            URLQueryItem(name: "origin",         value: "https://www.example.com"),
        ]
        return comps.url!
    }

    /// Wraps an embed URL in the `<iframe id="yt">` HTML page — mirrors
    /// `TOSPlayerViewModel.loadEmbed`'s HTML template (TOSPlayerViewModel.swift:427-446).
    static func htmlWrapper(embedURL: URL) -> String {
        """
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
    }
}
#endif
