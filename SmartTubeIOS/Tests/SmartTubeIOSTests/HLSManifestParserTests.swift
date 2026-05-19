import Foundation
import Testing
@testable import SmartTubeIOSCore

// MARK: - HLSManifestParserTests

@Suite("HLS Manifest Parser")
struct HLSManifestParserTests {

    private let base = URL(string: "https://cdn.example.com/hls/")!

    // MARK: - Empty / malformed

    @Test("empty manifest returns empty dictionary")
    func parseHLS_emptyManifest_returnsEmpty() {
        let result = parseHLSMasterManifest("", baseURL: base)
        #expect(result.isEmpty)
    }

    @Test("manifest with only tags but no URI lines returns empty")
    func parseHLS_onlyTags_returnsEmpty() {
        let manifest = """
        #EXTM3U
        #EXT-X-VERSION:3
        """
        let result = parseHLSMasterManifest(manifest, baseURL: base)
        #expect(result.isEmpty)
    }

    @Test("malformed STREAM-INF lines without URI are skipped")
    func parseHLS_malformedLines_skipped() {
        let manifest = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080
        #EXT-X-STREAM-INF:BANDWIDTH=3000000,RESOLUTION=1280x720
        https://cdn.example.com/720p.m3u8
        """
        let result = parseHLSMasterManifest(manifest, baseURL: base)
        // Only the 720p entry has a URI immediately following; 1080p has another tag → skipped
        #expect(result[720] != nil)
        #expect(result[1080] == nil)
    }

    // MARK: - Single variant

    @Test("single 1080p variant with absolute URI is parsed")
    func parseHLS_singleVariant1080p_returnsOneEntry() {
        let manifest = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080
        https://cdn.example.com/1080p.m3u8
        """
        let result = parseHLSMasterManifest(manifest, baseURL: base)
        #expect(result.count == 1)
        #expect(result[1080] == URL(string: "https://cdn.example.com/1080p.m3u8"))
    }

    // MARK: - Multiple heights

    @Test("multiple heights all returned in the dictionary")
    func parseHLS_multipleHeights_returnsAllHeights() {
        let manifest = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=15000000,RESOLUTION=1920x1080
        https://cdn.example.com/1080p.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=8000000,RESOLUTION=1280x720
        https://cdn.example.com/720p.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=4000000,RESOLUTION=854x480
        https://cdn.example.com/480p.m3u8
        """
        let result = parseHLSMasterManifest(manifest, baseURL: base)
        #expect(result.count == 3)
        #expect(result[1080] != nil)
        #expect(result[720]  != nil)
        #expect(result[480]  != nil)
    }

    // MARK: - Relative vs absolute URIs

    @Test("relative URI is resolved against baseURL")
    func parseHLS_relativeURI_resolvesAgainstBaseURL() {
        let manifest = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080
        1080p.m3u8
        """
        let result = parseHLSMasterManifest(manifest, baseURL: base)
        #expect(result[1080] == URL(string: "https://cdn.example.com/hls/1080p.m3u8"))
    }

    @Test("absolute http URI is preserved as-is")
    func parseHLS_absoluteURI_preservesAbsoluteURL() {
        let absolute = "https://other-cdn.example.net/streams/1080p.m3u8"
        let manifest = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080
        \(absolute)
        """
        let result = parseHLSMasterManifest(manifest, baseURL: base)
        #expect(result[1080] == URL(string: absolute))
    }

    // MARK: - H.264 vs HEVC codec preference

    @Test("on non-tvOS: HEVC variant at same height is upgraded to H.264 when H.264 follows")
    func parseHLS_hevcAndH264SameHeight_iOS_prefersH264() {
        // YouTube manifests often list HEVC first, then H.264 at the same resolution.
        let manifest = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=6000000,RESOLUTION=1920x1080,CODECS="hvc1.2.4.L123.B0"
        https://cdn.example.com/1080p_hevc.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080,CODECS="avc1.640028"
        https://cdn.example.com/1080p_h264.m3u8
        """
        let result = parseHLSMasterManifest(manifest, baseURL: base)
        #expect(result[1080] != nil)
        // On iOS/macOS the H.264 variant must win; on tvOS the first-seen (HEVC) wins.
#if os(tvOS)
        #expect(result[1080] == URL(string: "https://cdn.example.com/1080p_hevc.m3u8"),
                "tvOS: keeps first-seen HEVC variant")
#else
        #expect(result[1080] == URL(string: "https://cdn.example.com/1080p_h264.m3u8"),
                "iOS/macOS: upgrades to H.264 variant for broader compatibility")
#endif
    }

    @Test("H.264 first, HEVC second: H.264 is not downgraded")
    func parseHLS_h264First_notDowngradedToHEVC() {
        let manifest = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080,CODECS="avc1.640028"
        https://cdn.example.com/1080p_h264.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=6000000,RESOLUTION=1920x1080,CODECS="hvc1.2.4.L123.B0"
        https://cdn.example.com/1080p_hevc.m3u8
        """
        let result = parseHLSMasterManifest(manifest, baseURL: base)
        // H.264 came first; HEVC must not overwrite it on any platform.
        #expect(result[1080] == URL(string: "https://cdn.example.com/1080p_h264.m3u8"))
    }
}
