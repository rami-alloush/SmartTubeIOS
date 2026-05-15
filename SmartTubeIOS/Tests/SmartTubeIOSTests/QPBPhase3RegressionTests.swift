import Foundation
import Testing
@testable import SmartTubeIOSCore

// MARK: - QPB Phase 3 Regression Tests
//
// Each test is marked `withKnownIssue` — it documents a confirmed bug.
// When the fix lands, remove the `withKnownIssue` wrapper and the test becomes a permanent guard.
//
// BUG IDs correspond to quality/BUGS.md entries.

@Suite("QPB Phase 3 Regressions — InnerTubeAPI+TextHelpers")
struct BUG001ExtractNumberKSuffixTests {

    // MARK: - BUG-001: extractNumber silently undercounts K/M/B-suffixed view counts

    @Test("BUG-001 [xfail] 1.5K views → 1500 (not 15)")
    func extractNumber_1500K_returns1500() {
        // Given a view count string using YouTube's compact notation
        let text = "1.5K views"

        // Resolve via the public Video parsing path: parseTileRenderer / parseVideoRenderer
        // uses extractNumber internally. We exercise it via a synthetic renderer dict.
        let rendererDict: [String: Any] = [
            "videoId": "testid",
            "headline": ["runs": [["text": "Test Title"]]],
            "shortBylineText": ["runs": [["text": "Channel", "navigationEndpoint": ["browseEndpoint": ["browseId": "UCtest"]]]]],
            "viewCountText": ["simpleText": text],
            "thumbnail": ["thumbnails": [["url": "https://i.ytimg.com/vi/testid/hqdefault.jpg"]]],
        ]

        let api = InnerTubeAPI(authToken: nil, userAgent: "Test/1.0")
        let video = api.testHook_parseTileRendererDict(rendererDict)

        withKnownIssue("BUG-001: extractNumber strips K suffix as non-digit — '1.5K views' → 15 instead of 1500") {
            #expect(video?.viewCount == 1500, "1.5K views should parse to 1500")
        }
    }

    @Test("BUG-001 [xfail] 2.3M views → 2300000 (not 23)")
    func extractNumber_2300000M_returns2300000() {
        let text = "2.3M views"
        let rendererDict: [String: Any] = [
            "videoId": "testid2",
            "headline": ["runs": [["text": "Test Title"]]],
            "shortBylineText": ["runs": [["text": "Channel", "navigationEndpoint": ["browseEndpoint": ["browseId": "UCtest2"]]]]],
            "viewCountText": ["simpleText": text],
            "thumbnail": ["thumbnails": [["url": "https://i.ytimg.com/vi/testid2/hqdefault.jpg"]]],
        ]
        let api = InnerTubeAPI(authToken: nil, userAgent: "Test/1.0")
        let video = api.testHook_parseTileRendererDict(rendererDict)

        withKnownIssue("BUG-001: extractNumber strips M suffix — '2.3M views' → 23 instead of 2300000") {
            #expect(video?.viewCount == 2_300_000, "2.3M views should parse to 2300000")
        }
    }

    @Test("BUG-001 plain integers still work after fix")
    func extractNumber_plainInt_returnsCorrectly() {
        // Sanity: plain integers are NOT broken — this should pass now and after the fix.
        let text = "1234 views"
        let rendererDict: [String: Any] = [
            "videoId": "testid3",
            "headline": ["runs": [["text": "Test Title"]]],
            "shortBylineText": ["runs": [["text": "Channel", "navigationEndpoint": ["browseEndpoint": ["browseId": "UCtest3"]]]]],
            "viewCountText": ["simpleText": text],
            "thumbnail": ["thumbnails": [["url": "https://i.ytimg.com/vi/testid3/hqdefault.jpg"]]],
        ]
        let api = InnerTubeAPI(authToken: nil, userAgent: "Test/1.0")
        let video = api.testHook_parseTileRendererDict(rendererDict)
        #expect(video?.viewCount == 1234)
    }
}

@Suite("QPB Phase 3 Regressions — VideoRenderers parsers")
struct BUG011ViewCountParserTests {

    // MARK: - BUG-011: parseLockupViewModel, parseTileRenderer, parseReelItemRenderer viewCount: nil

    @Test("BUG-011 [xfail] parseTileRenderer extracts viewCount from viewCountText")
    func parseTileRenderer_viewCountTextPresent_extractsViewCount() {
        let tileRendererDict: [String: Any] = [
            "tileMetadata": [
                "lines": [
                    ["lineRenderer": ["items": [["lineItemRenderer": ["text": ["runs": [["text": "Channel"]]]]]]]],
                    ["lineRenderer": ["items": [["lineItemRenderer": ["text": ["simpleText": "1.2K views"]]]]]]],
                ]
            ],
            "onSelectCommand": ["watchEndpoint": ["videoId": "tilevidid"]],
            "thumbnail": ["thumbnails": [["url": "https://i.ytimg.com/vi/tilevidid/mqdefault.jpg"]]],
        ]

        let api = InnerTubeAPI(authToken: nil, userAgent: "Test/1.0")
        let video = api.testHook_parseTileRendererDict(tileRendererDict)

        withKnownIssue("BUG-011: parseTileRenderer hardcodes viewCount: nil") {
            #expect(video?.viewCount != nil, "tileRenderer should extract viewCount from viewCountText line")
        }
    }

    @Test("BUG-011 [xfail] parseReelItemRenderer extracts viewCount from viewCountText")
    func parseReelItemRenderer_viewCountTextPresent_extractsViewCount() {
        let reelDict: [String: Any] = [
            "videoId": "shortsvid",
            "headline": ["simpleText": "Shorts Title"],
            "viewCountText": ["runs": [["text": "1.5K"], ["text": " views"]]],
            "thumbnail": ["thumbnails": [["url": "https://i.ytimg.com/vi/shortsvid/hqdefault.jpg"]]],
            "navigationEndpoint": ["reelWatchEndpoint": ["videoId": "shortsvid"]],
        ]

        let api = InnerTubeAPI(authToken: nil, userAgent: "Test/1.0")
        let video = api.testHook_parseReelItemRendererDict(reelDict)

        withKnownIssue("BUG-011: parseReelItemRenderer hardcodes viewCount: nil") {
            #expect(video?.viewCount != nil, "reelItemRenderer should extract viewCount from viewCountText")
        }
    }
}

@Suite("QPB Phase 3 Regressions — VideoRenderers shortViewCountText")
struct BUG014ShortViewCountTextTests {

    // MARK: - BUG-014: shortViewCountText not checked

    @Test("BUG-014 [xfail] parseVideoRenderer extracts viewCount from shortViewCountText when viewCountText absent")
    func parseVideoRenderer_shortViewCountTextFallback_extractsViewCount() {
        // Simulate a renderer that has shortViewCountText but not viewCountText
        let rendererDict: [String: Any] = [
            "videoId": "vidshort",
            "title": ["runs": [["text": "Video Title"]]],
            "ownerText": ["runs": [["text": "Channel", "navigationEndpoint": ["browseEndpoint": ["browseId": "UCshort"]]]]],
            "shortViewCountText": ["simpleText": "1.2K"],
            // viewCountText intentionally absent
            "thumbnail": ["thumbnails": [["url": "https://i.ytimg.com/vi/vidshort/hqdefault.jpg"]]],
        ]

        let api = InnerTubeAPI(authToken: nil, userAgent: "Test/1.0")
        let video = api.testHook_parseVideoRendererDict(rendererDict)

        withKnownIssue("BUG-014: shortViewCountText never checked — viewCount returns nil when viewCountText absent") {
            #expect(video?.viewCount != nil, "Should fall back to shortViewCountText when viewCountText absent")
        }
    }
}

@Suite("QPB Phase 3 Regressions — VideoPreloadCache auth eviction")
struct BUG013DiskCacheEvictionTests {

    // MARK: - BUG-013: evictAuthSensitiveData does not clear VideoDiskCache

    @Test("BUG-013 [xfail] evictAuthSensitiveData clears disk nextInfo")
    func evictAuthSensitiveData_clearsDiskNextInfo() async {
        // Precondition: store a NextInfo with likeStatus into the cache (which persists to disk)
        let cache = VideoPreloadCache.shared
        let videoId = "bug013-test-\(Int.random(in: 1_000_000...9_999_999))"

        // Warm the cache with a synthetic NextInfo that has a like status
        let nextInfo = NextInfo(
            relatedVideos: [],
            likeStatus: .liked,
            isSubscribed: true,
            channelId: "UC_test",
            endCards: []
        )
        await cache.testHook_storeNextInfo(nextInfo, for: videoId)

        // Evict auth sensitive data (sign-out)
        cache.evictAuthSensitiveData()

        // Bug: the disk copy still has the old nextInfo — consuming will re-warm from disk
        let consumed = await cache.consumeNextInfo(for: videoId)

        withKnownIssue("BUG-013: evictAuthSensitiveData does not call disk.removeAll() — nextInfo with likeStatus survives sign-out") {
            #expect(consumed == nil || consumed?.likeStatus == nil,
                    "After evictAuthSensitiveData, no auth-sensitive nextInfo should be retrievable")
        }
    }
}
