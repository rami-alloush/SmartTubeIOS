import AVFoundation
import os
import SmartTubeIOSCore

private let audioOnlyLog = CrashlyticsLogger(category: "AudioOnly")

// MARK: - Audio-Only Playback Mode

extension PlaybackViewModel {

    /// Toggles audio-only mode on the **currently playing video** immediately.
    /// - Turning ON: saves playback position, loads the audio-only item, seeks back.
    /// - Turning OFF: saves playback position, reloads HLS video item, seeks back.
    /// The caller is responsible for persisting `store.settings.audioOnlyMode`.
    @MainActor
    func toggleAudioOnlyLive() {
        let savedTime = currentTime
        isAudioOnlyMode.toggle()
        settings.audioOnlyMode = isAudioOnlyMode

        if isAudioOnlyMode {
            Task { [weak self] in
                guard let self else { return }
                await self.loadAudioOnlyItemIfEnabled(seekTo: savedTime)
            }
        } else {
            Task { [weak self] in
                guard let self else { return }
                await self.reloadHLSItem(seekTo: savedTime, qualityCap: nil)
            }
        }
    }

    /// Entry point called from `loadAsync()` only when `isAudioOnlyMode == true`
    /// and `playerInfo` is already populated by the normal fetch.
    ///
    /// The existing HLS item is already loaded when this runs. If every audio-only
    /// attempt fails the HLS item remains active — the user gets video silently.
    func loadAudioOnlyItemIfEnabled(seekTo seekTime: TimeInterval = 0) async {
        guard isAudioOnlyMode else { return }
        guard let info = playerInfo else { return }

        // Live streams have no adaptive audio-only URL. Leave HLS path untouched.
        guard !info.video.isLive else {
            audioOnlyLog.notice("Audio-only: skipped for live stream id=\(info.video.id)")
            return
        }

        // Attempt 1: iOS client URL (already in memory, zero extra network cost).
        if let url = info.bestAdaptiveAudioURL {
            let success = await tryLoadAudioURL(url, userAgent: InnerTubeClients.iOS.userAgent, seekTo: seekTime)
            if success { return }
            audioOnlyLog.notice("Audio-only: iOS client URL failed, retrying with android_vr")
        }

        // Attempt 2: android_vr client — no PO Token required for unauthenticated users.
        await retryAudioOnlyWithAndroidVR(videoId: info.video.id, seekTo: seekTime)
    }

    /// Builds an `AVURLAsset` for the given audio URL, checks playability, and replaces
    /// the current player item. Returns `true` on success.
    private func tryLoadAudioURL(_ url: URL, userAgent: String, seekTo seekTime: TimeInterval = 0) async -> Bool {
        let opts: [String: Any] = [
            "AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": userAgent]
        ]
        let asset = AVURLAsset(url: url, options: opts)
        guard (try? await asset.load(.isPlayable)) == true else { return false }

        let item = AVPlayerItem(asset: asset)
        item.audioTimePitchAlgorithm = .spectral

        // Set up an item observer before replacing the current item, matching the
        // pattern used by every other load path. Without this the audio item's
        // .failed status is never observed, causing silent playback stalls.
        itemObserverTask?.cancel()
        itemObserverTask = Task { [weak self] in
            for await status in item.statusStream {
                guard let self, !Task.isCancelled else { return }
                switch status {
                case .readyToPlay:
                    audioOnlyLog.notice("✅ Audio-only AVPlayerItem readyToPlay")
                    if seekTime > 0 { self.seek(to: seekTime) }
                    self.player.rate = Float(self.settings.playbackSpeed)
                    self.isPlaying = true
                    self.loadAudioTracks(from: item)
                case .failed:
                    let err = item.error.map { "\($0)" } ?? "nil"
                    audioOnlyLog.error("❌ Audio-only AVPlayerItem failed: \(err)")
                    // Reset the flag so the UI re-shows the video layer.
                    // The HLS item placed by the primary load path is no longer the
                    // current item at this point, so also clear the error display.
                    self.isAudioOnlyMode = false
                    self.error = item.error
                case .unknown:
                    audioOnlyLog.notice("Audio-only: AVPlayerItem status unknown (loading)")
                @unknown default:
                    break
                }
            }
        }

        player.replaceCurrentItem(with: item)
        audioOnlyLog.notice("Audio-only: loaded \(url.absoluteString.prefix(80))")
        return true
    }

    /// Fetches player info with the android_vr client and retries loading the audio URL.
    /// Falls back to the existing HLS item (already in player) on any failure.
    private func retryAudioOnlyWithAndroidVR(videoId: String, seekTo seekTime: TimeInterval = 0) async {
        do {
            let vrInfo = try await api.fetchPlayerInfoAndroidVR(videoId: videoId)
            if let url = vrInfo.bestAdaptiveAudioURL {
                let success = await tryLoadAudioURL(url, userAgent: InnerTubeClients.AndroidVR.userAgent, seekTo: seekTime)
                if success { return }
            }
        } catch {
            audioOnlyLog.error("Audio-only: android_vr fetch failed: \(error)")
        }

        // Both attempts failed — the HLS item is already in the player. Reset the flag
        // so the UI re-shows the video layer rather than a blank thumbnail overlay.
        audioOnlyLog.notice("Audio-only: all attempts failed, falling back to HLS")
        isAudioOnlyMode = false
    }
}
