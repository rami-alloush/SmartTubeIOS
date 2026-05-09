import Foundation

// MARK: - Video

/// Mirrors the Android `Video` data model.
public struct Video: Identifiable, Hashable, Codable, Sendable {
    public let id: String                   // videoId
    public var title: String
    public var channelTitle: String
    public var channelId: String?
    public var description: String?
    public var thumbnailURL: URL?
    public var duration: TimeInterval?      // seconds
    public var viewCount: Int?
    public var publishedAt: Date?
    public var isLive: Bool
    public var isUpcoming: Bool
    public var isShort: Bool
    public var watchProgress: Double?       // 0.0 – 1.0
    public var playlistId: String?
    public var playlistIndex: Int?
    public var badges: [String]
    // Feed feedback tokens (session-scoped, from InnerTube menuRenderer)
    public var notInterestedToken: String?  // "Not interested" — hide this video
    public var dontLikeToken: String?       // "Don't like this video"
    public var hideChannelToken: String?    // "Don't recommend channel"

    public init(
        id: String,
        title: String,
        channelTitle: String,
        channelId: String? = nil,
        description: String? = nil,
        thumbnailURL: URL? = nil,
        duration: TimeInterval? = nil,
        viewCount: Int? = nil,
        publishedAt: Date? = nil,
        isLive: Bool = false,
        isUpcoming: Bool = false,
        isShort: Bool = false,
        watchProgress: Double? = nil,
        playlistId: String? = nil,
        playlistIndex: Int? = nil,
        badges: [String] = [],
        notInterestedToken: String? = nil,
        dontLikeToken: String? = nil,
        hideChannelToken: String? = nil
    ) {
        self.id = id
        self.title = title
        self.channelTitle = channelTitle
        self.channelId = channelId
        self.description = description
        self.thumbnailURL = thumbnailURL
        self.duration = duration
        self.viewCount = viewCount
        self.publishedAt = publishedAt
        self.isLive = isLive
        self.isUpcoming = isUpcoming
        self.isShort = isShort
        self.watchProgress = watchProgress
        self.playlistId = playlistId
        self.playlistIndex = playlistIndex
        self.badges = badges
        self.notInterestedToken = notInterestedToken
        self.dontLikeToken = dontLikeToken
        self.hideChannelToken = hideChannelToken
    }
}

// MARK: - Chapter

/// A named time-range bookmark within a video.
/// Mirrors Android's Chapter data class in YouTubeMediaItem.
public struct Chapter: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let title: String
    public let startTime: TimeInterval  // seconds from the start

    public init(title: String, startTime: TimeInterval) {
        self.id = UUID()
        self.title = title
        self.startTime = startTime
    }
}

// MARK: - Convenience helpers

public extension Video {
    var formattedDuration: String {
        guard let duration else { return "" }
        return formatDuration(duration)
    }

    var formattedViewCount: String {
        guard let viewCount else { return "" }
        switch viewCount {
        case 0..<1_000:       return "\(viewCount) views"
        case 1_000..<1_000_000: return String(format: "%.1fK views", Double(viewCount) / 1_000)
        default:              return String(format: "%.1fM views", Double(viewCount) / 1_000_000)
        }
    }

    /// High-quality thumbnail URL using YouTube's image CDN.
    var highQualityThumbnailURL: URL? {
        URL(string: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg")
    }
}
