import Foundation
import Observation

// MARK: - SearchViewModel
//
// Mirrors the Android `SearchPresenter`.

@MainActor
@Observable
public final class SearchViewModel {

    public var query: String = ""
    public var filter: SearchFilter = .default
    public private(set) var results: [Video] = []
    public private(set) var suggestions: [String] = []
    public private(set) var isLoading: Bool = false
    public var error: Error?

    private let api: any InnerTubeAPIProtocol
    private var nextPageToken: String?
    private var searchTask: Task<Void, Never>?
    private var suggestTask: Task<Void, Never>?

    private static let recommendedTerms: [String] = [
        "trending videos", "music 2025", "cooking recipes", "travel vlog",
        "programming tutorial", "workout", "movie trailer", "lofi hip hop",
        "documentary", "gaming highlights"
    ]

    public init(api: any InnerTubeAPIProtocol = InnerTubeAPI()) {
        self.api = api
        suggestions = Self.recommendedTerms
    }

    /// Call from `.task(id: query)` in the view to debounce live suggestions.
    /// When `q` is empty, restores the recommended terms immediately.
    public func updateSuggestions(for q: String) async {
        print("[Suggestions] updateSuggestions called, q='\(q)'")
        if q.isEmpty {
            print("[Suggestions] Empty query — restoring recommendedTerms")
            suggestions = Self.recommendedTerms
            return
        }
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else {
            print("[Suggestions] Task cancelled before fetch")
            return
        }
        fetchSuggestions(for: q)
    }

    public func search() {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        results = []
        nextPageToken = nil
        searchTask?.cancel()
        searchTask = Task { await performSearch(query: query, filter: filter) }
    }

    /// Apply a new filter and re-run the current search immediately.
    public func applyFilter(_ newFilter: SearchFilter) {
        filter = newFilter
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        results = []
        nextPageToken = nil
        searchTask?.cancel()
        searchTask = Task { await performSearch(query: query, filter: filter) }
    }

    public func loadMore() {
        guard let token = nextPageToken, !isLoading else { return }
        searchTask = Task { await performSearch(query: query, continuationToken: token, filter: filter) }
    }

    private func performSearch(query: String, continuationToken: String? = nil, filter: SearchFilter = .default) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let group = try await api.search(query: query, continuationToken: continuationToken, filter: filter)
            if continuationToken == nil {
                results = group.videos
            } else {
                results.append(contentsOf: group.videos)
            }
            nextPageToken = group.nextPageToken
        } catch {
            if !Task.isCancelled { self.error = error }
        }
    }

    private func fetchSuggestions(for query: String) {
        print("[Suggestions] fetchSuggestions spawning task for q='\(query)'")
        suggestTask?.cancel()
        suggestTask = Task {
            do {
                let s = try await api.fetchSearchSuggestions(query: query)
                guard !Task.isCancelled else {
                    print("[Suggestions] Task cancelled after fetch")
                    return
                }
                let result = s.isEmpty ? Self.recommendedTerms : s
                print("[Suggestions] Setting \(result.count) suggestions")
                suggestions = result
            } catch {
                print("[Suggestions] fetchSearchSuggestions threw: \(error)")
                if !Task.isCancelled { suggestions = Self.recommendedTerms }
            }
        }
    }
}

// MARK: - ChannelViewModel

@MainActor
@Observable
public final class ChannelViewModel {

    public private(set) var channel: Channel?
    public private(set) var videos: [Video] = []
    public private(set) var isLoading: Bool = false
    public var error: Error?

    private let api: any InnerTubeAPIProtocol
    private var nextPageToken: String?

    public init(api: any InnerTubeAPIProtocol = InnerTubeAPI()) {
        self.api = api
    }

    public func load(channelId: String) {
        Task { await loadAsync(channelId: channelId) }
    }

    private func loadAsync(channelId: String) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let (ch, group) = try await api.fetchChannel(channelId: channelId)
            channel = ch
            videos  = group.videos
            nextPageToken = group.nextPageToken
        } catch {
            self.error = error
        }
    }

    public func loadMore() {
        guard let id = channel?.id, let token = nextPageToken, !isLoading else { return }
        Task {
            isLoading = true
            defer { isLoading = false }
            do {
                let group = try await api.fetchChannelVideos(channelId: id, continuationToken: token)
                videos.append(contentsOf: group.videos)
                nextPageToken = group.nextPageToken
            } catch {
                self.error = error
            }
        }
    }
}
