import Foundation
import Testing
@testable import SmartTubeIOSCore

// MARK: - VideoPreloadCacheTTLTests
//
// Verifies that TTL constants match their documented values and that
// CacheEntry.isExpired reflects whether the entry is within its TTL window.
// No network calls, no actor isolation needed — CacheEntry is a plain struct.

@Suite("Video Preload Cache TTL")
struct VideoPreloadCacheTTLTests {

    // MARK: - TTL constant values

    @Test("playerInfoTTL is 5 hours 30 minutes")
    func playerInfoTTLIs5h30m() {
        #expect(VideoPreloadCache.playerInfoTTL == 5.5 * 3600)
    }

    @Test("trackingTTL is 1 hour")
    func trackingTTLIs1h() {
        #expect(VideoPreloadCache.trackingTTL == 3600)
    }

    @Test("nextInfoTTL is 5 minutes")
    func nextInfoTTLIs5min() {
        #expect(VideoPreloadCache.nextInfoTTL == 300)
    }

    @Test("endCardsTTL is 1 hour")
    func endCardsTTLIs1h() {
        #expect(VideoPreloadCache.endCardsTTL == 3600)
    }

    @Test("sponsorTTL is 1 hour")
    func sponsorTTLIs1h() {
        #expect(VideoPreloadCache.sponsorTTL == 3600)
    }

    @Test("deArrowTTL is 1 hour")
    func deArrowTTLIs1h() {
        #expect(VideoPreloadCache.deArrowTTL == 3600)
    }

    // MARK: - CacheEntry.isExpired logic

    @Test("Fresh entry stored just now is not expired")
    func freshEntryIsNotExpired() {
        let entry = VideoPreloadCache.CacheEntry(value: 1, storedAt: Date(), ttl: 3600)
        #expect(!entry.isExpired)
    }

    @Test("Entry stored longer ago than its TTL is expired")
    func expiredEntryIsExpired() {
        let twoHoursAgo = Date(timeIntervalSinceNow: -7200)
        let entry = VideoPreloadCache.CacheEntry(value: 1, storedAt: twoHoursAgo, ttl: 3600)
        #expect(entry.isExpired)
    }

    @Test("Entry stored 1 s past TTL is expired")
    func entryAtExactTTLBoundaryIsExpired() {
        // Production code: elapsed > ttl. One second past TTL → definitely expired.
        let oneSecondPast = Date(timeIntervalSinceNow: -3601)
        let entry = VideoPreloadCache.CacheEntry(value: 1, storedAt: oneSecondPast, ttl: 3600)
        #expect(entry.isExpired)
    }

    @Test("Entry stored just under the TTL is not expired")
    func entryJustUnderTTLIsNotExpired() {
        // 1 second less than the TTL — should still be fresh
        let nearlyExpired = Date(timeIntervalSinceNow: -3599)
        let entry = VideoPreloadCache.CacheEntry(value: 1, storedAt: nearlyExpired, ttl: 3600)
        #expect(!entry.isExpired)
    }

    @Test("Short TTL of 5 minutes expires after 6 minutes")
    func shortTTLExpiresCorrectly() {
        let sixMinutesAgo = Date(timeIntervalSinceNow: -360)
        let entry = VideoPreloadCache.CacheEntry(value: "data", storedAt: sixMinutesAgo, ttl: 300)
        #expect(entry.isExpired)
    }
}
