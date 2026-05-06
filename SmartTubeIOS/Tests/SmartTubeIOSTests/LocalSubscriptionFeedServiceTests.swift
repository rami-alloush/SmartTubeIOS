import Foundation
import Testing
@testable import SmartTubeIOSCore

// MARK: - LocalSubscriptionFeedServiceTests

@Suite("Local Subscription Feed Service")
@MainActor
struct LocalSubscriptionFeedServiceTests {

    // MARK: - Helpers

    private func makeStore(suiteName: String? = nil) -> LocalSubscriptionStore {
        LocalSubscriptionStore(suiteName: suiteName ?? "test-feedsvc-\(UUID().uuidString)")
    }

    private func makeCache() -> LocalSubscriptionFeedCache {
        LocalSubscriptionFeedCache()
    }

    private func makeChannel(id: String, title: String = "Channel") -> LocalChannel {
        LocalChannel(id: id, title: title)
    }

    // MARK: - Empty store

    @Test("fetchFeed returns empty array when no channels are followed")
    func fetchFeedEmptyStore() async {
        let store = makeStore()
        let cache = makeCache()
        let api = MockInnerTubeAPI()
        let service = LocalSubscriptionFeedService()

        let videos = await service.fetchFeed(store: store, cache: cache, api: api)
        #expect(videos.isEmpty)
    }

    // MARK: - Cache hit

    @Test("fetchFeed returns cached videos without calling InnerTube API")
    func fetchFeedCacheHit() async {
        let store = makeStore()
        let cache = makeCache()
        let api = MockInnerTubeAPI()

        let channel = makeChannel(id: "UCcache1")
        await store.follow(channel)

        // Pre-populate cache
        let cachedVideo = Video(id: "vid-cached", title: "Cached Video", channelTitle: "Channel")
        await cache.store(videos: [cachedVideo], for: "UCcache1")

        let service = LocalSubscriptionFeedService()
        let videos = await service.fetchFeed(store: store, cache: cache, api: api)

        // Should return the cached video
        #expect(videos.map(\.id).contains("vid-cached"))
        // InnerTube should NOT have been called for channel videos
        let channelVideoCalls = api.calls.filter { $0.method == "fetchChannelVideos" }
        #expect(channelVideoCalls.isEmpty)
    }

    // MARK: - InnerTube fallback (when RSS would fail, InnerTube is tried)

    @Test("fetchFeed falls back to InnerTube when RSS returns no data")
    func fetchFeedInnerTubeFallback() async {
        let store = makeStore()
        let cache = makeCache()
        let api = MockInnerTubeAPI()

        // Configure mock to return a video for channel videos
        let mockVideo = Video(id: "vid-innertube", title: "InnerTube Video", channelTitle: "Channel")
        api.channelVideosResult = VideoGroup(title: "ChVideos", videos: [mockVideo])

        let channel = makeChannel(id: "UCfallback")
        await store.follow(channel)

        // Use a service with a session that will fail all RSS requests
        let session = URLSession(configuration: {
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [AlwaysFailURLProtocol.self]
            return config
        }())
        let service = LocalSubscriptionFeedService(session: session)
        let videos = await service.fetchFeed(store: store, cache: cache, api: api)

        // InnerTube fallback should have provided the video
        #expect(videos.map(\.id).contains("vid-innertube"))
    }

    // MARK: - Deduplication

    @Test("fetchFeed deduplicates videos that appear in multiple channels")
    func fetchFeedDeduplicates() async {
        let store = makeStore()
        let cache = makeCache()
        let api = MockInnerTubeAPI()

        // Two channels, both with the same video in cache
        await store.follow(makeChannel(id: "UC1"))
        await store.follow(makeChannel(id: "UC2"))

        let sharedVideo = Video(id: "vid-shared", title: "Shared", channelTitle: "A")
        await cache.store(videos: [sharedVideo], for: "UC1")
        await cache.store(videos: [sharedVideo], for: "UC2")

        let service = LocalSubscriptionFeedService()
        let videos = await service.fetchFeed(store: store, cache: cache, api: api)

        let sharedCount = videos.filter { $0.id == "vid-shared" }.count
        #expect(sharedCount == 1)
    }

    // MARK: - Sort order

    @Test("fetchFeed returns videos sorted newest-first")
    func fetchFeedSortedNewestFirst() async {
        let store = makeStore()
        let cache = makeCache()
        let api = MockInnerTubeAPI()

        await store.follow(makeChannel(id: "UCsort"))

        let older = Video(id: "vid-old", title: "Old", channelTitle: "C",
                          publishedAt: Date(timeIntervalSince1970: 1_000_000))
        let newer = Video(id: "vid-new", title: "New", channelTitle: "C",
                          publishedAt: Date(timeIntervalSince1970: 2_000_000))
        await cache.store(videos: [older, newer], for: "UCsort")

        let service = LocalSubscriptionFeedService()
        let videos = await service.fetchFeed(store: store, cache: cache, api: api)

        #expect(videos.first?.id == "vid-new")
        #expect(videos.last?.id == "vid-old")
    }
}

// MARK: - AlwaysFailURLProtocol

/// URLProtocol subclass that fails every request immediately.
/// Used to force the InnerTube fallback path in feed service tests.
private final class AlwaysFailURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}
