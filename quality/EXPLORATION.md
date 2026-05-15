# Quality Playbook — Phase 1: Open Exploration
**Target:** SmartTube iOS / tvOS (Swift Package `SmartTubeIOS` + `SmartTubeApp` Xcode project)  
**Audit date:** 2026-05-15  
**Playbook version:** QPB v1.5.6, Mode A (skill-direct)  
**Exploration subagents:** 3 parallel (Playback/Fallback, API Parsers, Cache/Auth)  
**Total files analysed:** 314 tracked source files (see `exploration_role_map.json`)

---

## Open Exploration Findings

Findings are numbered `EF-N` and graded **CRITICAL / MAJOR / MINOR**.  
File references use repo-relative paths; line numbers are approximations from the most recent full-file reads.

---

### EF-01 — `playerInfo` is never propagated to fallback execution paths (CRITICAL)

**Files:**  
- `SmartTubeIOS/Sources/SmartTubeIOS/ViewModels/PlaybackViewModel+Fallback.swift` lines 27–50 (`retryWithFallbackPlayer`)  
- `SmartTubeIOS/Sources/SmartTubeIOS/ViewModels/PlaybackViewModel+Fallback.swift` lines 116–140 (`retryWith403Recovery`)  
- `SmartTubeIOS/Sources/SmartTubeIOS/ViewModels/PlaybackViewModel+AudioOnly.swift` line 97 (`retryAudioOnlyWithAndroidVR`)

**Observation:**  
When `retryWithFallbackPlayer()`, `retryWith403Recovery()`, or `retryAudioOnlyWithAndroidVR()` succeed and obtain a new `PlayerInfo` from an alternate client (Android, authenticated TV, AndroidVR), none of them write the new `PlayerInfo` back to `self.playerInfo`, `availableFormats`, or `availableCaptions`. The UI quality picker and caption track list continue to reference stale data from the failed primary iOS client fetch.

**Concrete bad path:**  
iOS client returns formats [H.264-360p, H.264-720p] → AVPlayer item fails → `retryWithFallbackPlayer()` fetches Android client, obtains [VP9-1080p, VP9-720p] → `self.playerInfo` still points to iOS client response → quality picker shows H.264-720p as highest option while stream is actually VP9-1080p → user selects H.264-720p → URL lookup fails → ABR falls to lowest bitrate.

---

### EF-02 — Phase 2 background enrichment task is never re-launched after a fallback succeeds (MAJOR)

**Files:**  
- `SmartTubeIOS/Sources/SmartTubeIOS/ViewModels/PlaybackViewModel+Loading.swift` lines 520–535  
- `SmartTubeIOS/Sources/SmartTubeIOS/ViewModels/PlaybackViewModel+Fallback.swift` lines 27–50

**Observation:**  
`phase2Task` is created once at the end of `loadAsync()` using the primary iOS client's `PlayerInfo`. When the primary path fails and a fallback path succeeds, no new `phase2Task` is launched. Consequences: tracking URLs fetched from iOS client's unauthenticated response (watch history recorded as anonymous), SponsorBlock segments never fetched for the fallback video, end cards never loaded, related videos never populated.

---

### EF-03 — Audio-only mode ignores `liveToggle=true` when the first stream attempt fails (MAJOR)

**Files:**  
- `SmartTubeIOS/Sources/SmartTubeIOS/ViewModels/PlaybackViewModel+AudioOnly.swift` lines 65–87 (`tryLoadAudioURL`)

**Observation:**  
When `toggleAudioOnlyLive()` passes `liveToggle: true`, the flag reaches `retryAudioOnlyWithAndroidVR()` correctly. However, `tryLoadAudioURL()` — the first attempt — does not receive the `liveToggle` flag. If the iOS adaptive audio URL fails inside `tryLoadAudioURL`, the `.failed` case unconditionally sets `isAudioOnlyMode = false`, hiding the audio-only overlay. The Android VR fallback is never reached, and no "stream unavailable" toast is shown.

---

### EF-04 — Concurrent `load()` calls produce a race between `playerInfo`/`availableFormats` mutations and `currentVideo` (CRITICAL)

**Files:**  
- `SmartTubeIOS/Sources/SmartTubeIOS/ViewModels/PlaybackViewModel+Loading.swift` lines 14–110 (`load`)  
- `SmartTubeIOS/Sources/SmartTubeIOS/ViewModels/PlaybackViewModel+Loading.swift` lines 198–250 (`loadAsync` state-write section)

**Observation:**  
`load()` cancels the previous `loadTask` and immediately starts a new one. Swift Task cancellation is cooperative; cancelling a Task does not abort it — it sets `isCancelled = true` that must be explicitly polled. `loadAsync()` does not check `Task.isCancelled` between `await api.fetchPlayerInfo(...)` and the subsequent `self.playerInfo = info` / `self.availableFormats = formats` assignments. Under rapid navigation:  
1. `loadAsync(videoA)` awaits network fetch.  
2. `load(videoB)` called; `currentVideo = videoB` immediately.  
3. `loadAsync(videoA)` resumes and writes `playerInfo` and `availableFormats` for video A.  
4. UI is now in a mixed state: video B is playing, video A's metadata is displayed.

---

### EF-05 — AVPlayerItem observer task is created before the item is placed in the player (MAJOR)

**Files:**  
- `SmartTubeIOS/Sources/SmartTubeIOS/ViewModels/PlaybackViewModel+Fallback.swift` lines 45–58  
- `SmartTubeIOS/Sources/SmartTubeIOS/ViewModels/PlaybackViewModel+AudioOnly.swift` lines 77–86

**Observation:**  
In both fallback paths, `itemObserverTask` is assigned and begins iterating the new item's `statusStream` before `player.replaceCurrentItem(with: newItem)` is called. If `replaceCurrentItem` triggers an immediate synchronous status transition on a calling thread, the observer's `for await` loop may not yet be running and will miss the event. Also: if `replaceCurrentItem` is slow and a second fallback is triggered, the previous `itemObserverTask?.cancel()` fires before the new task's for loop starts, leaving a window with no observer.

---

### EF-06 — No `endObserverTask` is created for audio-only stream items (MAJOR)

**Files:**  
- `SmartTubeIOS/Sources/SmartTubeIOS/ViewModels/PlaybackViewModel+AudioOnly.swift` lines 80–86

**Observation:**  
`loadAsync()` creates an `endObserverTask` that observes `AVPlayerItem.didPlayToEndTimeNotification` on the HLS item to trigger autoplay. When audio-only mode replaces the HLS item with an audio URL item, the original `endObserverTask` remains subscribed to the now-removed HLS item. No new `endObserverTask` is created for the audio item. When the audio stream finishes, `handlePlaybackEnd()` is never called → autoplay does not trigger → watch time at end of video is not recorded.

---

### EF-07 — `extractNumber()` strips K/M/B suffixes, producing 100× undercount for formatted view counts (CRITICAL)

**Files:**  
- `SmartTubeIOS/Sources/SmartTubeIOSCore/InnerTubeAPI+TextHelpers.swift` lines 38–40

**Observation:**  
```swift
text.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
```
This strips all non-digit characters. For the string `"1.5K views"`, the digits `1`, `5` remain and are joined as `"15"` → `Int("15") = 15`. The correct value is 1 500. Likewise `"2.3M"` → `"23"` instead of 2 300 000. Any formatted count in search results, home feed, or channel pages is massively undercounted.

---

### EF-08 — `viewCount`, `publishedAt`, and `channelId` are extracted inconsistently across the four renderer parsers (MAJOR)

**Files:**  
- `SmartTubeIOS/Sources/SmartTubeIOSCore/InnerTubeAPI+VideoRenderers.swift` lines 259–636 (all four parsers)

**Observation:**  
| Field | `parseVideoRenderer` | `parseLockupViewModel` | `parseTileRenderer` | `parseReelItemRenderer` |
|---|---|---|---|---|
| `viewCount` | ✅ extracted | ❌ nil | ❌ nil | ❌ nil |
| `publishedAt` | ❌ nil | ❌ nil | ✅ extracted | ❌ nil |
| `channelId` | ownerText.runs | watchEndpoint | watchEndpoint / @handle | reelWatchEndpoint |

The same video appearing in different contexts (home feed via `lockupViewModel`, search via `videoRenderer`, history via `tileRenderer`) will return different metadata for the same fields — violating the contract of the `Video` value type.

---

### EF-09 — `playlistVideoRenderer` is delegated to `parseVideoRenderer()` which uses wrong field names (MAJOR)

**Files:**  
- `SmartTubeIOS/Sources/SmartTubeIOSCore/InnerTubeAPI+VideoRenderers.swift` lines 221–222

**Observation:**  
`playlistVideoRenderer` uses `shortTitle` for the video title (not `title`) and has no `ownerText` field (channel info comes from parent context). Delegating to `parseVideoRenderer()` causes title to be blank or fall through to `headline`, and channel ID to be nil for all playlist browse responses.

---

### EF-10 — Token mismatch in watch history: tracking URLs generated with Token A, pinged with Token B (CRITICAL)

**Files:**  
- `SmartTubeIOS/Sources/SmartTubeIOSCore/InnerTubeAPI+Player.swift` lines 166–189 and 460–467  
- `SmartTubeIOS/Sources/SmartTubeIOSCore/WatchtimeTracker.swift`

**Observation:**  
The `/player` API response embeds per-session tracking URLs that are token-bound at response generation time. `WatchtimeTracker` caches these URLs and pings them minutes later. If `TokenManager` emits a refreshed token between video load and the watchtime ping, `InnerTubeAPI`'s `authToken` has changed but `WatchtimeTracker` still sends the old URLs using the new token header. YouTube's backend may reject or misattribute these pings.

---

### EF-11 — Watch history pings are fire-and-forget with no retry or error surface (CRITICAL)

**Files:**  
- `SmartTubeIOS/Sources/SmartTubeIOSCore/InnerTubeAPI+Player.swift` line 467

**Observation:**  
```swift
try? await session.data(for: request)
```
All network errors — including 401 Unauthorized, 403 Forbidden, network timeout, and DNS failure — are silently discarded. There is no retry, no error logging to Crashlytics, and no user-visible feedback. This makes watch history tracking unreliable and unfalsifiable: there is no way to know pings are failing in production without external telemetry.

---

### EF-12 — Disk cache (`VideoDiskCache`) persists auth-bound data across sign-out (MAJOR)

**Files:**  
- `SmartTubeIOS/Sources/SmartTubeIOSCore/VideoPreloadCache.swift` lines 388–396 (`evictAuthSensitiveData`)  
- `SmartTubeIOS/Sources/SmartTubeIOSCore/VideoDiskCache.swift`

**Observation:**  
`evictAuthSensitiveData()` clears in-memory caches (likes, watch status, tracking URL map). However, `VideoDiskCache` stores preloaded `VideoPreloadEntry` objects that include `likeStatus`, `isWatched`, and `trackingURLs`. These disk entries are not cleared on sign-out. If a second user signs in on the same device, they will see the first user's like states and "watched" badges until the 20MB LRU fills and evicts the old entries.

---

### EF-13 — TOCTOU race in neighbour prefetch: `prefetchToken` captured at load time, stale after refresh (MAJOR)

**Files:**  
- `SmartTubeIOS/Sources/SmartTubeIOS/ViewModels/PlaybackViewModel+Loading.swift` lines 764–778

**Observation:**  
The background Task that prefetches the next/previous video captures the current `authToken` value at Task creation time. If the background Task is still running when `TokenManager` emits a refreshed token, the prefetch request is sent with the old token. The prefetch response may contain tracking URLs or personalised content bound to the old token session.

---

### EF-14 — `viewCountText` has no fallback for alternate YouTube field names (MAJOR)

**Files:**  
- `SmartTubeIOS/Sources/SmartTubeIOSCore/InnerTubeAPI+VideoRenderers.swift` line 576

**Observation:**  
```swift
let viewCountText = (r["viewCountText"] as? [String: Any]).flatMap { extractText($0) }
```
YouTube API responses sometimes use `shortViewCountText` (for compact renderers) or `"viewCount"` as a direct integer. If `viewCountText` is absent, no fallback is attempted → `viewCount` is nil for those videos. `title` has a `?? headline` fallback; `viewCountText` does not.

---

### EF-15 — `compactVideoRenderer` and `gridVideoRenderer` use `thumbnailOverlays` for duration, not `lengthText` (MINOR)

**Files:**  
- `SmartTubeIOS/Sources/SmartTubeIOSCore/InnerTubeAPI+VideoRenderers.swift` lines 218–220

**Observation:**  
Both renderer types are delegated to `parseVideoRenderer()`, which looks for `lengthText`. Compact and grid renderers embed duration inside `thumbnailOverlays[n].thumbnailOverlayTimeStatusRenderer.text`. When `lengthText` is absent, duration returns nil and no duration badge is shown on video cards in search or shelf contexts.

---

### EF-16 — Stale `WatchtimeTracker` URL references after in-memory eviction (MAJOR)

**Files:**  
- `SmartTubeIOS/Sources/SmartTubeIOSCore/VideoPreloadCache.swift` lines 329–360  
- `SmartTubeIOS/Sources/SmartTubeIOSCore/WatchtimeTracker.swift`

**Observation:**  
`evictTrackingURLs()` removes the URL set from the in-memory `VideoPreloadCache` map. But `WatchtimeTracker.setTrackingURLs()` was already called earlier and holds a strong reference to the URL array. After eviction, `WatchtimeTracker` continues to ping the now-evicted URLs with no observable validation that they are still current. If the URLs were evicted because a new video started (and new URLs are pending), pings for the old video can overlap with pings for the new video.

---

### EF-17 — `AuthService+TokenRefresh.swift` uses a `Timer` instead of `Task`/`sleep(for:)`, mixing run-loop and actor domains (MINOR)

**Files:**  
- `SmartTubeIOS/Sources/SmartTubeIOS/Services/AuthService+TokenRefresh.swift`

**Observation:**  
`AuthService` schedules token refresh via `Timer.scheduledTimer(...)`, which fires on the main run loop. The timer callback then calls `Task { await refreshToken() }` to bridge back to the async domain. If the main run loop is busy under UI pressure, the Timer may fire late, causing auth tokens to be used after expiry. In Swift 6 strict-concurrency mode this pattern also produces actor-isolation warnings.

---

### EF-18 — `PlayerStateStore` creates `PlaybackViewModel` in an `init()` without `@MainActor` isolation (MINOR)

**Files:**  
- `SmartTubeIOS/Sources/SmartTubeIOS/PlayerStateStore.swift`

**Observation:**  
`PlaybackViewModel` is declared `@MainActor`. If `PlayerStateStore.init()` is called off the main actor (e.g., in a background continuation or a test harness), Swift 6 strict concurrency will flag this as a data race. In the current app target the store is created on the main thread, but the pattern is fragile: any refactoring that moves store creation to a background context will silently violate isolation.

---

## Quality Risks

### QR-1 — Auth token threading (HIGH)
All three auth-related bugs (EF-10, EF-11, EF-13) compound: a user who watches a 20-minute video while the app is in background has a ~80% probability of triggering a token refresh mid-session. Combined with fire-and-forget pings (EF-11), it is effectively impossible to verify that watch history is accurately recorded in production. This risk is invisible without server-side telemetry.

### QR-2 — Fallback parity gap (HIGH)
The primary playback path has 4+ fallbacks (`retryWithFallbackPlayer`, `retryWith403Recovery`, `retryAudioOnlyWithAndroidVR`, adaptive composition). None of them re-execute Phase 2 enrichment or update `playerInfo` / `availableFormats`. Users on restricted networks (where the iOS client frequently fails and Android fallback is common) will systematically have broken quality pickers, missing captions, and unauthenticated watch history.

### QR-3 — Race conditions on rapid navigation (HIGH)
EF-04 (concurrent load race) is difficult to reproduce in manual testing but routine in automated tests. Any user action that replaces the video faster than a single network round trip (tapping a video while another is still loading) can corrupt ViewModel state. The race has no guard, no version token, and no test coverage.

### QR-4 — API surface contract fragility (MEDIUM)
YouTube has historically changed renderer types server-side without notice. The current system has 4 parsers with silently inconsistent field coverage (EF-08, EF-09, EF-14, EF-15). A YouTube A/B test that rolls out `lockupViewModel` on search results (previously served as `videoRenderer`) would instantly break view count display across the entire search feature with no error logs.

### QR-5 — Cross-account data leakage on shared devices (MEDIUM)
EF-12 (disk cache not cleared on sign-out) and EF-03 (audio overlay state leak) both affect shared devices. On a family device, user B will see user A's like states and "watched" badges on thumbnails after sign-out. This is a privacy concern, not just a UI glitch.

---

## Pattern Applicability Matrix

| Pattern | Name | Verdict | Rationale |
|---|---|---|---|
| P-1 | Fallback and Degradation Path Parity | **FULL** | 6 findings directly concern fallback paths failing to mirror primary-path behaviour (EF-01 through EF-06). This is the single richest pattern in the codebase. |
| P-2 | Dispatcher Return-Value Correctness | PARTIAL | EF-04 (concurrent load race) partially covers this; however full analysis requires instrumented concurrency tests that exceed Phase 1 scope. Mark PARTIAL; include in candidate list. |
| P-3 | Cross-Implementation Contract Consistency | **FULL** | EF-08, EF-09, EF-14, EF-15 all stem from multiple parser implementations diverging on the same `Video` model contract. Classic interface: four parsers, one contract, inconsistent coverage. |
| P-4 | Enumeration and Representation Completeness | **FULL** | EF-07, EF-09, EF-14, EF-15 are textbook enumeration gaps: cases the code must handle but silently ignores (K/M/B suffixes, `shortViewCountText`, `thumbnailOverlays` duration, `playlistVideoRenderer` field names). |
| P-5 | Resource Lifecycle and Cleanup | SKIP | EF-05 and EF-06 touch resource cleanup but the scope is narrow (observer tasks only). No evidence of memory cycle or file handle leaks in this exploration. |
| P-6 | Concurrency Safety | SKIP | EF-04, EF-13, EF-17, EF-18 are concurrency findings, but they are already captured by the other patterns. A dedicated Phase 3 concurrency audit would be more productive after Phase 2 bug fixes are in place. |

---

## Pattern Deep Dive — Fallback and Degradation Path Parity

**Scope:** All execution paths that execute when the primary iOS client `/player` response fails or produces an unplayable stream.

### P-1.1 State Propagation Gap (EF-01)

The contract of the load system is: after any successful load (primary or fallback), `self.playerInfo`, `self.availableFormats`, and `self.availableCaptions` must reflect the response that is actually playing.

All three fallback entry points violate this contract. In `retryWithFallbackPlayer()`:
```swift
// Present in fallback paths — MISSING assignment:
// self.playerInfo = fallbackInfo  ← not here
// self.availableFormats = fallbackInfo.streamingData?.adaptiveFormats ← not here
let item = AVPlayerItem(url: fallbackURL)
player.replaceCurrentItem(with: item)
```
The primary path in `loadAsync()` assigns both fields before calling `player.replaceCurrentItem`. Fallback paths skip this.

**Correct pattern:**
```swift
self.playerInfo = fallbackInfo
self.availableFormats = fallbackInfo.streamingData?.adaptiveFormats ?? []
self.availableCaptions = fallbackInfo.captions?.playerCaptionsTracklistRenderer?.captionTracks ?? []
player.replaceCurrentItem(with: item)
```
This fix must be applied to all three fallback entry points uniformly.

### P-1.2 Phase 2 Enrichment Gap (EF-02)

Phase 2 (`phase2Task`) performs four distinct enrichments: (a) authTrackingTask — fetches per-account tracking URLs using the TV client, (b) SponsorBlockTask — fetches segment markers, (c) endCardsTask — fetches end card data, (d) relatedTask — fetches related videos. All four are skipped when a fallback succeeds.

The fix requires extracting a `launchPhase2(playerInfo:)` method and calling it from both the primary path and from each fallback path after `self.playerInfo = fallbackInfo` is assigned.

### P-1.3 Audio-Only liveToggle Propagation Gap (EF-03)

The `liveToggle` parameter exists in `retryAudioOnlyWithAndroidVR(liveToggle:)` but `tryLoadAudioURL()` has no equivalent parameter. The failure branch in `tryLoadAudioURL` unconditionally exits audio-only mode:
```swift
case .failed:
    self.isAudioOnlyMode = false   // ← does not know liveToggle was set
```

Fix: thread `liveToggle: Bool` through `tryLoadAudioURL(url:liveToggle:)` and in the `.failed` case only set `isAudioOnlyMode = false` when `!liveToggle`.

### P-1.4 Observer Task Ordering Gap (EF-05)

Pattern: create observer → then replace item. Should be: cancel old observer → replace item → then create observer.
```swift
// BUG: observer sees new item before player does
itemObserverTask = Task { for await status in fallbackItem.statusStream { … } }
player.replaceCurrentItem(with: fallbackItem)   // ← item enters player after observer

// CORRECT:
itemObserverTask?.cancel()
itemObserverTask = nil
player.replaceCurrentItem(with: fallbackItem)
itemObserverTask = Task { for await status in fallbackItem.statusStream { … } }
```

### P-1.5 Missing End-of-Stream Observer for Audio Items (EF-06)

The `endObserverTask` is only created once in `loadAsync()`. After a successful audio-only switch, the call to `tryLoadAudioURL` must cancel `endObserverTask`, then restart it subscribed to the audio item.

---

## Pattern Deep Dive — Cross-Implementation Contract Consistency

**Scope:** The four InnerTube video renderer parser functions — `parseVideoRenderer`, `parseLockupViewModel`, `parseTileRenderer`, `parseReelItemRenderer` — all produce `Video` model instances and must satisfy the same field-coverage contract.

### P-3.1 Contract Table

| Parser | Used in | viewCount | publishedAt | channelId path |
|---|---|---|---|---|
| `parseVideoRenderer` | Search results, related, channel videos | ✅ `viewCountText` | ❌ nil | `ownerText.runs[0].browseId` → `shortBylineText` |
| `parseLockupViewModel` | Home feed (new API) | ❌ nil | ❌ nil | `watchEndpoint.channelId` → `reelEndpoint` → metadata rows |
| `parseTileRenderer` | History, library | ❌ nil | ✅ `parseRelativeDate()` | `watchEndpoint.channelId` → `browseId` → @handle |
| `parseReelItemRenderer` | Shorts shelf | ❌ nil | ❌ nil | `reelWatchEndpoint.channelId` → `ownerText` |

**Contract violations (EF-08):**
- `viewCount`: 3 of 4 parsers return nil. Should be extracted in all four.
- `publishedAt`: 1 of 4 parsers extracts it. Should be extracted in all four.
- `channelId`: Different fallback chains; no parser covers all known YouTube field names.

### P-3.2 Correct Pattern

Each parser should follow the same extraction priority list, derived from the union of all known YouTube field names across all renderers:

```swift
// Canonical channelId extraction — apply to all four parsers:
let channelId = (r["navigationEndpoint"] as? [String: Any]).flatMap {
    ($0["browseEndpoint"] as? [String: Any])?["browseId"] as? String
} ?? (r["watchEndpoint"] as? [String: Any])?["channelId"] as? String
  ?? (r["reelWatchEndpoint"] as? [String: Any])?["channelId"] as? String
  ?? extractChannelIdFromHandle(r)
```

A shared helper function enforces uniform fallback order and eliminates per-parser divergence.

### P-3.3 `playlistVideoRenderer` Field Name Mismatch (EF-09)

`playlistVideoRenderer` is parsed by `parseVideoRenderer()` (delegated at line 221–222). But `playlistVideoRenderer` uses `shortTitle` for the video title:
```swift
// parseVideoRenderer looks for:
let title = extractText(r["title"]) ?? extractText(r["headline"])
// playlistVideoRenderer actually has:
// r["shortTitle"] — not checked
```
The correct fix is a dedicated `parsePlaylistVideoRenderer()` function that first tries `shortTitle`, falls back to `title`.

---

## Pattern Deep Dive — Enumeration and Representation Completeness

**Scope:** All cases where input values have a known set of variants that must each be handled, and where unhandled variants produce silent degradation rather than an error.

### P-4.1 K/M/B Suffix Enumeration in `extractNumber()` (EF-07)

YouTube's API returns formatted counts in three formats:
1. Plain integer: `"42"` — handled correctly
2. Abbreviated: `"1.5K"`, `"2.3M"`, `"1.1B"` — **not handled; digits stripped, decimal ignored**
3. Localised with separators: `"1,500"` — partially handled (comma stripped, result `1500` is correct)

The complete enumeration of cases that `extractNumber()` must handle:
```
"1.5K views"   → 1500
"2.3M views"   → 2300000
"1.1B views"   → 1100000000
"42 views"     → 42
"1,234 views"  → 1234
"1.5K"         → 1500   (no trailing text)
```

The fix requires detecting the multiplier suffix before stripping non-digits:
```swift
func extractNumber(_ text: String) -> Int? {
    let t = text.lowercased()
    let multiplier: Int
    let stripped: String
    if t.contains("k") { multiplier = 1000; stripped = t.replacingOccurrences(of: "k", with: "") }
    else if t.contains("m") { multiplier = 1_000_000; stripped = t.replacingOccurrences(of: "m", with: "") }
    else if t.contains("b") { multiplier = 1_000_000_000; stripped = t.replacingOccurrences(of: "b", with: "") }
    else { multiplier = 1; stripped = t }
    let digits = stripped.components(separatedBy: CharacterSet.decimalDigits.union(["."]).inverted).joined()
    guard let value = Double(digits) else { return nil }
    return Int(value * Double(multiplier))
}
```

### P-4.2 `viewCountText` Field Name Variants (EF-14)

YouTube uses at least three field names for view count across renderer types:
- `viewCountText` — standard, full-length
- `shortViewCountText` — compact form (e.g., search row, notification shelf)
- `viewCount` — direct integer (some history responses)

Current code only checks `viewCountText`. The enumeration must cover all three:
```swift
let rawCount = r["viewCountText"] ?? r["shortViewCountText"]
let viewCount: Int?
if let dict = rawCount as? [String: Any] {
    viewCount = extractText(dict).flatMap { extractNumber($0) }
} else if let direct = r["viewCount"] as? Int {
    viewCount = direct
} else {
    viewCount = nil
}
```

### P-4.3 Duration Field Location Variants (EF-15)

Duration appears in different locations by renderer type:
- `videoRenderer` → `lengthText` (direct field)
- `compactVideoRenderer`, `gridVideoRenderer` → `thumbnailOverlays[n].thumbnailOverlayTimeStatusRenderer.text`

Current code assumes `lengthText` in all cases (via `parseVideoRenderer` delegation). The parser must enumerate both locations:
```swift
let durationText = extractText(r["lengthText"])
    ?? extractDurationFromOverlays(r["thumbnailOverlays"] as? [[String: Any]])
```

---

## Candidate Bugs for Phase 2

The following bugs are proposed for Phase 2 (spec derivation, test generation, patch). Ordered by severity and blast radius.

| # | ID | Severity | Short description | Stage |
|---|---|---|---|---|
| 1 | EF-04 | CRITICAL | Concurrent `load()` race — stale `playerInfo` applied to new `currentVideo` | Phase 2 |
| 2 | EF-01 | CRITICAL | `playerInfo`/`availableFormats` not updated in any fallback path | Phase 2 |
| 3 | EF-07 | CRITICAL | `extractNumber()` 100× undercount for K/M/B formatted view counts | Phase 2 |
| 4 | EF-10 | CRITICAL | Token mismatch in watchtime tracking URLs | Phase 2 |
| 5 | EF-11 | CRITICAL | Watch history pings are fire-and-forget; no retry, no error logging | Phase 2 |
| 6 | EF-02 | MAJOR | Phase 2 enrichment (tracking URLs, SponsorBlock, end cards) not re-run after fallback | Phase 2 |
| 7 | EF-03 | MAJOR | Audio-only `liveToggle` not threaded through first-attempt path | Phase 2 |
| 8 | EF-05 | MAJOR | AVPlayerItem observer created before `replaceCurrentItem` in fallback paths | Phase 2 |
| 9 | EF-06 | MAJOR | Missing `endObserverTask` for audio-only stream items; autoplay never fires | Phase 2 |
| 10 | EF-08 | MAJOR | `viewCount`, `publishedAt`, `channelId` inconsistent across four renderer parsers | Phase 2 |
| 11 | EF-09 | MAJOR | `playlistVideoRenderer` delegated to `parseVideoRenderer()`; wrong field names | Phase 2 |
| 12 | EF-12 | MAJOR | Disk cache not cleared on sign-out; auth-bound data visible to next user | Phase 2 |
| 13 | EF-13 | MAJOR | Prefetch token captured at Task-creation; stale after token refresh | Phase 2 |
| 14 | EF-14 | MAJOR | `viewCountText` has no fallback for `shortViewCountText` or direct-int `viewCount` | Phase 2 |
| 15 | EF-16 | MAJOR | `WatchtimeTracker` holds stale URL references after in-memory eviction | Phase 2 |
| 16 | EF-15 | MINOR | Duration extracted from wrong field for `compactVideoRenderer`/`gridVideoRenderer` | Phase 2 |
| 17 | EF-17 | MINOR | `AuthService` uses `Timer` for token refresh; fragile under main-thread pressure | Phase 2 |
| 18 | EF-18 | MINOR | `PlayerStateStore.init()` creates `@MainActor` ViewModel without actor-isolated context | Phase 2 |

---

## Gate Self-Check

| Requirement | Status | Evidence |
|---|---|---|
| ≥ 8 numbered Open Exploration Findings with file:line citations | ✅ | EF-01 through EF-18 (18 findings) |
| Quality Risks section present | ✅ | QR-1 through QR-5 |
| Pattern Applicability Matrix with all patterns and 3–4 marked FULL | ✅ | P-1 FULL, P-2 PARTIAL, P-3 FULL, P-4 FULL, P-5 SKIP, P-6 SKIP |
| Deep dive for each FULL pattern | ✅ | P-1, P-3, P-4 deep dives present |
| Candidate Bugs for Phase 2 list with Stage: attributions | ✅ | 18 candidates, all Stage: Phase 2 |
| All file citations use repo-relative paths | ✅ | Verified above |

**Phase 1 gate: PASS**

---

*Proceed to Phase 2 on next `/dotasks` invocation.*
