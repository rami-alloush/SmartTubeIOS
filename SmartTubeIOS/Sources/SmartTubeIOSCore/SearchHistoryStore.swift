import Foundation

// MARK: - SearchHistoryStore
//
// Persists the user's local search query history across sessions.
// Stores up to `maxEntries` entries, newest-first. Re-submitting an existing
// query moves it to the top rather than creating a duplicate.
//
// Thread-safe: implemented as a Swift actor, mirroring VideoStateStore,
// LocalSubscriptionStore, and CurrentQueueStore.

public actor SearchHistoryStore {

    // MARK: - Singleton

    public static let shared = SearchHistoryStore()

    // MARK: - Private

    private static let udKey = "st_search_history"
    private static let maxEntries = 50

    private var entries: [SearchHistoryEntry] = []
    private let defaults: UserDefaults

    private init() {
        self.defaults = .standard
        entries = Self.load(from: .standard)
    }

    /// Designated initializer for unit testing. Pass a unique `suiteName` string
    /// (e.g. `"test-\(UUID().uuidString)"`) to get a fully isolated store with
    /// no shared `UserDefaults` state.
    init(suiteName: String) {
        let ud = UserDefaults(suiteName: suiteName) ?? .standard
        self.defaults = ud
        entries = Self.load(from: ud)
    }

    // MARK: - Public API

    /// All history entries sorted newest-first.
    public var all: [SearchHistoryEntry] { entries }

    /// Adds or updates `query` in the history.
    /// If the query already exists it is moved to the top; otherwise a new entry
    /// is prepended. Trims to `maxEntries` by dropping the oldest entry when needed.
    public func add(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        entries.removeAll { $0.query.lowercased() == trimmed.lowercased() }
        entries.insert(SearchHistoryEntry(query: trimmed), at: 0)
        if entries.count > Self.maxEntries {
            entries = Array(entries.prefix(Self.maxEntries))
        }
        persist()
    }

    /// Removes the entry matching `query` (case-insensitive). No-op if not found.
    public func remove(_ query: String) {
        entries.removeAll { $0.query.lowercased() == query.lowercased() }
        persist()
    }

    /// Deletes all history entries.
    public func clear() {
        entries = []
        persist()
    }

    // MARK: - Persistence

    private static func load(from defaults: UserDefaults) -> [SearchHistoryEntry] {
        guard let data = defaults.data(forKey: udKey),
              let decoded = try? JSONDecoder().decode([SearchHistoryEntry].self, from: data)
        else { return [] }
        return decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: Self.udKey)
    }
}
