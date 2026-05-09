import Foundation
import Testing
@testable import SmartTubeIOSCore

// MARK: - VideoModelTests

@Suite("Video Model")
struct VideoModelTests {

    @Test func formattedDurationMinutesSeconds() {
        let video = Video(id: "test", title: "Test", channelTitle: "Channel", duration: 125)
        #expect(video.formattedDuration == "2:05")
    }

    @Test func formattedDurationWithHours() {
        let video = Video(id: "test", title: "Test", channelTitle: "Channel", duration: 3661)
        #expect(video.formattedDuration == "1:01:01")
    }

    @Test func formattedDurationNil() {
        let video = Video(id: "test", title: "Test", channelTitle: "Channel")
        #expect(video.formattedDuration == "")
    }

    @Test func formattedViewCountThousands() {
        let video = Video(id: "v", title: "T", channelTitle: "C", viewCount: 1_500)
        #expect(video.formattedViewCount == "1.5K views")
    }

    @Test func formattedViewCountMillions() {
        let video = Video(id: "v", title: "T", channelTitle: "C", viewCount: 2_000_000)
        #expect(video.formattedViewCount == "2.0M views")
    }

    @Test func highQualityThumbnailURL() {
        let video = Video(id: "dQw4w9WgXcQ", title: "T", channelTitle: "C")
        #expect(video.highQualityThumbnailURL == URL(string: "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg"))
    }

    @Test func videoHashableAndEquatable() {
        let v1 = Video(id: "abc", title: "A", channelTitle: "X")
        let v2 = Video(id: "abc", title: "A", channelTitle: "X")
        let v3 = Video(id: "xyz", title: "B", channelTitle: "Y")
        #expect(v1 == v2)
        #expect(v1 != v3)
    }
}

// MARK: - VideoGroupTests

@Suite("Video Group")
struct VideoGroupTests {

    @Test func defaultSections() {
        let sections = BrowseSection.defaultSections
        #expect(!sections.isEmpty)
        #expect(sections.first?.type == .home)
    }

    @Test func videoGroupAppend() {
        var group = VideoGroup(title: "Home", videos: [
            Video(id: "1", title: "V1", channelTitle: "C"),
        ])
        group.videos.append(Video(id: "2", title: "V2", channelTitle: "C"))
        #expect(group.videos.count == 2)
    }
}

// MARK: - AppSettingsTests

@Suite("App Settings")
struct AppSettingsTests {

    @Test func defaultSettings() {
        let settings = AppSettings()
        #expect(settings.preferredQuality == .auto)
        #expect(settings.playbackSpeed == 1.0)
        #expect(settings.autoplayEnabled)
        #expect(!settings.subtitlesEnabled)
        #expect(settings.sponsorBlockEnabled)
        #expect(!settings.deArrowEnabled)
        #expect(settings.themeName == .system)
        #expect(settings.perDeviceRecommendationsEnabled == true)
    }

    @Test func settingsEncodeDecode() throws {
        var settings = AppSettings()
        settings.preferredQuality    = .q1080
        settings.playbackSpeed       = 1.5
        settings.sponsorBlockEnabled = false

        let data    = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)

        #expect(decoded.preferredQuality == AppSettings.VideoQuality.q1080)
        #expect(decoded.playbackSpeed == 1.5)
        #expect(!decoded.sponsorBlockEnabled)
    }
}

// MARK: - SponsorSegmentTests

@Suite("Sponsor Segment")
struct SponsorSegmentTests {

    @Test func segmentInRange() {
        let seg = SponsorSegment(start: 30.0, end: 60.0, category: .sponsor)
        #expect(45.0 >= seg.start && 45.0 < seg.end)
        #expect(!(25.0 >= seg.start && 25.0 < seg.end))
    }

    @Test func allCategoryRawValuesUnique() {
        let raws = SponsorSegment.Category.allCases.map { $0.rawValue }
        #expect(Set(raws).count == raws.count)
    }
}

// MARK: - VideoFormatTests

@Suite("Video Format")
struct VideoFormatTests {

    @Test func qualityLabel30fps() {
        let f = VideoFormat(label: "720p", width: 1280, height: 720, fps: 30, mimeType: "video/mp4")
        #expect(f.qualityLabel == "720p")
    }

    @Test func qualityLabel60fps() {
        let f = VideoFormat(label: "1080p60", width: 1920, height: 1080, fps: 60, mimeType: "video/mp4")
        #expect(f.qualityLabel == "1080p60")
    }
}

// MARK: - SubscriptionParsingTests
// Validates that the InnerTubeAPI parser handles the gridVideoRenderer format used
// in the YouTube FEsubscriptions response.

@Suite("Subscription Parsing")
struct SubscriptionParsingTests {

    /// Minimal mock of the `onResponseReceivedActions` structure returned
    /// by a successfully authenticated `POST /browse?browseId=FEsubscriptions` call.
    @Test func gridVideoRendererParsed() async throws {
        let mockSubscriptionsResponse: [String: Any] = [
            "responseContext": ["visitorData": "abc"],
            "trackingParams": "xyz",
            "onResponseReceivedActions": [
                [
                    "appendContinuationItemsAction": [
                        "continuationItems": [
                            [
                                "gridVideoRenderer": [
                                    "videoId": "dQw4w9WgXcQ",
                                    "title": ["runs": [["text": "Rick Astley - Never Gonna Give You Up"]]],
                                    "shortBylineText": [
                                        "runs": [
                                            [
                                                "text": "Rick Astley",
                                                "navigationEndpoint": [
                                                    "browseEndpoint": [
                                                        "browseId": "UCuAXFkgsw1L7xaCfnd5JJOw"
                                                    ]
                                                ]
                                            ]
                                        ]
                                    ],
                                    "thumbnail": [
                                        "thumbnails": [
                                            ["url": "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg", "width": 480, "height": 360]
                                        ]
                                    ],
                                    "thumbnailOverlays": [
                                        [
                                            "thumbnailOverlayTimeStatusRenderer": [
                                                "text": ["simpleText": "3:33"],
                                                "style": "DEFAULT"
                                            ]
                                        ]
                                    ],
                                    "viewCountText": ["simpleText": "1,604,532,756 views"],
                                    "navigationEndpoint": ["watchEndpoint": ["videoId": "dQw4w9WgXcQ"]]
                                ]
                            ]
                        ]
                    ]
                ]
            ]
        ]

        let api = InnerTubeAPI()
        let group = try await api.parseVideoGroupForTesting(mockSubscriptionsResponse, title: "Subscriptions")

        #expect(group.videos.count == 1, "Should parse one gridVideoRenderer item")
        let video = try #require(group.videos.first)
        #expect(video.id == "dQw4w9WgXcQ")
        #expect(video.title == "Rick Astley - Never Gonna Give You Up")
        #expect(video.channelTitle == "Rick Astley")
        #expect(video.channelId == "UCuAXFkgsw1L7xaCfnd5JJOw")
        #expect(video.duration == 213)   // 3m 33s
    }

    @Test func videoRendererStillParsed() async throws {
        let mockHomeResponse: [String: Any] = [
            "contents": [
                "twoColumnBrowseResultsRenderer": [
                    "tabs": [
                        [
                            "tabRenderer": [
                                "content": [
                                    "richGridRenderer": [
                                        "contents": [
                                            [
                                                "richItemRenderer": [
                                                    "content": [
                                                        "videoRenderer": [
                                                            "videoId": "abc123",
                                                            "title": ["runs": [["text": "Test Video"]]],
                                                            "ownerText": ["runs": [["text": "Test Channel"]]],
                                                            "thumbnail": ["thumbnails": [
                                                                ["url": "https://i.ytimg.com/vi/abc123/hqdefault.jpg"]
                                                            ]],
                                                            "lengthText": ["simpleText": "10:00"]
                                                        ]
                                                    ]
                                                ]
                                            ]
                                        ]
                                    ]
                                ]
                            ]
                        ]
                    ]
                ]
            ]
        ]

        let api = InnerTubeAPI()
        let group = try await api.parseVideoGroupForTesting(mockHomeResponse, title: "Home")
        #expect(group.videos.count == 1, "richItemRenderer->videoRenderer should still parse")
        let video = try #require(group.videos.first)
        #expect(video.id == "abc123")
        #expect(video.duration == 600)  // 10:00 = 600s
    }
}

// MARK: - HistoryParsingTests
// Reproduces the "history shows only shorts" bug:
// TVHTML5 FEhistory tileRenderers can use either
//   onSelectCommand.watchEndpoint.videoId  (classic path)
//   onSelectCommand.innertubeCommand.watchEndpoint.videoId  (newer TV variant)
//   navigationEndpoint.watchEndpoint.videoId  (another TVHTML5 variant)
// Previously only the classic path was tried, causing all regular-video tiles
// to be silently dropped — leaving only reelItemRenderer (Shorts) visible.

@Suite("History Parsing")
struct HistoryParsingTests {

    // Mock that mirrors the classic TVHTML5 tileRenderer path
    // (onSelectCommand → watchEndpoint → videoId).
    @Test func tileRendererClassicPath() async throws {
        let mockResponse = makeTileResponse(videoId: "classic1", useInnertubeWrapper: false, useNavigation: false)
        let api = InnerTubeAPI()
        let group = try await api.parseVideoGroupForTesting(mockResponse, title: "History")
        #expect(group.videos.count == 1, "Classic onSelectCommand.watchEndpoint path should parse")
        let video = try #require(group.videos.first)
        #expect(video.id == "classic1")
        #expect(!video.isShort)
    }

    // Mock that mirrors the newer TVHTML5 variant where watchEndpoint is nested
    // under onSelectCommand → innertubeCommand → watchEndpoint → videoId.
    @Test func tileRendererInnertubeCommandPath() async throws {
        let mockResponse = makeTileResponse(videoId: "inner1", useInnertubeWrapper: true, useNavigation: false)
        let api = InnerTubeAPI()
        let group = try await api.parseVideoGroupForTesting(mockResponse, title: "History")
        #expect(group.videos.count == 1, "innertubeCommand-wrapped watchEndpoint path should parse")
        let video = try #require(group.videos.first)
        #expect(video.id == "inner1")
        #expect(!video.isShort)
    }

    // Mock that mirrors the TVHTML5 variant using navigationEndpoint instead of onSelectCommand.
    @Test func tileRendererNavigationEndpointPath() async throws {
        let mockResponse = makeTileResponse(videoId: "nav1", useInnertubeWrapper: false, useNavigation: true)
        let api = InnerTubeAPI()
        let group = try await api.parseVideoGroupForTesting(mockResponse, title: "History")
        #expect(group.videos.count == 1, "navigationEndpoint.watchEndpoint path should parse")
        let video = try #require(group.videos.first)
        #expect(video.id == "nav1")
        #expect(!video.isShort)
    }

    // Shorts in TVHTML5 history come back as reelItemRenderer — verify they still parse
    // and are correctly tagged isShort = true.
    @Test func reelItemRendererParsedAsShort() async throws {
        let mockResponse: [String: Any] = [
            "contents": [
                "reelShelfRenderer": [
                    "items": [
                        [
                            "reelItemRenderer": [
                                "videoId": "reel1",
                                "headline": ["simpleText": "My Short"]
                            ]
                        ]
                    ]
                ]
            ]
        ]
        let api = InnerTubeAPI()
        let group = try await api.parseVideoGroupForTesting(mockResponse, title: "History")
        #expect(group.videos.count == 1)
        let video = try #require(group.videos.first)
        #expect(video.id == "reel1")
        #expect(video.isShort)
    }

    // Mixed response: one regular tileRenderer (via innertubeCommand path) + one reelItemRenderer.
    // Before the fix history would only return 1 video (the Short); after the fix it returns 2.
    @Test func mixedHistoryBothRegularAndShort() async throws {
        let reelItem: [String: Any] = [
            "reelItemRenderer": [
                "videoId": "short1",
                "headline": ["simpleText": "A Short"]
            ]
        ]
        let tileItem: [String: Any] = [
            "tileRenderer": [
                "contentType": "TILE_CONTENT_TYPE_VIDEO",
                "onSelectCommand": [
                    "innertubeCommand": [
                        "watchEndpoint": ["videoId": "regular1"]
                    ]
                ],
                "metadata": [
                    "tileMetadataRenderer": [
                        "title": ["simpleText": "A Regular Video"]
                    ]
                ]
            ]
        ]
        let mockResponse: [String: Any] = [
            "contents": [
                "sectionListRenderer": [
                    "contents": [
                        ["itemSectionRenderer": ["contents": [tileItem]]],
                        ["itemSectionRenderer": ["contents": [reelItem]]]
                    ]
                ]
            ]
        ]
        let api = InnerTubeAPI()
        let group = try await api.parseVideoGroupForTesting(mockResponse, title: "History")
        #expect(group.videos.count == 2, "Both regular tile and Short should appear in history")
        let ids = Set(group.videos.map { $0.id })
        #expect(ids.contains("regular1"))
        #expect(ids.contains("short1"))
        let regular = group.videos.first { $0.id == "regular1" }
        let short   = group.videos.first { $0.id == "short1" }
        #expect(regular?.isShort == false)
        #expect(short?.isShort == true)
    }

    // Reproduces the confirmed live-API path: tileRenderer carries videoId in tile.contentId
    // and onSelectCommand uses commandExecutorCommand (no watchEndpoint anywhere).
    // Shape confirmed by live fetchHistory log on 2026-04-03.
    @Test func tileRendererContentIdPath() async throws {
        let tileRenderer: [String: Any] = [
            "contentType": "TILE_CONTENT_TYPE_VIDEO",
            "contentId": "RoLKhzJG3nc",
            "style": "TILE_STYLE_YTLR_DEFAULT",
            "onSelectCommand": [
                "clickTrackingParams": "abc",
                "commandExecutorCommand": ["commands": []]   // no watchEndpoint
            ],
            "metadata": [
                "tileMetadataRenderer": [
                    "title": ["simpleText": "Test via contentId"]
                ]
            ]
        ]
        let mockResponse: [String: Any] = [
            "contents": [
                "tvBrowseRenderer": [
                    "content": [
                        "tvSurfaceContentRenderer": [
                            "content": [
                                "gridRenderer": [
                                    "items": [["tileRenderer": tileRenderer]]
                                ]
                            ]
                        ]
                    ]
                ]
            ]
        ]
        let api = InnerTubeAPI()
        let group = try await api.parseVideoGroupForTesting(mockResponse, title: "History")
        #expect(group.videos.count == 1, "tileRenderer.contentId path should parse")
        let video = try #require(group.videos.first)
        #expect(video.id == "RoLKhzJG3nc")
        #expect(!video.isShort)
    }
}


// MARK: - Home Row Parsing Tests

@Suite("Home Row Parsing")
struct HomeRowParsingTests {

    // reelShelfRenderer at the top level of the home feed response should produce
    // a VideoGroup containing isShort == true videos.
    @Test func reelShelfRendererProducesShorts() async {
        let mockResponse: [String: Any] = [
            "contents": [
                "twoColumnBrowseResultsRenderer": [
                    "tabs": [[
                        "tabRenderer": [
                            "content": [
                                "richGridRenderer": [
                                    "contents": [
                                        [
                                            "richSectionRenderer": [
                                                "content": [
                                                    "reelShelfRenderer": [
                                                        "title": ["simpleText": "Shorts"],
                                                        "items": [
                                                            [
                                                                "reelItemRenderer": [
                                                                    "videoId": "short1",
                                                                    "headline": ["simpleText": "A Short"]
                                                                ]
                                                            ]
                                                        ]
                                                    ]
                                                ]
                                            ]
                                        ]
                                    ]
                                ]
                            ]
                        ]
                    ]]
                ]
            ]
        ]
        let api = InnerTubeAPI()
        let rows = await api.parseVideoGroupRowsForTesting(mockResponse)
        let shortsRow = rows.first { $0.videos.contains { $0.id == "short1" } }
        #expect(shortsRow != nil, "reelShelfRenderer should produce a row with shorts")
        #expect(shortsRow?.videos.first?.isShort == true)
    }

    // richShelfRenderer containing richItemRenderer wrapping a reelItemRenderer
    // (Shorts embedded inside a regular topic shelf) should surface the short.
    @Test func richShelfRendererWithEmbeddedReelItem() async {
        let mockResponse: [String: Any] = [
            "contents": [
                "twoColumnBrowseResultsRenderer": [
                    "tabs": [[
                        "tabRenderer": [
                            "content": [
                                "richGridRenderer": [
                                    "contents": [
                                        [
                                            "richShelfRenderer": [
                                                "title": ["simpleText": "Trending"],
                                                "contents": [
                                                    [
                                                        "richItemRenderer": [
                                                            "content": [
                                                                "reelItemRenderer": [
                                                                    "videoId": "embeddedShort1",
                                                                    "headline": ["simpleText": "Embedded Short"]
                                                                ]
                                                            ]
                                                        ]
                                                    ]
                                                ]
                                            ]
                                        ]
                                    ]
                                ]
                            ]
                        ]
                    ]]
                ]
            ]
        ]
        let api = InnerTubeAPI()
        let rows = await api.parseVideoGroupRowsForTesting(mockResponse)
        let row = rows.first { $0.videos.contains { $0.id == "embeddedShort1" } }
        #expect(row != nil, "richShelfRenderer with embedded reelItemRenderer should produce a row")
        #expect(row?.videos.first?.isShort == true)
    }
}

// MARK: - Helpers


// MARK: - TimeFormattingTests

@Suite("Time Formatting")
struct TimeFormattingTests {

    @Test("Zero seconds formats as 0:00")
    func zeroSeconds() {
        #expect(formatDuration(0) == "0:00")
    }

    @Test("Negative value is clamped to 0:00")
    func negativeClampedToZero() {
        #expect(formatDuration(-10) == "0:00")
    }

    @Test("Exactly one minute formats as 1:00")
    func exactlyOneMinute() {
        #expect(formatDuration(60) == "1:00")
    }

    @Test("59 minutes 59 seconds has no hours component")
    func hoursThreshold() {
        #expect(formatDuration(3599) == "59:59")
    }

    @Test("Exactly one hour shows H:MM:SS")
    func exactlyOneHour() {
        #expect(formatDuration(3600) == "1:00:00")
    }

    @Test("Large value 23:59:59 formats correctly")
    func largeValue() {
        #expect(formatDuration(86399) == "23:59:59")
    }

    @Test("Single digit seconds are zero-padded")
    func singleDigitSecondsPadded() {
        #expect(formatDuration(65) == "1:05")
    }

    @Test("Single digit minutes in hour format are zero-padded")
    func singleDigitMinuteInHourFormat() {
        #expect(formatDuration(3661) == "1:01:01")
    }
}

// MARK: - AudioTrackTests

@Suite("Audio Track")
struct AudioTrackTests {

    @Test("Init preserves all fields")
    func initPreservesFields() {
        let track = AudioTrack(id: "en", name: "English", languageCode: "en", isOriginal: true)
        #expect(track.id == "en")
        #expect(track.name == "English")
        #expect(track.languageCode == "en")
        #expect(track.isOriginal == true)
    }

    @Test("Tracks with same values are equal")
    func equalTracksAreEqual() {
        let a = AudioTrack(id: "en", name: "English", languageCode: "en", isOriginal: true)
        let b = AudioTrack(id: "en", name: "English", languageCode: "en", isOriginal: true)
        #expect(a == b)
    }

    @Test("Tracks with different id are not equal")
    func differentIdNotEqual() {
        let a = AudioTrack(id: "en", name: "English", languageCode: "en", isOriginal: true)
        let b = AudioTrack(id: "es", name: "Spanish", languageCode: "es", isOriginal: false)
        #expect(a != b)
    }

    @Test("AudioTrack can be inserted into a Set")
    func canBeStoredInSet() {
        let a = AudioTrack(id: "en", name: "English", languageCode: "en", isOriginal: true)
        let b = AudioTrack(id: "es", name: "Spanish", languageCode: "es", isOriginal: false)
        let set: Set<AudioTrack> = [a, b, a]
        #expect(set.count == 2)
    }

    @Test("Non-original track stores isOriginal false")
    func nonOriginalTrack() {
        let track = AudioTrack(id: "fr", name: "French", languageCode: "fr", isOriginal: false)
        #expect(!track.isOriginal)
    }
}

// MARK: - InnerTubeAPI Parsing Gap Tests

@Suite("InnerTube API Parsing Gaps")
struct InnerTubeAPIParsingGapsTests {

    // MARK: - Shorts tagging

    @Test("tileRenderer with TILE_STYLE_YTLR_SHORTS style is tagged isShort = true")
    func tileRendererShortsTagged() async throws {
        let mockResponse: [String: Any] = [
            "contents": [
                "sectionListRenderer": [
                    "contents": [
                        [
                            "itemSectionRenderer": [
                                "contents": [
                                    [
                                        "tileRenderer": [
                                            "contentType": "TILE_CONTENT_TYPE_VIDEO",
                                            "style": "TILE_STYLE_YTLR_SHORTS",
                                            "contentId": "short1234567",
                                            "metadata": [
                                                "tileMetadataRenderer": [
                                                    "title": ["simpleText": "A Short"]
                                                ]
                                            ],
                                            "onSelectCommand": [
                                                "watchEndpoint": ["videoId": "short1234567"]
                                            ]
                                        ]
                                    ]
                                ]
                            ]
                        ]
                    ]
                ]
            ]
        ]
        let api = InnerTubeAPI()
        let group = try await api.parseVideoGroupForTesting(mockResponse, title: "History")
        let video = try #require(group.videos.first)
        #expect(video.isShort, "TILE_STYLE_YTLR_SHORTS tile must be tagged isShort = true")
    }

    @Test("videoRenderer with reelWatchEndpoint is tagged isShort = true")
    func videoRendererReelEndpointTaggedShort() async throws {
        let mockResponse: [String: Any] = [
            "contents": [
                "twoColumnBrowseResultsRenderer": [
                    "tabs": [[
                        "tabRenderer": [
                            "content": [
                                "richGridRenderer": [
                                    "contents": [
                                        [
                                            "richItemRenderer": [
                                                "content": [
                                                    "videoRenderer": [
                                                        "videoId": "short1234567",
                                                        "title": ["runs": [["text": "A Short Video"]]],
                                                        "ownerText": ["runs": [["text": "Channel"]]],
                                                        "thumbnail": ["thumbnails": [
                                                            ["url": "https://i.ytimg.com/vi/short1234567/hqdefault.jpg"]
                                                        ]],
                                                        "navigationEndpoint": [
                                                            "reelWatchEndpoint": ["videoId": "short1234567"]
                                                        ]
                                                    ]
                                                ]
                                            ]
                                        ]
                                    ]
                                ]
                            ]
                        ]
                    ]]
                ]
            ]
        ]
        let api = InnerTubeAPI()
        let group = try await api.parseVideoGroupForTesting(mockResponse, title: "Home")
        let video = try #require(group.videos.first)
        #expect(video.isShort, "videoRenderer with reelWatchEndpoint must be tagged isShort = true")
    }

    // MARK: - Empty response

    @Test("Empty JSON response produces an empty VideoGroup")
    func emptyContentsReturnsEmptyGroup() async throws {
        let api = InnerTubeAPI()
        let group = try await api.parseVideoGroupForTesting([:], title: nil)
        #expect(group.videos.isEmpty)
    }

    // MARK: - Multiple items

    @Test("Three richItemRenderer entries all produce three Videos")
    func multipleRichItemRenderersAllParsed() async throws {
        func makeItem(_ videoId: String) -> [String: Any] {
            [
                "richItemRenderer": [
                    "content": [
                        "videoRenderer": [
                            "videoId": videoId,
                            "title": ["runs": [["text": "Video \(videoId)"]]],
                            "ownerText": ["runs": [["text": "Channel"]]],
                            "thumbnail": ["thumbnails": [
                                ["url": "https://i.ytimg.com/vi/\(videoId)/hqdefault.jpg"]
                            ]],
                            "navigationEndpoint": ["watchEndpoint": ["videoId": videoId]]
                        ]
                    ]
                ]
            ]
        }
        let mockResponse: [String: Any] = [
            "contents": [
                "twoColumnBrowseResultsRenderer": [
                    "tabs": [[
                        "tabRenderer": [
                            "content": [
                                "richGridRenderer": [
                                    "contents": [
                                        makeItem("video1_AAAAA"),
                                        makeItem("video2_BBBBB"),
                                        makeItem("video3_CCCCC"),
                                    ]
                                ]
                            ]
                        ]
                    ]]
                ]
            ]
        ]
        let api = InnerTubeAPI()
        let group = try await api.parseVideoGroupForTesting(mockResponse, title: "Home")
        #expect(group.videos.count == 3, "All three richItemRenderer items should be parsed")
        let ids = Set(group.videos.map { $0.id })
        #expect(ids.contains("video1_AAAAA"))
        #expect(ids.contains("video2_BBBBB"))
        #expect(ids.contains("video3_CCCCC"))
    }

    @Test("richItemRenderer wrapping reelItemRenderer is tagged isShort = true")
    func richItemRendererWithReelEndpointIsShort() async throws {
        let mockResponse: [String: Any] = [
            "contents": [
                "twoColumnBrowseResultsRenderer": [
                    "tabs": [[
                        "tabRenderer": [
                            "content": [
                                "richGridRenderer": [
                                    "contents": [
                                        [
                                            "richItemRenderer": [
                                                "content": [
                                                    "reelItemRenderer": [
                                                        "videoId": "reel1234567",
                                                        "headline": ["simpleText": "My Short"]
                                                    ]
                                                ]
                                            ]
                                        ]
                                    ]
                                ]
                            ]
                        ]
                    ]]
                ]
            ]
        ]
        let api = InnerTubeAPI()
        let group = try await api.parseVideoGroupForTesting(mockResponse, title: "Home")
        let video = try #require(group.videos.first)
        #expect(video.id == "reel1234567")
        #expect(video.isShort, "richItemRenderer wrapping reelItemRenderer must be isShort = true")
    }

    // MARK: - Continuation / nextPageToken

    @Test("continuationItemRenderer token is extracted as nextPageToken")
    func nextPageTokenExtracted() async throws {
        let mockResponse: [String: Any] = [
            "contents": [
                "twoColumnBrowseResultsRenderer": [
                    "tabs": [[
                        "tabRenderer": [
                            "content": [
                                "richGridRenderer": [
                                    "contents": [
                                        [
                                            "richItemRenderer": [
                                                "content": [
                                                    "videoRenderer": [
                                                        "videoId": "video1_AAAAA",
                                                        "title": ["runs": [["text": "Test"]]],
                                                        "ownerText": ["runs": [["text": "Ch"]]],
                                                        "thumbnail": ["thumbnails": [
                                                            ["url": "https://i.ytimg.com/vi/video1_AAAAA/hqdefault.jpg"]
                                                        ]],
                                                        "navigationEndpoint": [
                                                            "watchEndpoint": ["videoId": "video1_AAAAA"]
                                                        ]
                                                    ]
                                                ]
                                            ]
                                        ],
                                        [
                                            "continuationItemRenderer": [
                                                "continuationEndpoint": [
                                                    "continuationCommand": [
                                                        "token": "CONTINUATION_TOKEN_XYZ"
                                                    ]
                                                ]
                                            ]
                                        ]
                                    ]
                                ]
                            ]
                        ]
                    ]]
                ]
            ]
        ]
        let api = InnerTubeAPI()
        let group = try await api.parseVideoGroupForTesting(mockResponse, title: "Home")
        #expect(group.nextPageToken == "CONTINUATION_TOKEN_XYZ")
    }
}

// MARK: - Private helpers

private func makeTileResponse(
    videoId: String,
    useInnertubeWrapper: Bool,
    useNavigation: Bool
) -> [String: Any] {
    let onSelectCommand: [String: Any]
    if useInnertubeWrapper {
        onSelectCommand = ["innertubeCommand": ["watchEndpoint": ["videoId": videoId]]]
    } else if !useNavigation {
        onSelectCommand = ["watchEndpoint": ["videoId": videoId]]
    } else {
        onSelectCommand = [:]
    }

    var tileRenderer: [String: Any] = [
        "contentType": "TILE_CONTENT_TYPE_VIDEO",
        "onSelectCommand": onSelectCommand,
        "metadata": ["tileMetadataRenderer": ["title": ["simpleText": "Test Video"]]]
    ]
    if useNavigation {
        tileRenderer["navigationEndpoint"] = ["watchEndpoint": ["videoId": videoId]]
    }

    return [
        "contents": [
            "sectionListRenderer": [
                "contents": [
                    [
                        "itemSectionRenderer": [
                            "contents": [
                                ["tileRenderer": tileRenderer]
                            ]
                        ]
                    ]
                ]
            ]
        ]
    ]
}
