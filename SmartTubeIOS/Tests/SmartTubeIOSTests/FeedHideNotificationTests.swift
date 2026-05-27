import Foundation
import Testing
@testable import SmartTubeIOSCore

// MARK: - FeedHideNotificationTests
//
// Verifies that SearchViewModel, ChannelViewModel, and PlaylistViewModel
// all remove the relevant videos when .hideVideoFromFeed and
// .hideChannelFromFeed notifications fire (task #216).

private func makeVideo(id: String, channelId: String = "ch_default") -> Video {
    Video(id: id, title: "Video \(id)", channelTitle: "Channel", channelId: channelId)
}

private func postHideVideo(id: String) {
    NotificationCenter.default.post(
        name: .hideVideoFromFeed,
        object: nil,
        userInfo: ["videoId": id]
    )
}

private func postHideChannel(id: String) {
    NotificationCenter.default.post(
        name: .hideChannelFromFeed,
        object: nil,
        userInfo: ["channelId": id]
    )
}

// MARK: - SearchViewModel

@Suite("SearchViewModel feed hide notifications")
@MainActor
struct SearchViewModelFeedHideTests {

    private func makeVM(videos: [Video]) -> SearchViewModel {
        let mock = MockInnerTubeAPI()
        mock.searchResult = VideoGroup(title: "Results", videos: videos)
        return SearchViewModel(
            api: mock,
            historyStore: SearchHistoryStore(suiteName: "test-\(UUID().uuidString)")
        )
    }

    private func loadedVM(videos: [Video]) async throws -> SearchViewModel {
        let vm = makeVM(videos: videos)
        vm.query = "test query"
        vm.search()
        let deadline = Date().addingTimeInterval(2)
        while vm.results.isEmpty && Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        return vm
    }

    @Test("hideVideoFromFeed removes matching video from search results")
    func hideVideoRemovesFromResults() async throws {
        let vm = try await loadedVM(videos: [
            makeVideo(id: "vid_aaa"),
            makeVideo(id: "vid_bbb"),
        ])
        #expect(vm.results.count == 2)

        postHideVideo(id: "vid_aaa")
        try await Task.sleep(for: .milliseconds(100))

        #expect(vm.results.count == 1)
        #expect(vm.results.first?.id == "vid_bbb")
    }

    @Test("hideVideoFromFeed with unknown id does not change results")
    func hideVideoUnknownIdNoChange() async throws {
        let vm = try await loadedVM(videos: [makeVideo(id: "vid_aaa")])

        postHideVideo(id: "vid_zzz")
        try await Task.sleep(for: .milliseconds(100))

        #expect(vm.results.count == 1)
    }

    @Test("hideChannelFromFeed removes all videos from that channel")
    func hideChannelRemovesAllFromChannel() async throws {
        let vm = try await loadedVM(videos: [
            makeVideo(id: "vid_aaa", channelId: "ch_1"),
            makeVideo(id: "vid_bbb", channelId: "ch_1"),
            makeVideo(id: "vid_ccc", channelId: "ch_2"),
        ])
        #expect(vm.results.count == 3)

        postHideChannel(id: "ch_1")
        try await Task.sleep(for: .milliseconds(100))

        #expect(vm.results.count == 1)
        #expect(vm.results.first?.id == "vid_ccc")
    }

    @Test("hideChannelFromFeed with unknown channelId does not change results")
    func hideChannelUnknownIdNoChange() async throws {
        let vm = try await loadedVM(videos: [makeVideo(id: "vid_aaa", channelId: "ch_1")])

        postHideChannel(id: "ch_zzz")
        try await Task.sleep(for: .milliseconds(100))

        #expect(vm.results.count == 1)
    }
}

// MARK: - ChannelViewModel

@Suite("ChannelViewModel feed hide notifications")
@MainActor
struct ChannelViewModelFeedHideTests {

    private func loadedVM(videos: [Video]) async throws -> ChannelViewModel {
        let mock = MockInnerTubeAPI()
        mock.channelResult = (
            Channel(id: "ch_root", title: "Root Channel"),
            VideoGroup(title: "Videos", videos: videos)
        )
        let vm = ChannelViewModel(api: mock)
        vm.load(channelId: "ch_root")
        let deadline = Date().addingTimeInterval(2)
        while vm.videos.isEmpty && Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        return vm
    }

    @Test("hideVideoFromFeed removes matching video from channel videos")
    func hideVideoRemovesFromChannelVideos() async throws {
        let vm = try await loadedVM(videos: [
            makeVideo(id: "vid_aaa"),
            makeVideo(id: "vid_bbb"),
        ])
        #expect(vm.videos.count == 2)

        postHideVideo(id: "vid_aaa")
        try await Task.sleep(for: .milliseconds(100))

        #expect(vm.videos.count == 1)
        #expect(vm.videos.first?.id == "vid_bbb")
    }

    @Test("hideChannelFromFeed removes all videos matching channelId")
    func hideChannelRemovesAllFromChannelVideos() async throws {
        let vm = try await loadedVM(videos: [
            makeVideo(id: "vid_aaa", channelId: "ch_1"),
            makeVideo(id: "vid_bbb", channelId: "ch_2"),
        ])
        #expect(vm.videos.count == 2)

        postHideChannel(id: "ch_1")
        try await Task.sleep(for: .milliseconds(100))

        #expect(vm.videos.count == 1)
        #expect(vm.videos.first?.id == "vid_bbb")
    }
}

// MARK: - PlaylistViewModel

private struct EmptyQueueLoader: QueuedPlaylistLoader {
    func loadQueuedVideos(for playlistId: String) async -> [Video]? { nil }
}

@Suite("PlaylistViewModel feed hide notifications")
@MainActor
struct PlaylistViewModelFeedHideTests {

    private func loadedVM(videos: [Video]) async throws -> PlaylistViewModel {
        let mock = MockInnerTubeAPI()
        mock.playlistVideosResult = VideoGroup(title: "Playlist", videos: videos)
        let vm = PlaylistViewModel(api: mock, queueLoader: EmptyQueueLoader())
        vm.load(playlistId: "pl_test_123")
        let deadline = Date().addingTimeInterval(2)
        while vm.videos.isEmpty && Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        return vm
    }

    @Test("hideVideoFromFeed removes matching video from playlist videos")
    func hideVideoRemovesFromPlaylist() async throws {
        let vm = try await loadedVM(videos: [
            makeVideo(id: "vid_aaa"),
            makeVideo(id: "vid_bbb"),
        ])
        #expect(vm.videos.count == 2)

        postHideVideo(id: "vid_aaa")
        try await Task.sleep(for: .milliseconds(100))

        #expect(vm.videos.count == 1)
        #expect(vm.videos.first?.id == "vid_bbb")
    }

    @Test("hideChannelFromFeed removes all videos from that channel in playlist")
    func hideChannelRemovesFromPlaylist() async throws {
        let vm = try await loadedVM(videos: [
            makeVideo(id: "vid_aaa", channelId: "ch_1"),
            makeVideo(id: "vid_bbb", channelId: "ch_1"),
            makeVideo(id: "vid_ccc", channelId: "ch_2"),
        ])
        #expect(vm.videos.count == 3)

        postHideChannel(id: "ch_1")
        try await Task.sleep(for: .milliseconds(100))

        #expect(vm.videos.count == 1)
        #expect(vm.videos.first?.id == "vid_ccc")
    }
}

// MARK: - AppSettings blockedChannels persistence

@Suite("AppSettings blockedChannels")
struct AppSettingsBlockedChannelsTests {

    @Test("blockedChannels defaults to empty")
    func defaultsToEmpty() {
        let settings = AppSettings()
        #expect(settings.blockedChannels.isEmpty)
    }

    @Test("blockedChannels encodes and decodes correctly")
    func encodeDecode() throws {
        var settings = AppSettings()
        settings.blockedChannels = ["ch_1": "Cool Channel", "ch_2": "Another Channel"]

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)

        #expect(decoded.blockedChannels["ch_1"] == "Cool Channel")
        #expect(decoded.blockedChannels["ch_2"] == "Another Channel")
        #expect(decoded.blockedChannels.count == 2)
    }

    @Test("blockedChannels missing from JSON decodes to empty (migration safe)")
    func missingKeyDecodesToEmpty() throws {
        let json = Data("{}".utf8)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: json)
        #expect(decoded.blockedChannels.isEmpty)
    }
}
