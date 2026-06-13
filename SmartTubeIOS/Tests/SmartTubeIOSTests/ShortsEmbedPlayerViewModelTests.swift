#if !os(tvOS)
import Foundation
import Testing
import SmartTubeIOSCore
@testable import SmartTubeIOS

@MainActor
@Suite("ShortsEmbedPlayerViewModel")
struct ShortsEmbedPlayerViewModelTests {

    @Test("Initial state before any loadShort() call")
    func initialState() {
        let vm = ShortsEmbedPlayerViewModel(api: InnerTubeAPI())
        #expect(vm.playerState == .unstarted)
        #expect(vm.currentTime == 0)
        #expect(vm.duration == 0)
        #expect(vm.isReady == false)
        #expect(vm.playerError == nil)
        #expect(vm.sponsorSegments.isEmpty)
        #expect(vm.currentToastSegment == nil)
        #expect(vm.sleepTimerMinutes == nil)
        #expect(vm.videoId == "")
    }

    @Test("updateSettings stores the new settings")
    func updateSettingsStoresNewSettings() {
        let vm = ShortsEmbedPlayerViewModel(api: InnerTubeAPI())
        var settings = AppSettings()
        settings.loopEnabled = true
        vm.updateSettings(settings)
        #expect(vm.settings.loopEnabled == true)
    }

    @Test("loadShort resets observable state for the new video")
    func loadShortResetsObservableState() {
        let vm = ShortsEmbedPlayerViewModel(api: InnerTubeAPI())
        vm.playerState = .playing
        vm.currentTime = 42
        vm.duration = 60
        vm.isReady = true

        vm.loadShort(video: Video(id: "abc123", title: "Test Short", channelTitle: "Channel"))

        #expect(vm.videoId == "abc123")
        #expect(vm.playerState == .unstarted)
        #expect(vm.currentTime == 0)
        #expect(vm.duration == 0)
        #expect(vm.isReady == false)
    }
}
#endif
