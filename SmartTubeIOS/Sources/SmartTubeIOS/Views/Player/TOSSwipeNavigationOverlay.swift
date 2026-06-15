import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - TOSSwipeNavigationOverlay
//
// Horizontal swipe-left/right navigation for the TOS (WKWebView) player —
// mirrors PlayerSwipeGestureOverlay's left/right behaviour for the AVPlayer
// pipeline (PlayerView+AVLayer.swift: left → playNext(), right → playPrevious()).
//
// Reuses PassthroughGestureView (SwipeGestureOverlay.swift) so the pan gesture
// recognizer is re-homed onto the window and never blocks touches to the
// WKWebView's own controls. To avoid stealing YouTube's native bottom
// scrubber/control-bar drag (which also uses horizontal pans for seeking),
// `gestureRecognizer(_:shouldReceive:)` only accepts touches starting in the
// top `verticalActivationFraction` of the screen.

#if os(iOS)
struct TOSSwipeNavigationOverlay: UIViewRepresentable {
    var onSwipeLeft: () -> Void
    var onSwipeRight: () -> Void
    var isEnabled: Bool = true
    /// Touches below this fraction of the screen height are ignored, leaving
    /// YouTube's bottom scrubber/control-bar free to handle horizontal drags.
    var verticalActivationFraction: CGFloat = 0.75

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> PassthroughGestureView {
        let view = PassthroughGestureView()
        view.backgroundColor = .clear

        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        pan.cancelsTouchesInView = false
        pan.delegate = context.coordinator
        context.coordinator.pan = pan

        view.managedGestureRecognizers = [pan]
        return view
    }

    func updateUIView(_ uiView: PassthroughGestureView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.pan?.isEnabled = isEnabled
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: TOSSwipeNavigationOverlay
        weak var pan: UIPanGestureRecognizer?
        private let minDistance: CGFloat = 40

        init(_ parent: TOSSwipeNavigationOverlay) {
            self.parent = parent
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                                shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let window = gestureRecognizer.view?.window else { return true }
            let y = touch.location(in: window).y
            return y <= window.bounds.height * parent.verticalActivationFraction
        }

        @MainActor @objc func handlePan(_ gr: UIPanGestureRecognizer) {
            guard gr.state == .ended else { return }
            let t = gr.translation(in: gr.view)
            guard abs(t.x) > minDistance, abs(t.x) > abs(t.y) else { return }
            if t.x < 0 {
                parent.onSwipeLeft()
            } else {
                parent.onSwipeRight()
            }
        }
    }
}
#endif
