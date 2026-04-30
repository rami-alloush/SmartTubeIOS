import Foundation
import Observation
import os
import SmartTubeIOSCore

private let playlistLog = CrashlyticsLogger(category: "Playlist")

// MARK: - PlaylistViewModel
//
// Fetches and paginates the videos inside a single playlist.
// Mirrors the Android `PlaylistPresenter`.

@MainActor
@Observable
public final class PlaylistViewModel {
    public private(set) var videos: [Video] = []
    public private(set) var isLoading = false
    public var error: Error?

    private var playlistId: String = ""
    private var nextPageToken: String?
    private var fetchTask: Task<Void, Never>?
    private let api: InnerTubeAPI

    public init(api: InnerTubeAPI = InnerTubeAPI()) {
        self.api = api
    }

    public func load(playlistId: String, refresh: Bool = false) {
        // If the same playlist is already loaded and no refresh was requested,
        // do nothing — this preserves scroll position when navigating back.
        if !refresh && self.playlistId == playlistId && !videos.isEmpty {
            return
        }
        if refresh || self.playlistId != playlistId {
            self.playlistId = playlistId
            videos = []
            nextPageToken = nil
        }
        fetchTask?.cancel()
        fetchTask = Task { await fetch() }
    }

    public func loadMoreIfNeeded(lastVideo: Video) {
        guard let last = videos.last, last.id == lastVideo.id,
              nextPageToken != nil, !isLoading else { return }
        fetchTask = Task { await fetch() }
    }

    private func fetch() async {
        isLoading = true
        defer { isLoading = false }
        playlistLog.notice("fetchPlaylistVideos id=\(self.playlistId) page=\(self.nextPageToken ?? "first")")
        do {
            let group = try await api.fetchPlaylistVideos(playlistId: self.playlistId, continuationToken: self.nextPageToken)
            if !Task.isCancelled {
                // Tag each video with the playlistId so the player can navigate next/prev.
                let tagged = group.videos.map { v -> Video in
                    var copy = v
                    copy.playlistId = playlistId
                    return copy
                }
                videos.append(contentsOf: tagged)
                nextPageToken = group.nextPageToken
                playlistLog.notice("fetchPlaylistVideos → \(tagged.count) videos (total \(self.videos.count))")
            }
        } catch {
            if !Task.isCancelled {
                playlistLog.error("fetchPlaylistVideos error: \(String(describing: error))")
                self.error = error
            }
        }
    }
}
