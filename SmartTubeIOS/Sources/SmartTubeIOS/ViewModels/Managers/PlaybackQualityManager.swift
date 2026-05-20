import AVFoundation
import os
import SmartTubeIOSCore

private let playerLog = CrashlyticsLogger(category: "Player")

// MARK: - Player Abstraction

/// Abstracts `AVPlayer.replaceCurrentItem(with:)` so `PlaybackQualityManager` can be
/// tested without real network or playback. `AVPlayer` satisfies this via the extension
/// below; tests supply a `MockPlayer`.
protocol PlayerItemSwappable: AnyObject {
    var rate: Float { get set }
    func replaceCurrentItem(with item: AVPlayerItem?)
}
extension AVPlayer: PlayerItemSwappable {}

// MARK: - QualityContext

/// Read-only (and narrowly write-accessible) context that `PlaybackQualityManager` pulls
/// from its coordinator (`PlaybackViewModel`). ISP-1: separates state reads from callbacks.
@MainActor
protocol QualityContext: AnyObject {
    var playerInfo: PlayerInfo? { get }
    var settings: AppSettings { get }
    var currentVideo: Video? { get }
    var currentTime: TimeInterval { get }
    var toastMessage: String? { get set }
}

// MARK: - QualityEventHandler

/// Callbacks fired by `PlaybackQualityManager` when a player-item state change requires
/// coordinator-level action (seek, audio-track load, error recovery).
/// ISP-1: separates lifecycle callbacks from the context reads above.
@MainActor
protocol QualityEventHandler: AnyObject {
    /// Called when a quality-switch `AVPlayerItem` becomes `.readyToPlay`.
    /// The coordinator must seek to `seekTo` (if > 0), mark `isPlaying`, and load audio tracks.
    func qualityItemDidBecomeReady(_ item: AVPlayerItem, seekTo: TimeInterval)
    /// Called when a quality-switch `AVPlayerItem` enters `.failed` with the full error context.
    /// The coordinator uses `qualityRecoveryAction(for:quality:hasAppliedH264Cap:)` to
    /// dispatch the appropriate recovery path.
    func qualityItemDidFail(
        error: Error?,
        quality: AppSettings.VideoQuality,
        hasAppliedH264Cap: Bool  // snapshot: avoid race with qualityManager.hasAppliedH264Cap
    ) async
    /// Called when quality needs to change for a DASH/MP4-only video (no HLS URL available).
    /// The coordinator must rebuild the `AVMutableComposition` from `videoURL` + `audioURL`
    /// and seek to `seekTo` once `.readyToPlay` fires.
    func qualitySelectDASHFormat(videoURL: URL, audioURL: URL, seekTo: TimeInterval) async
    /// Written by `reloadHLSItem` around `player.replaceCurrentItem` to suppress
    /// rate-observer false positives during the item swap.
    var isSwappingItem: Bool { get set }
}

/// Combined alias used by `PlaybackQualityManager.delegate`.
typealias QualityDelegate = QualityContext & QualityEventHandler

// MARK: - PlaybackQualityManager

/// Owns `selectedFormat`, `availableFormats`, `hlsVariantURLs`, `qualityTask`, and
/// `hasAppliedH264Cap`. Logic migrated from PlaybackViewModel+Quality.swift.
@MainActor
@Observable
final class PlaybackQualityManager {

    // MARK: - State

    var selectedFormat: VideoFormat? = nil
    var availableFormats: [VideoFormat] = []
    var hlsVariantURLs: [Int: URL] = [:]
    var hasAppliedH264Cap: Bool = false
    @ObservationIgnored var qualityTask: Task<Void, Never>? = nil
    @ObservationIgnored private var itemObserverTask: Task<Void, Never>? = nil

    // MARK: - Cross-load HLS manifest cache
    //
    // Delegated to HLSManifestCache.shared (SmartTubeIOSCore). Survives reset() so
    // revisited videos skip the manifest fetch. See HLSManifestCache for TTL / capacity.

    static func cachedHLSVariants(for videoId: String) -> [Int: URL]? {
        HLSManifestCache.shared.variants(for: videoId)
    }

    static func cacheHLSVariants(_ variants: [Int: URL], for videoId: String) {
        HLSManifestCache.shared.store(variants, for: videoId)
    }

    // MARK: - Dependencies

    @ObservationIgnored weak var delegate: (any QualityDelegate)?
    let player: any PlayerItemSwappable
    @ObservationIgnored let session: URLSession

    // MARK: - Init

    init(player: any PlayerItemSwappable, session: URLSession = .shared) {
        self.player = player
        self.session = session
    }

    // MARK: - Interface

    func reset() {
        selectedFormat = nil
        availableFormats = []
        hlsVariantURLs = [:]
        hasAppliedH264Cap = false
        qualityTask?.cancel()
        qualityTask = nil
        itemObserverTask?.cancel()
        itemObserverTask = nil
    }

    func cancel() {
        qualityTask?.cancel()
        qualityTask = nil
        hasAppliedH264Cap = false
        itemObserverTask?.cancel()
        itemObserverTask = nil
    }

    /// Switch to a specific quality. Pass `.auto` to return to Auto (no resolution cap).
    func selectFormat(_ format: VideoFormat?) {
        let previousLabel = selectedFormat.map { "\($0.height)p" } ?? "Auto"
        let newLabel = format.map { "\($0.height)p" } ?? "Auto"
        playerLog.notice("[quality] selectFormat: \(previousLabel) → \(newLabel)")
        selectedFormat = format
        delegate?.toastMessage = format.map { "\($0.height)p" } ?? "Auto"
        qualityTask?.cancel()
        qualityTask = nil
        guard let delegate else {
            playerLog.error("[quality] selectFormat: delegate is nil — quality reload skipped")
            return
        }
        let savedTime = delegate.currentTime
        let quality: AppSettings.VideoQuality
        if let fmt = format {
            if let q = AppSettings.VideoQuality.from(height: fmt.height) {
                quality = q
            } else {
                playerLog.error("selectFormat: non-standard height \(fmt.height)p — no matching VideoQuality; falling back to .auto")
                assertionFailure("selectFormat received format with non-standard height \(fmt.height) not in VideoQuality enum")
                quality = .auto
            }
        } else {
            quality = .auto
        }
        qualityTask = Task { [weak self] in
            guard let self else { return }
            if self.delegate?.playerInfo?.hlsURL != nil {
                await self.reloadHLSItem(seekTo: savedTime, quality: quality)
            } else {
                await self.reloadDASHItem(seekTo: savedTime, format: format)
            }
        }
    }

    /// Rebuilds the HLS player item from the stored `playerInfo`.
    func reloadHLSItem(seekTo time: TimeInterval, quality: AppSettings.VideoQuality) async {
        guard let hlsURL = delegate?.playerInfo?.hlsURL else {
            playerLog.error("[quality] reloadHLSItem: playerInfo.hlsURL is nil — video is DASH/MP4 only, HLS quality switch not possible")
            return
        }
        guard !Task.isCancelled else { return }
        let uaOpts: [String: Any] = [
            "AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": InnerTubeClients.iOS.userAgent]
        ]
        // Always use the master HLS URL so EXT-X-MEDIA alternate audio renditions are
        // preserved after a quality switch. YouTube variant playlists at 480p+ are
        // video-only and have no EXT-X-MEDIA groups → silent audio when used directly.
        // Quality preference is applied as ABR hints (preferredMaximumResolution +
        // preferredPeakBitRate), which strongly guide AVPlayer without replacing the item.
        itemObserverTask?.cancel()
        let asset = AVURLAsset(url: hlsURL, options: uaOpts)
        let item = AVPlayerItem(asset: asset)
        item.audioTimePitchAlgorithm = .spectral
        if let cap = quality.maxHeight {
            let h = CGFloat(cap)
            let peakBR = peakBitRate(for: cap)
            item.preferredMaximumResolution = CGSize(width: h * 4, height: h)
            item.preferredPeakBitRate = peakBR
            playerLog.notice("Quality → \(cap)p via HLS master + ABR hints (maxRes=\(Int(h * 4))x\(cap) peakBR=\(Int(peakBR / 1_000_000))Mbps)")
        } else {
            playerLog.notice("Quality → Auto via HLS master (hints cleared)")
        }
        itemObserverTask = Task { [weak self] in
            for await status in item.statusStream {
                guard let self, !Task.isCancelled else { return }
                switch status {
                case .readyToPlay:
                    let size = item.presentationSize
                    playerLog.notice("✅ Quality-switch readyToPlay — presentationSize=\(Int(size.width))x\(Int(size.height))")
                    self.player.rate = Float(self.delegate?.settings.playbackSpeed ?? 1)
                    await self.delegate?.qualityItemDidBecomeReady(item, seekTo: time)
                case .failed:
                    let err = item.error.map { "\($0)" } ?? "nil"
                    playerLog.error("❌ Quality-switch AVPlayerItem failed: \(err)")
                    await self.delegate?.qualityItemDidFail(
                        error: item.error,
                        quality: quality,
                        hasAppliedH264Cap: self.hasAppliedH264Cap
                    )
                case .unknown:
                    break
                @unknown default:
                    break
                }
            }
        }
        delegate?.isSwappingItem = true
        player.replaceCurrentItem(with: item)
        delegate?.isSwappingItem = false
    }

    /// Switches quality for a DASH/MP4-only video (no HLS URL) by rebuilding the composition
    /// from the selected format's video URL and the best available adaptive audio URL.
    private func reloadDASHItem(seekTo time: TimeInterval, format: VideoFormat?) async {
        guard let info = delegate?.playerInfo else {
            playerLog.error("[quality] reloadDASHItem: playerInfo is nil — quality reload skipped")
            return
        }
        guard !Task.isCancelled else { return }

        let label = format.map { "\($0.height)p" } ?? "Auto"

        // For explicit quality: use the format's direct URL.
        // For Auto: fall back to the best available video-only MP4 (mirrors the initial load path).
        let videoURL: URL?
        if let fmt = format {
            videoURL = fmt.url
        } else {
            videoURL = PlaybackQualityManager.selectBestVideoFormat(
                from: info.formats, preferredMaxHeight: nil
            )?.url
        }

        guard let videoURL else {
            playerLog.error("[quality] reloadDASHItem: no video URL for quality=\(label) — cannot switch")
            return
        }
        guard let audioURL = info.bestAdaptiveAudioURL else {
            playerLog.error("[quality] reloadDASHItem: no adaptive audio URL — cannot rebuild composition")
            return
        }

        playerLog.notice("[quality] DASH switch → \(label)")
        await delegate?.qualitySelectDASHFormat(videoURL: videoURL, audioURL: audioURL, seekTo: time)
    }

    /// Sets `selectedFormat` to the best available format for the current quality preference,
    /// without returning a URL. Call this when the master HLS URL is already being used and
    /// only the `selectedFormat` state needs to reflect the preference (e.g. fallback paths
    /// that keep the master URL for EXT-X-MEDIA audio rendition reasons).
    func setSelectedFormatForCurrentPreference() {
        guard let settings = delegate?.settings,
              settings.preferredQuality != .auto,
              let maxH = settings.preferredQuality.maxHeight else {
            selectedFormat = nil
            return
        }
        selectedFormat = availableFormats.first { $0.height <= maxH }
    }

    /// Fetches the HLS master manifest and returns a map of stream height → variant playlist URL.
    func fetchHLSVariantURLs(url: URL) async -> [Int: URL] {
        var request = URLRequest(url: url)
        request.setValue(InnerTubeClients.iOS.userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 8
        guard let (data, _) = try? await self.session.data(for: request),
              let text = String(data: data, encoding: .utf8) else {
            playerLog.notice("HLS manifest fetch failed — showing all quality options")
            return [:]
        }
        let variants = parseHLSMasterManifest(text, baseURL: url.deletingLastPathComponent())
        playerLog.notice("HLS manifest parsed: heights=\(variants.keys.sorted().reversed())")
        return variants
    }

    static func deduplicatedVideoFormats(_ formats: [VideoFormat]) -> [VideoFormat] {
        let candidates = formats.filter { $0.url != nil && $0.height > 0 }
        var seen = Set<String>()
        var result: [VideoFormat] = []
        // Sort: height desc → fps desc → mp4 first → bitrate desc.
        // Codec preference (H.264 first) is intentionally absent here — this list feeds the
        // quality picker which should show all height options, not pre-filter by codec.
        // (Compare: selectBestVideoFormat applies H.264 preference for a single best-pick.)
        for fmt in candidates.sorted(by: {
            if $0.height != $1.height { return $0.height > $1.height }
            if $0.fps != $1.fps { return $0.fps > $1.fps }
            let lhsMp4 = $0.mimeType.hasPrefix("video/mp4")
            let rhsMp4 = $1.mimeType.hasPrefix("video/mp4")
            if lhsMp4 != rhsMp4 { return lhsMp4 }
            return ($0.bitrate ?? 0) > ($1.bitrate ?? 0)
        }) {
            let key = "\(fmt.height):\(fmt.fps)"
            if !seen.contains(key) {
                seen.insert(key)
                result.append(fmt)
            }
        }
        return result
    }

    /// Returns the best video-only MP4 format for adaptive composition.
    ///
    /// Shared by `qualityCapVideoURL(from:)` in `PlaybackViewModel+Fallback` and any other
    /// caller that needs to pick the best adaptive MP4 stream with an optional resolution cap.
    ///
    /// - Parameters:
    ///   - formats: The full candidate list (all mimeTypes accepted; non-mp4 are filtered out).
    ///   - preferredMaxHeight: Height cap in pixels, or `nil` for Auto (best available).
    ///   - preferH264: When `true` (default), sorts H.264 (`avc1`) variants before AV1/other
    ///     codecs to avoid the Android-client `pot` token requirement that causes HTTP 403.
    /// - Returns: The best matching `VideoFormat`, or `nil` if no suitable format is found.
    static func selectBestVideoFormat(
        from formats: [VideoFormat],
        preferredMaxHeight: Int?,
        preferH264: Bool = true
    ) -> VideoFormat? {
        let videoOnly = formats.filter {
            $0.mimeType.hasPrefix("video/mp4") && !$0.mimeType.contains(", ") && $0.url != nil
        }
        func sortKey(_ lhs: VideoFormat, _ rhs: VideoFormat) -> Bool {
            if preferH264 {
                let lH264 = lhs.mimeType.contains("avc1")
                let rH264 = rhs.mimeType.contains("avc1")
                if lH264 != rH264 { return lH264 }
            }
            if lhs.height != rhs.height { return lhs.height > rhs.height }
            return (lhs.bitrate ?? 0) > (rhs.bitrate ?? 0)
        }
        guard let maxH = preferredMaxHeight else {
            return videoOnly.sorted(by: sortKey).first
        }
        let capped = videoOnly.filter { $0.height <= maxH }
        return capped.sorted(by: sortKey).first
            ?? videoOnly.sorted(by: sortKey).first
    }

    static let bitRateCaps: [Int: Double] = [
        2160: 45_000_000,
        1440: 20_000_000,
        1080: 15_000_000,
         720:  8_000_000,
         480:  4_000_000,
    ]

    func peakBitRate(for height: Int) -> Double {
        if let exact = Self.bitRateCaps[height] { return exact }
        let sortedKeys = Self.bitRateCaps.keys.sorted()
        let lower = sortedKeys.last(where: { $0 <= height }) ?? sortedKeys.first ?? 480
        return Self.bitRateCaps[lower] ?? 4_000_000
    }

    func reloadHLSItemH264Capped(seekTo time: TimeInterval) async {
        guard let hlsURL = delegate?.playerInfo?.hlsURL else { return }
        guard !Task.isCancelled else { return }
        let uaOpts: [String: Any] = [
            "AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": InnerTubeClients.iOS.userAgent]
        ]
        let asset = AVURLAsset(url: hlsURL, options: uaOpts)
        let item = AVPlayerItem(asset: asset)
        item.audioTimePitchAlgorithm = .spectral
        item.preferredMaximumResolution = CGSize(width: 1920, height: 1080)
        item.preferredPeakBitRate = peakBitRate(for: 1080)
        itemObserverTask?.cancel()
        itemObserverTask = Task { [weak self] in
            for await status in item.statusStream {
                guard let self, !Task.isCancelled else { return }
                switch status {
                case .readyToPlay:
                    self.player.rate = Float(self.delegate?.settings.playbackSpeed ?? 1)
                    await self.delegate?.qualityItemDidBecomeReady(item, seekTo: time)
                    playerLog.notice("✅ H.264-capped AVPlayerItem readyToPlay")
                case .failed:
                    let err = item.error.map { "\($0)" } ?? "nil"
                    playerLog.error("❌ H.264-capped AVPlayerItem also failed: \(err)")
                    await self.delegate?.qualityItemDidFail(
                        error: item.error,
                        quality: .auto,
                        hasAppliedH264Cap: self.hasAppliedH264Cap
                    )
                case .unknown:
                    break
                @unknown default:
                    break
                }
            }
        }
        delegate?.isSwappingItem = true
        player.replaceCurrentItem(with: item)
        delegate?.isSwappingItem = false
    }
}
