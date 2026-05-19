import Foundation

// MARK: - Quality Recovery Policy
//
// Pure classification logic extracted from PlaybackQualityManager.reloadHLSItem
// (task #141, SRP-2). No AVFoundation import needed — error domains are string constants.

// Known error domain strings. Using literals avoids importing AVFoundation into this
// Foundation-only core module. Values match the frameworks' public constants.
private let nsURLErrorDomain = NSURLErrorDomain
private let avFoundationErrorDomain = "AVFoundationErrorDomain"

/// Describes what recovery action `PlaybackQualityManager` should take when an
/// `AVPlayerItem` enters the `.failed` state during a quality-switch reload.
public enum QualityRecoveryAction: Sendable {
    /// HTTP 403 — invalidate the player-info cache and re-fetch via the 403 recovery path.
    case retry403Recovery
    /// A specific quality cap failed — revert `selectedFormat` to Auto and reload the master.
    case revertToAuto
    /// Auto HLS produced an H.264 decode error on first attempt — reload with a bitrate cap.
    case retryWithH264Cap
    /// Unrecoverable; surface the error to the user.
    case fail(error: Error?)
}

/// Returns the recovery action for a failed `AVPlayerItem`.
///
/// Priority (highest first):
/// 1. HTTP 403 → `.retry403Recovery`
/// 2. `qualityCap` was set (non-auto) → `.revertToAuto`
/// 3. H.264 decode error on first attempt → `.retryWithH264Cap`
/// 4. All other cases → `.fail(error:)`
///
/// - Parameters:
///   - error: The `NSError` from `AVPlayerItem.error`.
///   - qualityCap: The height cap in pixels, or `nil` when playing in Auto mode.
///   - hasAppliedH264Cap: `true` if the H.264 bitrate cap has already been tried.
public func qualityRecoveryAction(
    for error: NSError,
    qualityCap: Int?,
    hasAppliedH264Cap: Bool
) -> QualityRecoveryAction {
    let is403 = error.domain == nsURLErrorDomain && error.code == -1102
    let isH264DecodeError = error.domain == avFoundationErrorDomain && error.code == -11833
    if is403 { return .retry403Recovery }
    if qualityCap != nil { return .revertToAuto }
    if !hasAppliedH264Cap && isH264DecodeError { return .retryWithH264Cap }
    return .fail(error: error)
}
