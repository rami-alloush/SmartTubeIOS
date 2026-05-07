import Foundation

// MARK: - LikeStatus

/// The user's current like state for a video.
public enum LikeStatus: Sendable {
    case like
    case dislike
    case none
}

// MARK: - NextInfo

/// Combined result from the `/next` InnerTube endpoint.
public struct NextInfo: Sendable {
    public let relatedVideos: [Video]
    public let likeStatus: LikeStatus
    public let chapters: [Chapter]
}

// MARK: - Comment

/// A single top-level YouTube comment returned by the `/next` continuation endpoint.
public struct Comment: Sendable, Identifiable {
    public let id: String
    public let author: String
    public let authorAvatarURL: URL?
    public let text: String
    public let likeCount: String
    public let publishedTime: String
    public let isLiked: Bool
}

// MARK: - EndCard

/// A YouTube end-screen card shown in the final seconds of a video.
/// Mirrors the `endscreen.endscreenRenderer.elements[].endscreenElementRenderer` shape.
public struct EndCard: Sendable, Identifiable {
    public enum Style: String, Sendable {
        case video = "VIDEO"
        case playlist = "PLAYLIST"
        case subscribe = "SUBSCRIBE"
        case channel = "CHANNEL"
        case link = "LINK"
        case unknown
    }

    public let id: String
    public let style: Style
    /// Target video ID — non-nil only for `.video` cards.
    public let videoId: String?
    public let title: String
    public let thumbnailURL: URL?
    /// Left edge position as a percentage (0–100) of the player width.
    public let left: Double
    /// Top edge position as a percentage (0–100) of the player height.
    public let top: Double
    /// Card width as a percentage (0–100) of the player width.
    public let width: Double
    /// Width-to-height aspect ratio (e.g. 1.778 for 16:9).
    public let aspectRatio: Double
    /// Timestamp (milliseconds from video start) when this card should appear.
    public let startMs: Int
    /// Timestamp (milliseconds from video start) when this card should disappear.
    public let endMs: Int
}

// MARK: - PlayerInfo

/// Tracking URLs returned by the YouTube `/player` endpoint.
/// Pinging these records the video in the user's official YouTube watch history.
/// Mirrors Android's `VideoStatsPlaybackUrl` / `VideoStatsWatchtimeUrl` in MediaServiceCore.
public struct PlaybackTrackingURLs: Sendable {
    /// Fire once (GET) when playback begins — records the view in watch history.
    public let playbackURL: URL
    /// Fire periodically during playback and on stop — records watched intervals.
    public let watchtimeURL: URL
}

public struct PlayerInfo: Sendable {
    public let video: Video
    public let formats: [VideoFormat]
    public let hlsURL: URL?
    public let dashURL: URL?
    public let captionTracks: [CaptionTrack]
    /// Tracking URLs for watch-history reporting; nil when unavailable (e.g. unauthenticated iOS client).
    public let trackingURLs: PlaybackTrackingURLs?
    /// End-screen cards embedded in the player response (populated for web-client fetches).
    /// Empty when the iOS client is used for primary streaming — a fallback web-client
    /// fetch is performed in PlaybackViewModel when this is empty.
    public let endCards: [EndCard]

    /// The best stream URL to hand to AVPlayer.
    /// Prefers HLS (works natively in AVPlayer on iOS, handles adaptive quality).
    /// Falls back to combined muxed mp4 for non-HLS responses.
    public var preferredStreamURL: URL? {
        // HLS is the most reliable for AVPlayer — adaptive, no header restrictions
        if let hls = hlsURL { return hls }
        // Muxed (combined video+audio) MP4 — identified by two codecs separated by ", "
        // e.g. `video/mp4; codecs="avc1.42001E, mp4a.40.2"` (itag=18).
        // Adaptive video-only streams also have video/mp4 but only one codec, so the
        // `", "` check correctly excludes them (they have no audio and can't be played).
        let muxed = formats.filter {
            $0.mimeType.hasPrefix("video/mp4") &&
            $0.mimeType.contains(", ") &&
            $0.url != nil
        }
        return muxed.sorted { ($0.bitrate ?? 0) > ($1.bitrate ?? 0) }.first?.url
    }

    /// A direct MP4 URL suitable for file download (muxed video+audio).
    /// Muxed formats list two codecs separated by ", " (e.g. "avc1.xxx, mp4a.xxx"),
    /// unlike adaptive streams which have a single codec.
    /// Returns nil if no muxed MP4 with a plain URL is available.
    public var bestMuxedDownloadURL: URL? {
        let muxed = formats.filter {
            $0.mimeType.hasPrefix("video/mp4") &&
            $0.mimeType.contains(", ") &&
            $0.url != nil
        }
        return muxed.sorted { ($0.bitrate ?? 0) > ($1.bitrate ?? 0) }.first?.url
    }

    /// Best adaptive video-only MP4 URL (single codec, no audio).
    /// Used together with bestAdaptiveAudioURL for the merge fallback.
    public var bestAdaptiveVideoURL: URL? {
        let videoOnly = formats.filter {
            $0.mimeType.hasPrefix("video/mp4") &&
            !$0.mimeType.contains(", ") &&
            $0.url != nil
        }
        return videoOnly.sorted { ($0.bitrate ?? 0) > ($1.bitrate ?? 0) }.first?.url
    }

    /// Best adaptive audio-only MP4 URL.
    /// Used together with bestAdaptiveVideoURL for the merge fallback.
    public var bestAdaptiveAudioURL: URL? {
        let audioOnly = formats.filter {
            $0.mimeType.hasPrefix("audio/mp4") &&
            $0.url != nil
        }
        return audioOnly.sorted { ($0.bitrate ?? 0) > ($1.bitrate ?? 0) }.first?.url
    }
}

// MARK: - APIError

public enum APIError: LocalizedError {
    case httpError(Int)
    case decodingError(String)
    case notAuthenticated
    case unavailable(String)
    case invalidURL(String)

    public var errorDescription: String? {
        switch self {
        case .httpError(let code):      return "HTTP error \(code)"
        case .decodingError(let msg):   return "Decoding error: \(msg)"
        case .notAuthenticated:          return "You are not signed in"
        case .unavailable(let reason):   return reason
        case .invalidURL(let endpoint):  return "Could not build URL for endpoint: \(endpoint)"
        }
    }
}

// MARK: - Safe array subscript

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
