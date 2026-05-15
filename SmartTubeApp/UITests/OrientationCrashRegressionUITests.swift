import XCTest

// MARK: - OrientationCrashRegressionUITests
//
// Regression test for Crashlytics issue 1bce7ef11c47da56fe887213f0d7a652:
// EXC_BREAKPOINT in OrientationManager.requestGeometryUpdate(_:) error handler.
//
// Root cause: The error handler closure `{ error in ... }` inherited @MainActor
// isolation from the enclosing `Task { @MainActor in ... }`. On iOS 26+,
// UIWindowScene._performIOSGeometryRequestWithPreferences:errorHandler: calls the
// handler on a background GCD queue. Swift 6's _swift_task_checkIsolatedSwift
// detects the isolation violation and crashes with EXC_BREAKPOINT.
//
// Fix: Extracted error handler as a file-scope @Sendable function in
// OrientationManager.swift (geometryUpdateErrorHandler), explicitly non-isolated.
//
// This test exercises the requestGeometryUpdate code path by simulating a
// landscape → portrait rotation while a video is playing.

final class OrientationCrashRegressionUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
        app = nil
    }

    // MARK: - Tests

    /// Rotating between landscape and portrait while a video plays must not crash.
    /// This covers the requestGeometryUpdate error-handler actor-isolation fix.
    func testOrientationRotationDoesNotCrash() throws {
        app.launchArguments = [
            "--uitesting",
            "--uitesting-deeplink-video=dQw4w9WgXcQ"
        ]
        app.launch()

        let player = app.otherElements["player.view"].firstMatch
        guard player.waitForExistence(timeout: 20) else {
            throw XCTSkip("Player did not open within 20 s — network unavailable or video inaccessible")
        }

        // Allow the video to start buffering before rotating.
        // Rotate to landscape — triggers OrientationManager.requestGeometryUpdate(.landscape)
        XCUIDevice.shared.orientation = .landscapeLeft
        // Brief dwell to allow UIKit geometry update to complete and any error callback to fire.
        Thread.sleep(forTimeInterval: 1.0)

        // Rotate back to portrait — triggers OrientationManager.requestGeometryUpdate(.portrait)
        XCUIDevice.shared.orientation = .portrait
        Thread.sleep(forTimeInterval: 1.0)

        // A second full cycle verifies the geometry update is repeatable.
        XCUIDevice.shared.orientation = .landscapeRight
        Thread.sleep(forTimeInterval: 1.0)
        XCUIDevice.shared.orientation = .portrait

        // If we reach here the app has not crashed. Confirm the player is still alive.
        XCTAssertTrue(player.exists,
                      "Player must still exist after landscape ↔ portrait rotation cycle")
    }
}
