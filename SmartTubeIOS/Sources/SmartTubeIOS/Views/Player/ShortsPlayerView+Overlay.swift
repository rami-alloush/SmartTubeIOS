import SwiftUI
import SmartTubeIOSCore

extension ShortsPlayerView {

    // MARK: - Always-visible index badge
    //
    // Rendered outside the ZStack (as an .overlay on the body) so UIViewRepresentable
    // elements inside the ZStack cannot absorb it from the accessibility tree.

    var indexBadge: some View {
        Text("\(currentIndex + 1) / \(videos.count)")
            .font(.caption)
            .foregroundStyle(.white.opacity(0.8))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.black.opacity(0.4))
            .clipShape(Capsule())
            .accessibilityIdentifier("shorts.indexLabel")
            .padding(.top, 12)
            .padding(.trailing, 20)
    }

    // MARK: - Pause indicator
    //
    // Visual-only indicator shown while paused — confirms the paused state since
    // controls=0 removes YouTube's native pause icon. No tap gesture: the ZStack's
    // onTapGesture (ShortsPlayerView.swift) handles play/pause for the whole frame,
    // so every tap toggles play/pause regardless of where the user taps.
    // allowsHitTesting(false) ensures touches fall through to the ZStack.

    #if os(iOS)
    var pauseIndicator: some View {
        Group {
            if !vm.isPlaying && !vm.videoEnded {
                Image(systemName: "play.fill")
                    .font(.system(size: 38, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 68, height: 68)
                    .background(.ultraThinMaterial)
                    .clipShape(Circle())
                    .accessibilityHidden(true)
                    .transition(.opacity.combined(with: .scale(scale: 0.88)))
            }
        }
        .animation(.easeOut(duration: 0.15), value: vm.isPlaying || vm.videoEnded)
        .allowsHitTesting(false)
    }
    #endif

    // MARK: - Overlay

    var shortsOverlay: some View {
        VStack(spacing: 0) {
            // Top bar: back + index indicator
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: AppSymbol.chevronLeft)
                        .font(.title2)
                        .foregroundStyle(.white)
                        .padding(12)
                        .background(.black.opacity(0.4))
                        .clipShape(Circle())
                }
                .accessibilityIdentifier("shorts.backButton")
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)

            Spacer()
        }
        // Tapping the overlay background (outside the back button) toggles
        // play/pause — this is the primary unpause path when the video is paused
        // and the controls overlay is visible. The back button above intercepts
        // its own tap so it is NOT forwarded to this gesture.
        #if os(iOS)
        .onTapGesture { vm.togglePlayPause() }
        #endif
        // Make the whole overlay (including the transparent Spacer regions)
        // hit-testable for the DragGesture below — otherwise SwiftUI only
        // hit-tests the non-transparent back button / index area, and swipes
        // over empty space fall through to the WKWebView untouched.
        .contentShape(Rectangle())
        // Allow swipe navigation even when the controls overlay is on screen.
        // .simultaneousGesture fires alongside button taps so controls remain
        // interactive while vertical swipes still drive Shorts navigation.
        #if !os(tvOS)
        .simultaneousGesture(
            DragGesture(minimumDistance: 50, coordinateSpace: .global)
                .onEnded { value in
                    guard !isTransitioning else { return }
                    let dy = value.translation.height
                    guard abs(dy) > abs(value.translation.width) else { return }
                    if dy < 0 {
                        if let next = ShortsNavigation.targetIndex(
                            vertical: -100, horizontal: 0,
                            current: currentIndex, count: videos.count
                        ) { performVerticalTransition(direction: -1) { goTo(next) } }
                        else { withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { slideOffset = 0 } }
                    } else {
                        if let prev = ShortsNavigation.targetIndex(
                            vertical: 100, horizontal: 0,
                            current: currentIndex, count: videos.count
                        ) { performVerticalTransition(direction: 1) { goTo(prev) } }
                        else { loadMoreAtStart() }
                    }
                }
        )
        #endif
    }
}
