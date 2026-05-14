# Changelog

All notable changes to SmartTube are documented here.

---

## [2.6] – 2026-05-14

### Added
- **Safari Web Extension** — new `SafariExtension` target (`manifest.json` + `content.js`) intercepts YouTube watch, Shorts, youtu.be, and Music URLs in Safari and redirects them to `smarttube://video/<id>` without any user tap; `YouTubeLinkHandler` extended to recognise `music.youtube.com/watch?v=` URLs so the extension and the app URL handler stay in sync; `SafariExtensionURLCoverageTests` (7 tests) verify every manifest match pattern

### Fixed
- **Crash on age-restricted / region-locked videos** (1,048 iOS + 130 tvOS events, issue NW-3) — TV authenticated client sometimes returns a `PlayerInfo` with `hlsURL = nil` and no usable adaptive streams (muxed-only TVHTML5 URL); `PlaybackViewModel+Loading` now checks `tvInfo.hlsURL == nil && bestAdaptiveVideoURL == nil` immediately after the TV fetch and falls straight to `fetchPlayerInfoAndroid` before creating an `AVPlayerItem`, eliminating the `AVFoundationErrorDomain -11828` crash; `TVClientHLSNilFallbackTests` (8 tests) added
- **Audio-only mode silently stalling on playback start** — `tryLoadAudioURL(_:userAgent:)` now calls `setupAudioItemObserver(_:)` before `player.replaceCurrentItem(with:)`, wiring up `itemObserverTask` to catch `.failed` status (resets `isAudioOnlyMode = false` and propagates the error) and `.readyToPlay` (calls `loadAudioTracks(from:)`); previously a failed audio item had no observer and the player hung silently; `AudioOnlyModeUITests` (`testAudioOnlyModeOpensVideoWithoutError`) added
- **Mini player X button sometimes restoring fullscreen** — `fullScreenBinding` setter in `RootView` was calling `playerState.minimize()` whenever `currentVideo` cleared to `nil`; because `stop()` sets `presentation = .hidden` asynchronously, the setter raced and re-promoted state to `.miniPlayer`; setter is now a no-op (the `LandscapeFullScreenCover` UIKit coordinator already manages dismissal)
- **Audio track selection not working after fallback recovery** — `audioSelectionGroup` and `audioOptionsByID` were never refreshed when the Android fallback player, adaptive composition fallback, or 403-recovery path created a new `AVPlayerItem`; `retryWithFallbackPlayer`, `retryWithAdaptiveComposition`, and `retryWith403Recovery` in `PlaybackViewModel+Fallback` now call `loadAudioTracks(from:)` in their `.readyToPlay` observers, matching the existing pattern in the normal load and quality-change paths
- **More menu overflowing and unusable in landscape mode** (GitHub issue #45, contributor say4n) — `.frame(maxHeight: 520)` was too tall for compact vertical size class; `moreMenuOverlay` now uses 320 pt max-height in `verticalSizeClass == .compact`, adds `.safeAreaPadding(.horizontal)` plus 36 pt extra horizontal padding when landscape, keeping the menu within the live area and scrollable to the Cancel row; `player.moreMenu.scrollView` accessibility identifier added
- **"Hide Shorts" setting not filtering Shorts in Search, Library, and Channel views** (GitHub issue #41) — `AppSettings.hideShorts` was applied only in `HomeView` and `BrowseView`; `SearchView` and `LibraryView` now inject `SettingsStore` via `@Environment` and filter results before passing to `VideoGridSection`; `ChannelView.filteredVideos` extended to apply the same predicate; `RSSFeedsView.videoList` also updated for consistency; `HideShortsFilterTests` (6 tests) added

---

## [2.4] – 2026-05-10

### Fixed
- **Audio cutting out when manually changing video resolution** — `reloadHLSItem` and `reloadHLSItemH264Capped` in `PlaybackViewModel+Quality` created a new `AVPlayerItem` on quality switch but never called `loadAudioTracks(from:)`; `audioSelectionGroup` and `audioOptionsByID` stayed stale from the old item so `selectAudioTrack()` silently no-opped and AVPlayer fell back to muted defaults; one-line fix adds `loadAudioTracks(from: item)` in both `.readyToPlay` handlers
- **Audio quality improved to match official YouTube app** — `AVPlayerItem.audioTimePitchAlgorithm` defaulted to `.timeDomain` which introduces subtle artefacts at normal playback speeds; changed to `.spectral` in `PlaybackViewModel+Loading` when the `AVPlayerItem` is created (both HLS and adaptive paths)
- **tvOS video quality stuck at perceived ~420p despite 2160p setting** — `fetchHLSVariantURLs()` unconditionally replaced HEVC variants with H.264 for all platforms (added originally for Simulator compatibility); on tvOS HEVC is fully supported and YouTube lists it first in the manifest, so H.264 selection forced lower perceived quality; codec preference is now guarded `#if !os(tvOS)` so tvOS keeps the first (HEVC) variant while iOS/macOS still prefer H.264; `preferredPeakBitRate` hints added alongside `preferredMaximumResolution` in `reloadHLSItem` and initial load; `PlaybackQualityTests` (10 tests) added
- **Duplicate video cards causing blank cells in Home and Subscriptions feeds** — four separate deduplication gaps allowed duplicate `Video.id` values into `ForEach` arrays: (1) `fetchMoreVideos(.home)` returned `flatMap(\.videos)` with no dedup; (2) `HomeViewModel.loadMore` captured `existingIds` once before the append loop so intra-`newVideos` duplicates slipped through; (3) `BrowseViewModel.mergeIntoFirstGroup` had the same static-set gap; (4) `fetchNextPage(.home)` appended new groups without cross-group ID filtering; all four fixed with a growing-set pattern (`var seen = Set<String>(); filter { seen.insert($0.id).inserted }`); `mergedVideos` computed property gains a safety-net pass; `HomeFeedNoDuplicatesUITests` (3 tests) added
- **tvOS centre-zone double-tap and d-pad focus failures in player UI tests** — five UI tests were failing: `ToastModifier` had no accessibility identifier so toast queries raced against 2 s expiry; `ProgressView` spinner absorbed tap gestures; `SettingsStore` leaked persisted UserDefaults state between tests; SponsorBlock auto-seek disrupted player gesture tests; `testLandscapeAlwaysPlayBackButtonReturnsHome` used `guard` inside `defer` (compile-valid but never ran on error path); fixes: `.accessibilityIdentifier("player.toast")` on toast text; `.allowsHitTesting(false)` on spinner overlay; `--uitesting-reset-settings` launch-arg handler in `SettingsStore.init`; accessibility identifiers on SponsorBlock picker/NavigationLink; `testDoubleTapCentreZoneTogglesFitFill` converted from live Home feed to `--uitesting-deeplink-video=` fixed video ID to eliminate feed-timing flakiness; `guard`→`if` in defer block

---

## [2.3] – 2026-05-10

### Added
- **Shorts section on home screen** — `ShortsCardView` (portrait 9:16 thumbnail with dark gradient title overlay and duration badge) and `ShortsRowView` (horizontal `LazyHStack`, ~120 pt wide on iPhone) render above the main grid; `HomeViewModel` partitions `mergedVideos` into `homeVideos` (non-Shorts) and `homeShortsVideos` at the computed-property level with no extra network call; Shorts are identified by `Video.isShort` set at parse time from `reelWatchEndpoint`, `TILE_STYLE_YTLR_SHORTS`, or `parseReelItemRenderer`
- **Per-device YouTube recommendations setting** — `InnerTubeAPI.visitorData` (previously declared but never populated) is now extracted from `responseContext` on each browse/search response and injected into subsequent requests via `makeBody(includeVisitorData: true)`; different `visitorData` per device produces different recommendation graphs per device; toggle in Settings → Interface; disabled resets `visitorData = nil` on the next browse call

---

## [2.2] – 2026-05-06/07

### Added
- **Local Subscription Management** — follow/unfollow channels without a Google account; feeds backed by `LocalSubscriptionStore` (actor, UserDefaults persistence) and `LocalSubscriptionFeedService` (RSS fetch with InnerTube fallback); channels sorted alphabetically, feed videos sorted newest-first
- `YouTubeRSSParser` — XML-based RSS parser for YouTube channel feeds (`https://www.youtube.com/feeds/videos.xml?channel_id=CHANNEL_ID`) using Foundation `XMLParser`; background refresh via `LocalSubscriptionFeedCache`
- **RSS Feeds feature** — users can add arbitrary YouTube channel RSS feed URLs; `RSSFeedInfo` model + `RSSFeedStore` actor (JSON in UserDefaults); `RSSFeedsViewModel` fetches all active feeds concurrently with `withTaskGroup`, deduplicates by video ID, sorts newest-first; `RSSFeedsView` (list with toolbar add button), `AddRSSFeedView` (sheet), `ManageRSSFeedsView` (delete/toggle); Share Extension detects RSS URLs and writes `pendingRSSFeedURLs` to shared UserDefaults app group for `AppEntry` to drain on launch; `RSSFeedStoreTests` unit tests
- **Audio-only playback mode** — `PlaybackViewModel+AudioOnly` provides `loadAudioOnlyItemIfEnabled()` with a three-step chain: (1) iOS-client `bestAdaptiveAudioURL` (zero extra network cost), (2) `fetchPlayerInfoAndroidVR()` using `ANDROID_VR` client (nameID 28, version 1.65.10, Oculus UA, no PO Token required), (3) silent HLS fallback with `isAudioOnlyMode = false` reset; live streams excluded; thumbnail overlay shown via `audioOnlyThumbnailOverlay` in `PlayerView+Lifecycle`; quality picker hidden in audio-only mode; "Audio Only" toggle in Settings (iOS)
- **Preferred Audio Language setting** — `Picker` in Settings → Player (iOS only) with options: System Default, English, Spanish, French, German, Japanese, Korean, Portuguese, Chinese (Simplified), Original Track; `autoSelectAudioTrack()` priority updated: saved explicit language → `"original"` sentinel selects HLS `DEFAULT=YES` track → exact language code match → prefix match (e.g. `"en"` matches `"en-US"`) → English fallback → tracks.first; `AudioTrackSelectionTests` extended (6 new tests)
- **Picture-in-Picture** (iOS) — PiP session management in `PlaybackViewModel`; toggle in Settings
- "Landscape Always Play" setting — auto-rotate to landscape when a video starts on iPhone
- **poToken groundwork** — `PoTokenProvider` protocol; `PlayerInfo.applyingPoToken(_:)` appends `&pot=<token>` to all format/HLS/DASH URLs; `InnerTubeAPI` stores `poToken`/`poTokenVideoId`/`poTokenExpiry`; `makeBody(includePoToken:)` injects `serviceIntegrityDimensions.poToken`; `ServerPoTokenProvider` (developer tool, hidden behind `poTokenServiceURL` setting) POSTs `{"videoId":"..."}` and expects `{"token":"..."}`; `PoTokenInjectionTests` (6 tests)
- **VPN "cannot play video" hardening** — `APIError.ipBlocked(String)` added; `InnerTubeAPI+Player.parsePlayerInfo` detects VPN/proxy/bot keywords in `playabilityStatus.reason` and throws `.ipBlocked` instead of `.unavailable`; `PlaybackViewModel+Loading` short-circuits the retry storm on `.ipBlocked` (one TV-auth attempt for signed-in users; Android fallback skipped); `NWPathMonitor` in `InnerTubeAPI` resets `visitorData = nil` on VPN connect/disconnect; inert "Force IPv4 (VPN users)" toggle in Settings; `CrashlyticsLogger` records `vpn_ip_block = true` non-fatal; `IPBlockDetectionTests` (12 tests)
- **VideoPreloadCache — advanced caching (Phases E–K)**:
  - *Phase E — Progressive `loadAsync`*: `loadAsync` split into Phase 1 (critical path: cache consume → `fetchPlayerInfo` retry chain → AVPlayer setup → `isLoading = false`) and Phase 2 (`.utility` Task running concurrently: SponsorBlock cache-miss fetch, `nextInfo`, `endCards`, `trackingURLs`, neighbour prefetch); `phase2Task` cancelled in `load()` and `stop()`; `ProgressiveLoadPhase2Tests` (7 tests)
  - *Phase F — Stale-while-revalidate (SWR)*: `CachedVideoData.DataType` enum (`.nextInfo`, `.endCards`, `.sponsorSegments`, `.deArrowBranding`); `staleFields: Set<DataType>` returned by `consume()`; stale values returned immediately (non-nil) while Phase 2 revalidates in background; `VideoPreloadCacheTTLTests` (16 tests)
  - *Phase G — Priority prefetch queue*: `PrefetchPriority` enum (`.speculative`, `.visible`, `.immediate`, `.userFocused`); `[PrefetchRequest]` queue bounded at 20 items; overflow evicts lowest-priority item; worker pool of 5 slots (WiFi) / 2 (cellular); `VideoCardView` passes `.visible`; neighbour prefetch passes `.speculative`; `PrefetchQueueTests` (5 tests)
  - *Phase H — In-flight coalescing*: `inFlightPlayerFetches: [String: Task<PlayerInfo?, Never>]` on `VideoPreloadCache`; `getOrFetchPlayerInfo(videoId:)` returns existing in-flight task or creates a new one; `loadAsync` coalesces against in-flight prefetch before falling to its own fetch; `InFlightCoalescingTests` (4 tests)
  - *Phase I — TTL tuning*: `nextInfoTTL` 5 min → 20 min; `sponsorTTL` 1 h → 2 h; `deArrowTTL` 1 h → 4 h; `endCardsTTL` 1 h → 4 h
  - *Phase J — Disk persistence*: `VideoDiskCache` writes `nextInfo`, `endCards`, `sponsorSegments`, `deArrowBranding` as JSON under `Caches/st-video-cache/<videoId>-<dataType>.json`; LRU eviction at 20 MB; `playerInfo` and `trackingURLs` never written (CDN/auth-sensitive); `Codable` added to `NextInfo`, `EndCard`, `EndCard.Style`, `Chapter`, `DeArrowService.BrandingInfo`; `VideoDiskCacheTests` (7 tests)
  - *Phase K — Network-aware throttling*: `NWPathMonitor` in `VideoPreloadCache`; offline → 0 workers (pauses all prefetches); cellular/constrained → 2 workers, `playerInfo`+`nextInfo`+`sponsorSegments` only; WiFi → 5 workers, all data types; `networkCap` and `allowedPrefetchDataTypes` computed properties
- `YouTubeRSSParserTests`, `LocalSubscriptionStoreTests`, `LocalSubscriptionFeedServiceTests` unit tests

### Fixed
- Shorts player section feed sometimes not visible when test starts — added explicit wait for section feed before asserting

---

## [2.1] – 2026-05-04/05

### Added
- **Landscape playback for iOS** — `OrientationManager` + `LandscapeAwareHostingController` replace SwiftUI's portrait-locked hosting controller so UIKit accepts `requestGeometryUpdate(.landscape)` while the player is on screen
- **tvOS PlayerView** (`PlayerView+tvOS`) — full d-pad navigation with `TVPlayerControl` focus model; Siri Remote play/pause, seek, menu/back handling
- **Now Playing** — lock screen and Dynamic Island metadata, artwork, and transport controls via `MPNowPlayingInfoCenter` and `MPRemoteCommandCenter`
- **Playback quality selection** — manual format override with `PlaybackViewModel+Quality`; HLS variant URL fetching; toast confirmation via `ToastModifier`
- **Previous/next video navigation** — history stack in `PlaybackViewModel+Navigation`; `playNext()` / `playPrevious()`
- **Caption track selection** — VTT fetch and live cue overlay in `PlaybackViewModel+Captions`
- **Sleep timer** — countdown task in `PlaybackViewModel+SleepTimer`
- **Like/Dislike actions** — `PlaybackViewModel+LikeDislike`
- **Stats for Nerds** overlay — `PlaybackViewModel+StatsForNerds`
- `PlayerView+Overlays` and `PlayerView+PickerOverlays` — player UI extracted into focused extension files
- `ToastModifier` — self-dismissing pill message (auto-clears binding after 2 s)
- `ScrollOffsetPreserver` — saves and restores LibraryView scroll position across tab switches
- `VideoDownloadUITests` — UI test for both download methods: (A) player more menu → "Download to Gallery" using `--uitesting-deeplink-video=JhCjw57u8mQ` launch arg; (B) video card long-press context menu → "Download to Gallery"; `player.moreMenu.downloadButton` accessibility identifier added to download button in `PlayerView+Overlays`
- Updated app icon (dark variant added)

### Changed
- `PlaybackViewModel` split into 14 focused extensions (Auth, AudioTracks, Captions, Controls, ControlsVisibility, Fallback, LikeDislike, Loading, Navigation, NowPlaying, Observers, Quality, SleepTimer, SponsorBlock, StatsForNerds)
- `InnerTubeAPI+VideoRenderers.swift` (~1,100 lines) split into `InnerTubeAPI+VideoGroupRows.swift` (multi-shelf home row parsing), `InnerTubeAPI+VideoRendererParsers.swift` (individual renderer parsers: `parseTileRenderer`, `parseLockupViewModel`, `parseReelItemRenderer`, `parseVideoRenderer`), and `InnerTubeAPI+VideoGroupFlat.swift` (flat video group fallback parsing); all other files kept under 1,000 lines
- Enhanced error handling and retry logic for failed stream requests
- BrowseViewModel recommended-video fetch deduplicates results
- Improved focus management for picker overlays on tvOS

### Fixed
- **Subscriptions feed not strictly sorted in chronological order** — YouTube returns each page sorted newest-first, but `BrowseViewModel.mergeIntoFirstGroup` and `HomeViewModel.loadMore` appended pages without global re-sort, so videos from page 2 appeared out of position relative to page 1; `videoGroups[0].videos` is now re-sorted by `publishedAt` descending after each `mergeIntoFirstGroup` call (subscriptions case) and after each `loadMore` append in `HomeViewModel`; `SubscriptionsSortTests` (pagination merge test) added

---

## [2.0] – 2026-05-03/04

### Added
- **Localisation** — `Localizable.xcstrings` string catalog covering the full app
- `InnerTubeAPIProtocol` — protocol abstraction over `InnerTubeAPI` enabling mock injection in tests
- `ViewModelLogger` — structured per-category logging routed to Crashlytics
- Sign-in UI: one-tap "Open Activation Page" button (opens pre-filled URL); "Or scan from another device" QR divider section
- Sign-in progress guard in `AuthService` — prevents concurrent device-code flows
- Comprehensive unit tests: `WebVTTParserTests`, `VideoStateStoreTests`, `ViewModelTests`, `VideoPreloadCacheTTLTests`, `SearchFilterUITests`, `YouTubeLinkHandlerTests`
- UI test suites: Channel, Library (History / Playlists / Subscriptions), Player controls, Recommended chip pagination, Search, Settings, Shorts, Audio track selection
- GitHub issue templates (bug report, feature request)

### Changed
- Updated Privacy Policy
- Various internal refactors for readability and maintainability

### Fixed
- **Login failures requiring multiple retries on iPhone** — `AuthService` gained `retryWithBackoff<T>()`: up to 3 attempts with 1–10 s exponential delay on transient `URLError` codes (timeout, connection lost, offline, SSL); `requestDeviceCode`, `fetchUserInfo`, `validAccessToken`, `refreshAccessToken` all wrapped; permanent OAuth errors (`invalid_grant`, `invalid_client`, `unauthorized_client`) are still propagated immediately without retry; `YouTubeClientCredentialsFetcher.fetchFromYouTube` retries twice before falling back to hardcoded credentials; `URLSession` in `InnerTubeAPI.init` now uses `waitsForConnectivity = true`, 20 s request timeout, 60 s resource timeout
- **SponsorBlock causing video playback to stall** — race condition between time observer ticks and async seek callback; debounce guard (`sponsorSkipDebounceTask`) prevents redundant seeks when multiple ticks fire on the same segment; seek-in-flight guard skips sponsor check while a seek is pending; exact seek (tolerance = zero) used for segment endpoints instead of fuzzy tolerance; segment-near-end threshold widened from 0.5 s to 2.0 s of video duration to prevent clamping to last frame; buffer-status verification logs warning when player is `.waiting` for >2 s after seek
- **Subscriptions feed showing videos out of chronological order** — `InnerTubeAPI+Browse.fetchSubscriptions()` now sorts each page's videos by `publishedAt` descending on arrival; `parseGuideChannels()` and `parseSubscribedChannels()` now sort channels alphabetically, matching `LocalSubscriptionStore`'s existing order
- **Apple TV fast-forward and rewind buttons showing white squares and not responding** — SF Symbol images in `seekButton` and `playPauseButton` rendered as white-on-white on tvOS focus engine due to `scaleEffect` + `shadow` + `buttonStyle(.plain)` interaction; fixed with `.renderingMode(.original)` + `.foregroundStyle(.white)`; reduced shadow intensity; Siri Remote gen 1 edge-tap left/right swipe gestures wired to `seekRelative` when controls are visible
- **Audio track language defaulting to wrong language for AI-dubbed videos** — when no `DEFAULT=YES` track is present in the HLS manifest, `index == 0` was incorrectly marked `isOriginal = true`; for AI-dubbed videos YouTube often lists the dubbed track first, causing the wrong track to be auto-selected; `isOriginal` is now only set when `group.defaultOption == option` (explicit HLS `DEFAULT=YES`); auto-selection waterfall reordered: (1) user's saved language preference, (2) HLS `DEFAULT=YES` original, (3) English track, (4) device locale, (5) first track
- **Videos unable to play / "reload page" error on iOS 18.7.2 and iOS 26** — hardcoded `"iOS 18_3_2"` User-Agent and client version string caused YouTube to detect a version mismatch on newer OS versions and return `UNPLAYABLE` or cipher-protected streams; User-Agent now uses `UIDevice.systemVersion` dynamically; SponsorBlock segment fetch moved to a detached background `Task` after `AVPlayerItem` is `.readyToPlay` so it no longer blocks stream setup on slow connections

---

## [1.9] – 2026-05-02

### Added
- Home feed staleness check — `HomeViewModel.refreshIfStale(threshold:)` reloads shelves when content is older than 15 minutes
- `InnerTubeAPI`: authenticated playback tracking URLs (`fetchAuthenticatedTrackingURLs`), TV-client endpoint (`postTV`), section-date and relative-date parsing
- Home feed fallback to popular videos when watch history is empty

### Changed
- HomeView replaced shelf rows with `VideoGridSection` grid layout
- `VideoCardView` layout and thumbnail improvements

---

## [1.8] – 2026-05-01

### Added
- Android-client HLS fallback in `PlaybackViewModel` — retries with Android credentials when the iOS HLS manifest returns a 404 due to IP-binding; last attempted URL stamped into Crashlytics non-fatal reports
- `VideoPlaybackRegressionUITests` — UI test coverage for core playback flows

### Changed
- `VideoPreloadCache` keeps its `InnerTubeAPI` access-token in sync with the signed-in session

---

## [1.7] – 2026-04-30

### Added
- `VideoPreloadCache` — background prefetch and cache of video stream data keyed by video ID
- `WatchtimeTracker` — reports playback position metrics to YouTube's watchtime endpoint
- `InnerTubeAPIKey` SwiftUI environment key — all views receive `InnerTubeAPI` via `@Environment(\.innerTubeAPI)` instead of constructor injection

### Changed
- Updated InnerTube client version strings

---

## [1.6] – 2026-04-28/29 — Initial Open Source Release

### Added
- Initial open source release of SmartTube for iPhone, iPad, macOS, and Apple TV
- **Audio track selection** — loads alternate HLS renditions (dubbed/translated tracks) from the manifest; auto-selects by device locale; persisted in `AppSettings`
- tvOS d-pad navigation in the player — custom `TVPlayerControl` enum; directional seek, play/pause, and back without SwiftUI focus engine
- tvOS Settings: Ko-fi and GitHub QR code sheets
- Firebase dSYM copy script for crash symbolication
- `CrashlyticsLogger` integration

### Changed
- `AuthService`: concurrent sign-in guard; automatic sign-out on permanent OAuth failures (`invalid_grant`, `invalid_client`, `unauthorized_client`); device code expiration clamped at server-reported `expiresIn`
- `VideoDownloadService` download-session and background-task code restricted to iOS with `#if os(iOS)` guards
- `PlaybackViewModel`: foreground/background audio session handling (`handleForeground()` / `handleBackground()`)
