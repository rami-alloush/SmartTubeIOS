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
            .padding(.top, 60)
            .padding(.trailing, 20)
    }

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
            .padding(.top, 60)

            Spacer()

            // Bottom section: navigation hints + title + play-pause
            VStack(spacing: 8) {
                if currentIndex > 0 {
                    Image(systemName: AppSymbol.chevronUp)
                        .foregroundStyle(.white.opacity(0.5))
                        .font(.caption)
                }

                HStack(alignment: .bottom, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        #if os(iOS)
                        Text(currentVideo.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                        let channelId = currentVideo.channelId
                        let channelTitle = currentVideo.channelTitle
                        #else
                        Text(vm.playerInfo?.video.title ?? currentVideo.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                        let channelId = vm.playerInfo?.video.channelId ?? currentVideo.channelId
                        let channelTitle = vm.playerInfo?.video.channelTitle ?? currentVideo.channelTitle
                        #endif
                        Button {
                            guard let cid = channelId, !cid.isEmpty else { return }
                            channelDestination = ChannelDestination(channelId: cid)
                        } label: {
                            Text(channelTitle)
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.8))
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                        .disabled(channelId == nil || channelId?.isEmpty == true)
                        .accessibilityIdentifier("shorts.channelButton")
                    }
                    Spacer()
                    Button { vm.togglePlayPause() } label: {
                        Image(systemName: vm.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(.white)
                            .padding(12)
                            .background(.black.opacity(0.4))
                            .clipShape(Circle())
                    }
                }
                .padding(.horizontal, 20)

                if currentIndex < videos.count - 1 {
                    Image(systemName: AppSymbol.chevronDown)
                        .foregroundStyle(.white.opacity(0.5))
                        .font(.caption)
                }
            }
            .padding(.bottom, 40)
            .background(
                LinearGradient(
                    colors: [.clear, .black.opacity(0.65)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 200)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)
            )
        }
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
