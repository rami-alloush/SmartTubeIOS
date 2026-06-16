#if !os(tvOS)
import Foundation
import os
import SmartTubeIOSCore

private let tosLog = Logger(subsystem: "com.void.smarttube.app", category: "TOSPlayer")

// MARK: - Navigation (swipe left/right)
//
// Backs TOSSwipeNavigationOverlay. `relatedVideos` is populated from the "ready"
// bridge message (see TOSPlayerViewModel+WebBridge.swift) using the same
// cache-first/stale-revalidate/full-miss pattern as fetchSponsorSegments()
// (TOSPlayerViewModel+SponsorBlock.swift).

extension TOSPlayerViewModel {
    /// Whether a "next" video is available to swipe to.
    var hasNext: Bool { !relatedVideos.isEmpty }

    /// Called by `TOSPlayerStateStore.play(video:api:)` after creating this vm.
    func setNavigationContext(hasPrevious: Bool) {
        self.hasPrevious = hasPrevious
    }

    /// Swipe-left handler — plays the first related video, if any.
    func playNext() {
        tosLog.notice("[navigation] playNext called — relatedVideos=\(self.relatedVideos.count) hasNext=\(self.hasNext)")
        guard let next = relatedVideos.first else { return }
        tosLog.notice("[navigation] playNext — \(next.id, privacy: .public)")
        onPlayNext?(next)
    }

    /// Swipe-right handler — re-plays the previous video from history, if any.
    func playPrevious() {
        tosLog.notice("[navigation] playPrevious called — hasPrevious=\(self.hasPrevious)")
        guard hasPrevious else { return }
        tosLog.notice("[navigation] playPrevious — navigating back")
        onPlayPrevious?()
    }

    /// Cache-first fetch of related videos for swipe-left navigation.
    /// Mirrors PlaybackViewModel+Loading.swift's related-video fetch with the
    /// same search fallback when fetchNextInfo returns 0 results.
    func fetchRelatedVideos() async {
        let videoId = videoId
        let cached = await VideoPreloadCache.shared.consume(videoId: videoId)
        if let cachedNextInfo = cached.nextInfo {
            let isStale = cached.staleFields.contains(.nextInfo)
            relatedVideos = cachedNextInfo.relatedVideos.filter { $0.id != videoId }
            tosLog.notice("[navigation] cache \(isStale ? "STALE" : "HIT") — \(self.relatedVideos.count) related video(s) for \(videoId)")
            if relatedVideos.isEmpty { await searchFallback() }
            guard isStale else { return }
            Task(priority: .background) { [weak self] in
                guard let self else { return }
                guard let fresh = try? await self.api.fetchNextInfo(videoId: videoId) else { return }
                await VideoPreloadCache.shared.store(nextInfo: fresh, for: videoId)
                await MainActor.run {
                    let updated = fresh.relatedVideos.filter { $0.id != videoId }
                    tosLog.notice("[navigation] revalidated — \(updated.count) related video(s) for \(videoId)")
                    if !updated.isEmpty { self.relatedVideos = updated }
                }
            }
            return
        }

        guard let fresh = try? await api.fetchNextInfo(videoId: videoId) else {
            tosLog.notice("[navigation] fetchNextInfo failed for \(videoId)")
            await searchFallback()
            return
        }
        await VideoPreloadCache.shared.store(nextInfo: fresh, for: videoId)
        relatedVideos = fresh.relatedVideos.filter { $0.id != videoId }
        tosLog.notice("[navigation] cache MISS — fetched \(self.relatedVideos.count) related video(s) for \(videoId)")
        if relatedVideos.isEmpty { await searchFallback() }
    }

    /// Search-based fallback when fetchNextInfo returns 0 related videos —
    /// mirrors PlaybackViewModel+Loading.swift:1267-1273.
    private func searchFallback() async {
        guard !videoTitle.isEmpty else { return }
        tosLog.notice("[navigation] search fallback — query='\(self.videoTitle, privacy: .public)'")
        guard let result = try? await api.search(query: videoTitle) else { return }
        let videos = result.videos.filter { $0.id != videoId }
        guard !videos.isEmpty else { return }
        relatedVideos = Array(videos.prefix(25))
        tosLog.notice("[navigation] search fallback — \(self.relatedVideos.count) video(s)")
    }
}
#endif // !os(tvOS)
