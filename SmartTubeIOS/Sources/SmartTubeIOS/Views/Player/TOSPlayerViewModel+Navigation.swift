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
        guard let next = relatedVideos.first else { return }
        tosLog.notice("[navigation] playNext — \(next.id, privacy: .public)")
        onPlayNext?(next)
    }

    /// Swipe-right handler — re-plays the previous video from history, if any.
    func playPrevious() {
        guard hasPrevious else { return }
        tosLog.notice("[navigation] playPrevious")
        onPlayPrevious?()
    }

    /// Cache-first fetch of related videos for swipe-left navigation.
    func fetchRelatedVideos() async {
        let videoId = videoId
        let cached = await VideoPreloadCache.shared.consume(videoId: videoId)
        if let cachedNextInfo = cached.nextInfo {
            let isStale = cached.staleFields.contains(.nextInfo)
            relatedVideos = cachedNextInfo.relatedVideos.filter { $0.id != videoId }
            tosLog.notice("[navigation] cache \(isStale ? "STALE" : "HIT") — \(self.relatedVideos.count) related video(s) for \(videoId)")
            guard isStale else { return }
            Task(priority: .background) { [weak self] in
                guard let self else { return }
                guard let fresh = try? await self.api.fetchNextInfo(videoId: videoId) else { return }
                await VideoPreloadCache.shared.store(nextInfo: fresh, for: videoId)
                await MainActor.run {
                    self.relatedVideos = fresh.relatedVideos.filter { $0.id != videoId }
                    tosLog.notice("[navigation] revalidated — \(self.relatedVideos.count) related video(s) for \(videoId)")
                }
            }
            return
        }

        guard let fresh = try? await api.fetchNextInfo(videoId: videoId) else {
            tosLog.notice("[navigation] fetchNextInfo failed for \(videoId)")
            return
        }
        await VideoPreloadCache.shared.store(nextInfo: fresh, for: videoId)
        relatedVideos = fresh.relatedVideos.filter { $0.id != videoId }
        tosLog.notice("[navigation] cache MISS — fetched \(self.relatedVideos.count) related video(s) for \(videoId)")
    }
}
#endif // !os(tvOS)
