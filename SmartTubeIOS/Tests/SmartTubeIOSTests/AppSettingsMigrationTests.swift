import Foundation
import Testing
@testable import SmartTubeIOSCore

// MARK: - AppSettingsMigrationTests
//
// Regression tests for task #181: user settings (quality, theme, SponsorBlock, etc.)
// were silently reset to defaults on every app update that added or renamed a property
// in AppSettings.
//
// Root cause: the synthesized Codable init(from:) requires ALL non-Optional properties
// to be present in the JSON. A single missing property (added in a new version) causes
// JSONDecoder to throw, which SettingsStore catches via `try?` and falls back to a fresh
// AppSettings() — wiping all user preferences.
//
// Fix: custom init(from:) using decodeIfPresent with per-field defaults so that missing
// keys always receive their intended default rather than causing a total settings reset.

@Suite("AppSettings forward-compatible decoding (#181)")
struct AppSettingsMigrationTests {

    // MARK: - Missing new field → default, other fields preserved

    /// Simulates loading settings stored by an old app version that doesn't have
    /// a field that was added in the current version (e.g. `settingsVersion`).
    /// The decode must succeed and return the stored values, not fall back to defaults.
    @Test("Old JSON missing new field decodes successfully with stored values preserved")
    func oldJSONMissingNewFieldDecodeSucceeds() throws {
        // JSON without `settingsVersion` (a field added in the current version)
        let json = """
        {
            "preferredQuality": "1080p",
            "playbackSpeed": 1.5,
            "autoplayEnabled": false,
            "subtitlesEnabled": true,
            "backgroundPlaybackEnabled": false,
            "landscapeAlwaysPlay": true,
            "pipEnabled": false,
            "miniPlayerEnabled": true,
            "seekBackSeconds": 15,
            "seekForwardSeconds": 45,
            "controlsHideTimeout": 6,
            "videoGravityMode": "fill",
            "loopEnabled": true,
            "shuffleEnabled": false,
            "defaultSection": "subscriptions",
            "compactThumbnails": true,
            "hideShorts": true,
            "perDeviceRecommendationsEnabled": false,
            "themeName": "Dark",
            "enabledSections": ["home", "subscriptions"],
            "historyState": "disabled",
            "sponsorBlockEnabled": false,
            "sponsorBlockActions": {},
            "sponsorBlockMinSegmentDuration": 2.5,
            "sponsorBlockExcludedChannels": {},
            "deArrowEnabled": true,
            "forceIPv4": false,
            "audioOnlyMode": true,
            "preferH264": true,
            "iCloudSyncEnabled": true
        }
        """.data(using: .utf8)!

        let settings = try JSONDecoder().decode(AppSettings.self, from: json)

        // Stored values must survive
        #expect(settings.preferredQuality == .q1080)
        #expect(settings.playbackSpeed == 1.5)
        #expect(settings.autoplayEnabled == false)
        #expect(settings.subtitlesEnabled == true)
        #expect(settings.landscapeAlwaysPlay == true)
        #expect(settings.pipEnabled == false)
        #expect(settings.seekBackSeconds == 15)
        #expect(settings.seekForwardSeconds == 45)
        #expect(settings.controlsHideTimeout == 6)
        #expect(settings.videoGravityMode == .fill)
        #expect(settings.loopEnabled == true)
        #expect(settings.hideShorts == true)
        #expect(settings.themeName == .dark)
        #expect(settings.historyState == .disabled)
        #expect(settings.sponsorBlockEnabled == false)
        #expect(settings.sponsorBlockMinSegmentDuration == 2.5)
        #expect(settings.deArrowEnabled == true)
        #expect(settings.audioOnlyMode == true)
        #expect(settings.preferH264 == true)
        #expect(settings.iCloudSyncEnabled == true)

        // Missing field decodes as 0 (the pre-migration sentinel), then the one-time
        // migration in init(from:) bumps it to the current settingsVersion (2) so
        // version-gated migrations don't re-run on every subsequent load.
        #expect(settings.settingsVersion == 2, "Old JSON without settingsVersion should be migrated to the current settingsVersion")
    }

    // MARK: - Type-mismatched field → default for that field, others preserved

    /// Simulates a field whose stored type no longer matches (e.g. Bool stored where Int expected).
    /// Only the mismatched field should fall to its default; all other fields must be preserved.
    @Test("Type-mismatched field falls to default, all other fields preserved")
    func typeMismatchedFieldFallsToDefault() throws {
        // controlsHideTimeout stored as a string (invalid) — was Int
        let json = """
        {
            "preferredQuality": "720p",
            "playbackSpeed": 2.0,
            "autoplayEnabled": true,
            "subtitlesEnabled": false,
            "backgroundPlaybackEnabled": false,
            "landscapeAlwaysPlay": false,
            "pipEnabled": true,
            "miniPlayerEnabled": true,
            "seekBackSeconds": 10,
            "seekForwardSeconds": 30,
            "controlsHideTimeout": "bad_value",
            "videoGravityMode": "fit",
            "loopEnabled": false,
            "shuffleEnabled": false,
            "defaultSection": "home",
            "compactThumbnails": false,
            "hideShorts": false,
            "perDeviceRecommendationsEnabled": true,
            "themeName": "System",
            "enabledSections": [],
            "historyState": "enabled",
            "sponsorBlockEnabled": true,
            "sponsorBlockActions": {},
            "sponsorBlockMinSegmentDuration": 0,
            "sponsorBlockExcludedChannels": {},
            "deArrowEnabled": false,
            "forceIPv4": false,
            "audioOnlyMode": false,
            "preferH264": false,
            "iCloudSyncEnabled": false,
            "settingsVersion": 1
        }
        """.data(using: .utf8)!

        let settings = try JSONDecoder().decode(AppSettings.self, from: json)

        // Type-mismatched field falls to default (4 seconds)
        #expect(settings.controlsHideTimeout == 4, "Type-mismatched field must fall to its default, not crash/reset all settings")

        // All other stored values must survive
        #expect(settings.preferredQuality == .q720)
        #expect(settings.playbackSpeed == 2.0)

        // settingsVersion 1 predates the useTOSPlayerOnIOS-default migration, so the
        // one-time migration in init(from:) bumps it to the current version (2).
        #expect(settings.settingsVersion == 2)
    }

    // MARK: - Round-trip: encode then decode preserves all values

    /// Verifies that a full encode → decode cycle preserves every field including
    /// settingsVersion. This confirms the custom init(from:) and synthesized encode(to:)
    /// are consistent with each other.
    @Test("Full encode/decode round-trip preserves all settings")
    func roundTripPreservesAllSettings() throws {
        var original = AppSettings()
        original.preferredQuality = .q1440
        original.playbackSpeed = 0.75
        original.autoplayEnabled = false
        original.subtitlesEnabled = true
        original.subtitlesLanguage = "fr"
        original.landscapeAlwaysPlay = true
        original.seekBackSeconds = 20
        original.seekForwardSeconds = 60
        original.controlsHideTimeout = 8
        original.videoGravityMode = .fill
        original.hideShorts = true
        original.themeName = .dark
        original.historyState = .disabled
        original.sponsorBlockEnabled = false
        original.deArrowEnabled = true
        original.iCloudSyncEnabled = true
        // settingsVersion 2 is the current version (post useTOSPlayerOnIOS migration),
        // so round-tripping it should be a pure no-op — see
        // AppSettingsTOSPlayerMigrationTests for the settingsVersion 1 → 2 migration itself.
        original.settingsVersion = 2

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: encoded)

        #expect(decoded.preferredQuality == original.preferredQuality)
        #expect(decoded.playbackSpeed == original.playbackSpeed)
        #expect(decoded.autoplayEnabled == original.autoplayEnabled)
        #expect(decoded.subtitlesEnabled == original.subtitlesEnabled)
        #expect(decoded.subtitlesLanguage == original.subtitlesLanguage)
        #expect(decoded.landscapeAlwaysPlay == original.landscapeAlwaysPlay)
        #expect(decoded.seekBackSeconds == original.seekBackSeconds)
        #expect(decoded.seekForwardSeconds == original.seekForwardSeconds)
        #expect(decoded.controlsHideTimeout == original.controlsHideTimeout)
        #expect(decoded.videoGravityMode == original.videoGravityMode)
        #expect(decoded.hideShorts == original.hideShorts)
        #expect(decoded.themeName == original.themeName)
        #expect(decoded.historyState == original.historyState)
        #expect(decoded.sponsorBlockEnabled == original.sponsorBlockEnabled)
        #expect(decoded.deArrowEnabled == original.deArrowEnabled)
        #expect(decoded.iCloudSyncEnabled == original.iCloudSyncEnabled)
        #expect(decoded.settingsVersion == original.settingsVersion)
    }

    // MARK: - Completely empty JSON → all defaults (no crash)

    /// Simulates a completely empty JSON object (e.g. corrupted store).
    /// Must return all defaults rather than throwing or crashing.
    @Test("Completely empty JSON decodes to all defaults without crashing")
    func emptyJSONDecodesToDefaults() throws {
        let json = "{}".data(using: .utf8)!
        let settings = try JSONDecoder().decode(AppSettings.self, from: json)
        let defaults = AppSettings()

        #expect(settings.preferredQuality == defaults.preferredQuality)
        #expect(settings.playbackSpeed == defaults.playbackSpeed)
        #expect(settings.autoplayEnabled == defaults.autoplayEnabled)
        #expect(settings.seekBackSeconds == defaults.seekBackSeconds)
        #expect(settings.sponsorBlockEnabled == defaults.sponsorBlockEnabled)
        #expect(settings.settingsVersion == 2, "Empty JSON should be migrated to the current settingsVersion")
    }
}

// MARK: - useTOSPlayerOnIOS one-time migration (settingsVersion 1 → 2)
//
// Before settingsVersion 2, `useTOSPlayerOnIOS` defaulted to `false` on every
// platform, so existing installs persisted that value explicitly. When the iOS
// default changed to `true`, `safeDecode` saw the key present in old JSON and kept
// the stale `false` — silently negating the new default for any non-fresh install.
//
// Fix: a one-time migration in init(from:) forces `useTOSPlayerOnIOS = true` on iOS
// for any store with settingsVersion < 2, then bumps settingsVersion to 2 so the
// migration never re-applies (and a later explicit user opt-out sticks).

@Suite("AppSettings useTOSPlayerOnIOS migration (settingsVersion 1 → 2)")
struct AppSettingsTOSPlayerMigrationTests {

    @Test("Pre-migration store (settingsVersion 1, useTOSPlayerOnIOS=false) is migrated")
    func preMigrationStoreIsMigrated() throws {
        let json = """
        {
            "settingsVersion": 1,
            "useTOSPlayerOnIOS": false,
            "useTOSPlayerOnMac": false
        }
        """.data(using: .utf8)!

        let settings = try JSONDecoder().decode(AppSettings.self, from: json)

        #if os(iOS)
        #expect(settings.useTOSPlayerOnIOS == true, "Pre-migration iOS stores must have useTOSPlayerOnIOS forced on")
        #endif
        #expect(settings.settingsVersion == 2, "Migration must bump settingsVersion so it doesn't re-fire")
    }

    @Test("Pre-migration store with no settingsVersion at all (settingsVersion 0) is migrated")
    func preMigrationStoreWithoutVersionIsMigrated() throws {
        let json = """
        {
            "useTOSPlayerOnIOS": false
        }
        """.data(using: .utf8)!

        let settings = try JSONDecoder().decode(AppSettings.self, from: json)

        #if os(iOS)
        #expect(settings.useTOSPlayerOnIOS == true, "Pre-migration iOS stores must have useTOSPlayerOnIOS forced on")
        #endif
        #expect(settings.settingsVersion == 2, "Migration must bump settingsVersion so it doesn't re-fire")
    }

    @Test("Post-migration store with useTOSPlayerOnIOS explicitly off stays off")
    func postMigrationExplicitOptOutIsPreserved() throws {
        // A user already on settingsVersion 2 who explicitly disabled the TOS
        // player via Settings must not be re-migrated back to true.
        let json = """
        {
            "settingsVersion": 2,
            "useTOSPlayerOnIOS": false
        }
        """.data(using: .utf8)!

        let settings = try JSONDecoder().decode(AppSettings.self, from: json)

        #expect(settings.useTOSPlayerOnIOS == false, "Explicit opt-out after migration must be preserved")
        #expect(settings.settingsVersion == 2)
    }
}
