import SwiftUI

// MARK: - ScrollOffsetPreferenceKey

/// Reports the current vertical scroll offset from inside a `ScrollView`.
/// Use by placing a zero-height `GeometryReader` inside the ScrollView's content and
/// reading changes via `.onPreferenceChange(ScrollOffsetPreferenceKey.self)`.
struct ScrollOffsetPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

// MARK: - ScrollOffsetRestorer

/// A zero-size `UIViewRepresentable` that restores the scrollable offset of the nearest
/// ancestor `UIScrollView` once, then calls `onComplete`.
///
/// Always keep this view in the content (don't add/remove conditionally — that would
/// trigger a layout recalculation that resets `contentOffset`). Pass `nil` when no
/// restore is needed; the view becomes a no-op.
///
/// ```swift
/// // In the ScrollView content (unconditionally):
/// ScrollOffsetRestorer(targetOffset: restoreOffset) { restoreOffset = nil }
///     .frame(width: 0, height: 0)
/// ```
// MARK: - ScrollOffsetStore

/// Reference-type container that holds the current vertical scroll offset,
/// updated via KVO without triggering SwiftUI re-renders on every scroll tick.
final class ScrollOffsetStore {
    var currentOffset: CGFloat = 0
}

// MARK: - ScrollOffsetReader

/// A zero-size `UIViewRepresentable` that attaches a KVO observer to the
/// nearest ancestor `UIScrollView` and writes real-time `contentOffset.y`
/// into a `ScrollOffsetStore`. Using a reference type avoids SwiftUI
/// re-renders on every scroll frame.
///
/// Place unconditionally inside the `ScrollView` content so the view is
/// always in the hierarchy.
///
/// ```swift
/// @State private var scrollStore = ScrollOffsetStore()
///
/// ScrollView {
///     ScrollOffsetReader(store: scrollStore).frame(width: 0, height: 0)
///     // … content …
/// }
/// ```
#if os(iOS) || os(tvOS)
struct ScrollOffsetReader: UIViewRepresentable {
    let store: ScrollOffsetStore

    func makeCoordinator() -> Coordinator { Coordinator(store: store) }

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.isHidden = true
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.attach(to: uiView)
    }

    final class Coordinator: NSObject {
        let store: ScrollOffsetStore
        private weak var scrollView: UIScrollView?
        private var observation: NSKeyValueObservation?

        init(store: ScrollOffsetStore) { self.store = store }

        func attach(to view: UIView) {
            // Re-attach only when scrollView was deallocated or never set.
            guard scrollView == nil else { return }
            var cursor: UIView? = view.superview
            while let current = cursor {
                if let sv = current as? UIScrollView {
                    scrollView = sv
                    observation = sv.observe(\.contentOffset, options: .new) { [weak self] sv, _ in
                        // Intentionally NOT dispatching to main — contentOffset KVO
                        // already fires on the main thread during UIKit scroll events.
                        self?.store.currentOffset = sv.contentOffset.y
                    }
                    return
                }
                cursor = current.superview
            }
        }

        deinit { observation?.invalidate() }
    }
}
#endif

// MARK: - ScrollOffsetRestorer

#if os(iOS) || os(tvOS)
struct ScrollOffsetRestorer: UIViewRepresentable {
    /// Desired `contentOffset.y`. Pass `nil` to do nothing.
    let targetOffset: CGFloat?
    let onComplete: () -> Void

    func makeUIView(context: Context) -> UIView {
        UIView()  // zero-size, hidden
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        guard let offset = targetOffset else { return }
        // Defer past the current SwiftUI layout commit AND any UIKit navigation
        // pop animation, so contentSize is finalised and contentOffset is stable.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            var current: UIView? = uiView.superview
            while let view = current {
                if let sv = view as? UIScrollView {
                    // With a VStack (all items rendered) contentSize is already full;
                    // no clamping needed — but guard against negative offset.
                    let y = max(offset, 0)
                    sv.setContentOffset(CGPoint(x: 0, y: y), animated: false)
                    self.onComplete()
                    return
                }
                current = view.superview
            }
        }
    }
}
#endif
