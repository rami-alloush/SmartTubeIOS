#if os(iOS)
import UIKit
import SmartTubeIOS

/// Provides the per-screen orientation mask that UIKit queries on every
/// orientation-change event. Returns `.allButUpsideDown` so that
/// `UIWindowScene.requestGeometryUpdate` can successfully request landscape
/// when the player opens and portrait when it closes. Proactive
/// portrait↔landscape transitions are managed by `OrientationManager`.
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        // Return .allButUpsideDown at all times so that:
        // 1. UIKit's intersection with the view controller hierarchy does not
        //    restrict to portrait-only while the full-screen player cover is
        //    being presented (PresentationHostingController caches the supported
        //    mask at creation time, before PlayerView.onAppear fires).
        // 2. OrientationManager.requestGeometryUpdate can successfully request
        //    landscape when the player opens and portrait when it closes.
        // Proactive portrait↔landscape transitions are still managed by
        // OrientationManager via UIWindowScene.requestGeometryUpdate.
        .allButUpsideDown
    }
}
#endif
