import Foundation
import Observation
import os

private let homeLog = ViewModelLogger(category: "Home")

// MARK: - HomeViewModel
//
// Fetches Subscriptions and Recommended shelves in parallel
// to populate the Home tab's multi-section feed.

@MainActor
@Observable
public final class HomeViewModel {

    // MARK: - Section state

    public struct SectionState: Identifiable {
        public let section: BrowseSection
        public var videos: [Video] = []
        public var isLoading: Bool = true
        public var isLoadingMore: Bool = false
        public var hasFailed: Bool = false
        public var nextPageToken: String? = nil
        public var id: String { section.id }
    }

    // MARK: - State

    public private(set) var sections: [SectionState]
    public private(set) var isRefreshing: Bool = false
    /// Timestamp of the last successful load. Used for staleness checks.
    public private(set) var loadedAt: Date? = nil

    // MARK: - Shelf definitions (in display order)

    public static let shelfSections: [BrowseSection] = [
        BrowseSection(id: BrowseSection.SectionType.home.rawValue,          title: "Recommended",   type: .home),
        BrowseSection(id: BrowseSection.SectionType.subscriptions.rawValue, title: "Subscriptions", type: .subscriptions),
    ]

    /// Number of recommended videos inserted between each subscription video
    /// in the interleaved home feed.
    private static let interleaveRatio = 4

    /// `true` while either the recommended or subscriptions section is still on
    /// its initial load (no videos yet).  Used by the view to show a spinner.
    public var isLoadingAny: Bool {
        sections.contains { $0.isLoading }
    }

    /// A single interleaved video list that mixes recommended and subscription
    /// videos: one subscription video is inserted after every `interleaveRatio`
    /// recommended videos.  Subscription videos that duplicate an already-seen
    /// recommended ID are skipped.
    public var mergedVideos: [Video] {
        let recState  = sections.first { $0.section.type == .home }
        let subState  = sections.first { $0.section.type == .subscriptions }
        let recs  = recState?.videos  ?? []
        let subs  = subState?.videos  ?? []

        guard !subs.isEmpty else { return recs }
        guard !recs.isEmpty else { return subs }

        let recIds = Set(recs.map(\.id))
        let uniqueSubs = subs.filter { !recIds.contains($0.id) }

        var result: [Video] = []
        result.reserveCapacity(recs.count + uniqueSubs.count)

        var subIndex = 0
        for (i, rec) in recs.enumerated() {
            result.append(rec)
            let slot = i + 1
            if slot % Self.interleaveRatio == 0, subIndex < uniqueSubs.count {
                result.append(uniqueSubs[subIndex])
                subIndex += 1
            }
        }
        // Append any remaining subscription videos after all recommended videos.
        if subIndex < uniqueSubs.count {
            result.append(contentsOf: uniqueSubs[subIndex...])
        }
        return result
    }

    /// Non-Short videos from the interleaved home feed.
    /// Used by `homeShelves` to populate the main grid (Shorts are shown separately).
    public var homeRegularVideos: [Video] { mergedVideos.filter { !$0.isShort } }

    /// Short videos from the interleaved home feed.
    /// Used by `homeShelves` to populate the dedicated Shorts row.
    public var homeShortsVideos: [Video] { mergedVideos.filter { $0.isShort } }

    // MARK: - Dependencies

    private let api: any InnerTubeAPIProtocol
    private var loadTask: Task<Void, Never>?
    private var hideObserverTasks: [Task<Void, Never>] = []

    public init(api: any InnerTubeAPIProtocol = InnerTubeAPI()) {
        self.api = api
        self.sections = Self.shelfSections.map { SectionState(section: $0) }
        observeFeedHideNotifications()
    }

    // MARK: - Feed hide handling

    private func observeFeedHideNotifications() {
        hideObserverTasks.append(Task { [weak self] in
            for await note in NotificationCenter.default.notifications(named: .hideVideoFromFeed) {
                guard let self, let videoId = note.userInfo?["videoId"] as? String else { continue }
                self.removeVideo(id: videoId)
            }
        })
        hideObserverTasks.append(Task { [weak self] in
            for await note in NotificationCenter.default.notifications(named: .hideChannelFromFeed) {
                guard let self, let channelId = note.userInfo?["channelId"] as? String else { continue }
                self.removeChannel(id: channelId)
            }
        })
    }

    public func removeVideo(id: String) {
        for i in sections.indices {
            sections[i].videos.removeAll { $0.id == id }
        }
    }

    public func removeChannel(id: String) {
        for i in sections.indices {
            sections[i].videos.removeAll { $0.channelId == id }
        }
    }

    // MARK: - Public API

    public func load() {
        loadTask?.cancel()
        loadedAt = nil
        isRefreshing = true
        for i in sections.indices {
            sections[i].videos = []
            sections[i].isLoading = true
            sections[i].isLoadingMore = false
            sections[i].hasFailed = false
            sections[i].nextPageToken = nil
        }
        loadTask = Task {
            await withTaskGroup(of: (String, [Video], String?).self) { group in
                for state in sections {
                    let sectionId = state.id
                    let type = state.section.type
                    let api = self.api
                    group.addTask {
                        let (videos, token) = await HomeViewModel.fetchVideos(type: type, api: api)
                        return (sectionId, videos, token)
                    }
                }
                for await (sectionId, videos, token) in group {
                    guard !Task.isCancelled else { break }
                    if let idx = sections.firstIndex(where: { $0.id == sectionId }) {
                        sections[idx].videos = videos
                        sections[idx].nextPageToken = token
                        sections[idx].isLoading = false
                        sections[idx].hasFailed = videos.isEmpty
                    }
                }
            }
            isRefreshing = false
            loadedAt = Date()
        }
    }

    public func updateAuthToken(_ token: String?) async {
        await api.setAuthToken(token)
        if token != nil { load() }
    }

    /// Refreshes both shelves if the last successful load was more than
    /// `threshold` seconds ago (default 15 min). No-op while loading.
    public func refreshIfStale(threshold: TimeInterval = 15 * 60) {
        guard !isRefreshing else { return }
        let age = loadedAt.map { Date().timeIntervalSince($0) } ?? .infinity
        guard age > threshold else { return }
        let ageDesc = age.isFinite ? "\(Int(age))s" : "never loaded"
        homeLog.notice("refreshIfStale: age=\(ageDesc) — reloading shelves")
        load()
    }

    // MARK: - Pagination

    public func loadMore(sectionId: String) {
        guard let idx = sections.firstIndex(where: { $0.id == sectionId }),
              let token = sections[idx].nextPageToken,
              !sections[idx].isLoadingMore,
              !sections[idx].isLoading else { return }
        sections[idx].isLoadingMore = true
        let type = sections[idx].section.type
        Task {
            let (newVideos, nextToken) = await HomeViewModel.fetchMoreVideos(type: type, token: token, api: api)
            if let idx = sections.firstIndex(where: { $0.id == sectionId }) {
                let existingIds = Set(sections[idx].videos.map(\.id))
                let deduplicated = newVideos.filter { !existingIds.contains($0.id) }
                sections[idx].videos.append(contentsOf: deduplicated)
                // Re-sort after merging so videos from different pages remain in
                // strict newest-first order across pagination boundaries.
                if sections[idx].section.type == .subscriptions {
                    sections[idx].videos.sort { ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) }
                }
                sections[idx].nextPageToken = nextToken
                sections[idx].isLoadingMore = false
            }
        }
    }

    /// Called by the merged home feed when the user scrolls near the bottom.
    /// Pages both the recommended and subscriptions sections simultaneously so
    /// the interleaved list keeps growing evenly.
    public func loadMoreMerged() {
        for state in sections where state.section.type == .home || state.section.type == .subscriptions {
            loadMore(sectionId: state.id)
        }
    }

    // MARK: - Private fetch helpers

    /// Non-isolated so child tasks run on the global executor and network
    /// calls can overlap.
    private static func fetchVideos(type: BrowseSection.SectionType, api: any InnerTubeAPIProtocol) async -> ([Video], String?) {
        do {
            switch type {
            case .subscriptions:
                let group = try await api.fetchSubscriptions()
                return (Array(group.videos.prefix(InnerTubeClients.maxVideoResults)), group.nextPageToken)
            case .home:
                let rows = try await api.fetchHomeRows()
                let token = rows.last(where: { $0.nextPageToken != nil })?.nextPageToken
                var seen = Set<String>()
                let deduped = rows.flatMap(\.videos).filter { seen.insert($0.id).inserted }
                if deduped.isEmpty {
                    // Home feed empty (no watch history / feedNudgeRenderer) — fall back to popular
                    let popular = try await api.search(query: "popular")
                    return (popular.videos, popular.nextPageToken)
                }
                return (Array(deduped.prefix(InnerTubeClients.maxVideoResults)), token)
            default:
                return ([], nil)
            }
        } catch {
            homeLog.error("HomeViewModel fetch \(String(describing: type)): \(error.localizedDescription)")
            return ([], nil)
        }
    }

    private static func fetchMoreVideos(type: BrowseSection.SectionType, token: String, api: any InnerTubeAPIProtocol) async -> ([Video], String?) {
        do {
            switch type {
            case .subscriptions:
                let group = try await api.fetchSubscriptions(continuationToken: token)
                return (group.videos, group.nextPageToken)
            case .home:
                let rows = try await api.fetchHomeRows(continuationToken: token)
                let nextToken = rows.last(where: { $0.nextPageToken != nil })?.nextPageToken
                return (rows.flatMap(\.videos), nextToken)
            default:
                return ([], nil)
            }
        } catch {
            homeLog.error("HomeViewModel loadMore \(String(describing: type)): \(error.localizedDescription)")
            return ([], nil)
        }
    }
}
