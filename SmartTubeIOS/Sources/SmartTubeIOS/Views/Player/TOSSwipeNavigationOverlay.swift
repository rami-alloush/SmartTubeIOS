import SwiftUI
import os
#if canImport(UIKit)
import UIKit
#endif

private let swipeLog = Logger(subsystem: "com.void.smarttube.app", category: "TOSSwipe")

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
            // The recognizer is re-homed onto the UIWindow via PassthroughGestureView.
            // gestureRecognizer.view IS the window, so .window returns nil — use the
            // view directly instead.
            let window = (gestureRecognizer.view as? UIWindow) ?? gestureRecognizer.view?.window
            guard let window else { return true }
            let y = touch.location(in: window).y
            let fraction = parent.verticalActivationFraction
            let accept = y <= window.bounds.height * fraction
            swipeLog.debug("[shouldReceive] y=\(Int(y)) height=\(Int(window.bounds.height)) fraction=\(fraction, format: .fixed(precision: 2)) → \(accept ? "accept" : "reject")")
            return accept
        }

        @MainActor @objc func handlePan(_ gr: UIPanGestureRecognizer) {
            let t = gr.translation(in: gr.view)
            swipeLog.notice("[handlePan] state=\(gr.state.rawValue) tx=\(Int(t.x)) ty=\(Int(t.y))")
            guard gr.state == .ended else { return }
            guard abs(t.x) > minDistance, abs(t.x) > abs(t.y) else {
                swipeLog.notice("[handlePan] ended — ignored (tx=\(Int(t.x)) ty=\(Int(t.y)) minDist=\(Int(self.minDistance)))")
                return
            }
            let dir = t.x < 0 ? "LEFT" : "RIGHT"
            swipeLog.notice("[handlePan] swipe \(dir) confirmed (tx=\(Int(t.x)))")
            if t.x < 0 {
                parent.onSwipeLeft()
            } else {
                parent.onSwipeRight()
            }
        }
    }
}
#endif
