/// Global debug flags — flip these locally when you need a reproducible cold-start
/// baseline. Commit only with all flags set to their default (production) values.
///
/// `cachingDisabled`:
///   When `true`, every in-memory cache read returns nil/empty so every player load
///   goes through the full live network path:
///   · `VideoPreloadCache.consume()` returns an all-nil `CachedVideoData`
///   · `VideoPreloadCache.cachedWKHLSURL()` returns nil
///   · `VideoPreloadCache.cachedPoToken()` returns nil
///   · `VideoPreloadCache.prefetch()` is a no-op
///   · `BotGuardClient.token(for:)` always mints a fresh token (skips TTL cache)
///   Writes to caches are unaffected — the cache fills normally, reads are just bypassed.
public enum DebugFlags {
    /// Set to `true` to disable all custom in-memory caching for cold-start benchmarking.
    /// Default: `false` (full caching enabled in production).
    public static let cachingDisabled: Bool = false
}
