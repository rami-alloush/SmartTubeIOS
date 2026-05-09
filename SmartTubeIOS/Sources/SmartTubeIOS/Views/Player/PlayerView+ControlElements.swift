import SwiftUI
import SmartTubeIOSCore

// MARK: - Slide transition + individual control element views
//
// Extracted from PlayerView.swift to keep that file under 1 000 lines.
// All members are `internal` (no access modifier) so PlayerView's `body`
// and controlsOverlay() can call them across the file boundary.

extension PlayerView {

    // MARK: - Slide transition

    /// Animates the current content off-screen in `direction` (-1 = left, +1 = right),
    /// runs `action` to load the next/previous video, then slides the new content in
    /// from the opposite side.
    func performHorizontalTransition(direction: CGFloat, screenWidth: CGFloat, action: @escaping () -> Void) {
        // Set the re-entry guard synchronously so any concurrent gesture event
        // arriving before the Task runs still sees isTransitioning == true.
        isTransitioning = true
        // Defer ALL SwiftUI state mutations (incl. the initial slide-out animation)
        // into the async Task so none of them execute synchronously inside UIKit's
        // touch-event delivery pass. On iOS 26 the UpdateCycle framework throws when
        // @Observable/@State mutations happen synchronously during event dispatch.
        Task { @MainActor in
            withAnimation(.easeIn(duration: 0.2)) {
                slideOffset = direction * screenWidth
            }
            try? await Task.sleep(for: .milliseconds(220))
            action()                                        // load new video, clears AVPlayer
            slideOffset = -direction * screenWidth          // snap to opposite side (off-screen)
            withAnimation(.easeOut(duration: 0.25)) {
                slideOffset = 0                             // slide new content in
            }
            try? await Task.sleep(for: .milliseconds(270))
            isTransitioning = false
        }
    }

    // MARK: - Play / Pause

    var playPauseButton: some View {
        Button { vm.togglePlayPause() } label: {
            Image(systemName: vm.isPlaying ? "pause.fill" : "play.fill")
                // .original preserves the white foreground on tvOS even when the focus
                // engine or button state tries to apply a system tint colour.
                .renderingMode(.original)
                .font(.system(size: 42 * controlScale))
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        #if os(tvOS)
        .focusable(false)
        .scaleEffect(highlightedControl == .playPause ? 1.6 : 1.0)
        .shadow(color: highlightedControl == .playPause ? .white.opacity(0.65) : .clear, radius: 8)
        .animation(.easeInOut(duration: 0.15), value: highlightedControl)
        #endif
        .accessibilityIdentifier("player.playPauseButton")
    }

    // MARK: - Seek buttons

    func seekButton(symbol: String, seconds: TimeInterval, tvHighlighted: Bool = false) -> some View {
        Button { vm.seekRelative(seconds: seconds) } label: {
            Image(systemName: symbol)
                // .original preserves the white foreground on tvOS — prevents system
                // tinting from turning the icon into a white rectangle when highlighted.
                .renderingMode(.original)
                .font(.system(size: 28 * controlScale))
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        #if os(tvOS)
        .focusable(false)
        .scaleEffect(tvHighlighted ? 1.55 : 1.0)
        .shadow(color: tvHighlighted ? .white.opacity(0.6) : .clear, radius: 7)
        .animation(.easeInOut(duration: 0.15), value: tvHighlighted)
        #endif
    }

    // MARK: - Progress bar

    var progressBar: some View {
        #if os(tvOS)
        tvProgressBar
        #else
        iosProgressBar
        #endif
    }

    var iosProgressBar: some View {
        VStack(spacing: 4) {
            // Tooltip row — always occupies space so layout doesn't jump
            GeometryReader { geo in
                if vm.isScrubbing && vm.duration > 0 {
                    let hPad: CGFloat = 20
                    let trackW = geo.size.width - hPad * 2
                    let fraction = CGFloat(vm.scrubTime / vm.duration)
                    let thumbX = hPad + trackW * fraction
                    let chapterAtScrub = vm.chapters.last(where: { $0.startTime <= vm.scrubTime })
                    let labelW: CGFloat = chapterAtScrub != nil ? min(geo.size.width * 0.5, 180) : 64
                    let clampedX = min(max(thumbX, hPad + labelW / 2), geo.size.width - hPad - labelW / 2)

                    VStack(spacing: 2) {
                        if let chapter = chapterAtScrub {
                            Text(chapter.title)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.white.opacity(0.85))
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        Text(formatDuration(vm.scrubTime))
                            .font(.caption.monospacedDigit())
                            .fontWeight(.semibold)
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 6))
                    .frame(width: labelW)
                    .position(x: clampedX, y: geo.size.height / 2)
                }
            }
            .frame(height: 28)

            // Track + slider row (custom — fully transparent thumb and track)
            GeometryReader { geo in
                let hPad: CGFloat = 20
                let trackW = geo.size.width - hPad * 2
                let time = vm.isScrubbing ? vm.scrubTime : vm.currentTime
                let progress = vm.duration > 0 ? CGFloat(time / vm.duration) : 0
                let thumbX = hPad + trackW * progress

                ZStack {
                    // Background track
                    Capsule()
                        .fill(Color.white.opacity(0.2))
                        .frame(height: 4)
                        .padding(.horizontal, hPad)

                    // Progress fill
                    HStack(spacing: 0) {
                        Capsule()
                            .fill(Color.red.opacity(0.5))
                            .frame(width: max(thumbX - hPad, 0), height: 4)
                        Spacer(minLength: 0)
                    }
                    .padding(.leading, hPad)

                    // Thumb
                    Circle()
                        .fill(Color.white.opacity(0.5))
                        .frame(width: 16, height: 16)
                        .position(x: thumbX, y: geo.size.height / 2)
                }
                .overlay(sponsorBlockMarkers)
                .overlay(chapterMarkers)
                .contentShape(Rectangle())
                #if !os(tvOS)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let fraction = min(max((value.location.x - hPad) / trackW, 0), 1)
                            if !vm.isScrubbing { vm.beginScrubbing() }
                            vm.updateScrub(to: Double(fraction) * vm.duration)
                        }
                        .onEnded { _ in vm.commitScrub() }
                )
                #endif
            }
            .frame(height: 28)
        }
    }

    // Chapter tick marks on the progress bar — small white notches at each chapter boundary.
    // Each tick has a 24×44 pt transparent tap area so the user can tap to jump to it.
    var chapterMarkers: some View {
        GeometryReader { geo in
            ForEach(vm.chapters) { chapter in
                let x = geo.size.width * CGFloat(chapter.startTime / max(vm.duration, 1))
                ZStack {
                    // Invisible enlarged hit area
                    Color.clear
                        .frame(width: 24, height: 44)
                    // Visible tick
                    Rectangle()
                        .fill(Color.white.opacity(0.85))
                        .frame(width: 2, height: 12)
                }
                .contentShape(Rectangle())
                .onTapGesture { vm.seek(to: chapter.startTime) }
                .position(x: x, y: geo.size.height / 2)
            }
        }
    }

    // SponsorBlock segment markers on the progress bar
    var sponsorBlockMarkers: some View {
        GeometryReader { geo in
            ForEach(vm.sponsorSegments) { seg in
                let x = geo.size.width * CGFloat(seg.start / max(vm.duration, 1))
                let w = geo.size.width * CGFloat((seg.end - seg.start) / max(vm.duration, 1))
                Rectangle()
                    .fill(seg.category.color.opacity(0.8))
                    .frame(width: max(w, 2), height: 4)
                    .position(x: x + w / 2, y: geo.size.height / 2)
            }
        }
    }

    // MARK: - Toast / error

    var sponsorSkipToast: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                if let seg = vm.currentToastSegment {
                    Button("Skip \(seg.category.displayName)") {
                        vm.skipToastSegment()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(seg.category.color)
                    .padding()
                    .transition(.move(edge: .trailing))
                }
            }
        }
        .animation(.easeInOut, value: vm.currentToastSegment?.id)
    }

    func errorBanner(_ err: Error) -> some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: AppSymbol.warning)
                    .foregroundStyle(.yellow)
                Text(err.localizedDescription)
                    .font(.callout)
                    .foregroundStyle(.white)
            }
            Button {
                vm.retryLoad()
            } label: {
                Text("Try Again")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .background(Color.white)
                    .clipShape(Capsule())
            }
            .accessibilityIdentifier("player.retryButton")
        }
        .padding()
        .background(.black.opacity(0.75))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding()
        .accessibilityIdentifier("player.errorBanner")
    }
}
