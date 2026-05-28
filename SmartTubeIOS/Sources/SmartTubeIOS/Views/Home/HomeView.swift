import SwiftUI
import SmartTubeIOSCore

// MARK: - HomeView
//
// YouTube-style home tab.  A horizontal chip bar at the top lets the user
// switch between every available section:
//   • "Home"  chip  → multi-shelf overview (Subscriptions row,
//                      Recommended row) driven by HomeViewModel.
//   • Any other chip → full-screen video feed for that section driven by a
//                      dedicated BrowseViewModel instance.

public struct HomeView: View {
    @State private var homeVM: HomeViewModel
    @State private var sectionVM: BrowseViewModel
    @Environment(AuthService.self) private var auth
    @Environment(SettingsStore.self) private var store
    @Environment(\.innerTubeAPI) private var api
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    #if os(iOS)
    @Environment(PlayerStateStore.self) private var playerState
    #endif

    // "Home" is always first; its type is .home.
    @State private var selectedSection: BrowseSection = BrowseSection.allSections[0]
    @State private var selectedVideo: Video?
    @State private var selectedPlaylist: Video?
    @State private var shortsPresentation: ShortsPresentation?
    @State private var channelDestination: ChannelDestination?
    @State private var showSignIn = false
    @State private var queueVideosCount: Int = 0
    #if os(tvOS)
    @FocusState private var focusedSection: BrowseSection?
    #endif
    private var visibleSections: [BrowseSection] {
        let types = store.settings.enabledSections
        var all: [BrowseSection] = types.isEmpty
            ? BrowseSection.defaultSections
            : types.compactMap { type in BrowseSection.allSections.first { $0.type == type } }
        // Always keep a "Recommended" chip directly after the "Home" chip so the
        // user can filter to only recommended videos regardless of settings.
        if !all.contains(where: { $0.type == .recommended }),
           let homeIdx = all.firstIndex(where: { $0.type == .home }) {
            all.insert(BrowseSection(type: .recommended), at: homeIdx + 1)
        }
        if store.settings.hideShorts {
            return all.filter { $0.type != .shorts }
        }
        return all
    }

    public init(api: InnerTubeAPI) {
        _homeVM = State(initialValue: HomeViewModel(api: api))
        _sectionVM = State(initialValue: BrowseViewModel(api: api))
    }

    // MARK: - Body

    public var body: some View {
        VStack(spacing: 0) {
            chipBar
            #if !os(tvOS)
            Divider()
            #endif
            contentArea
                #if !os(iOS)
                .navigationDestination(item: $selectedVideo) { video in
                    PlayerView(video: video, api: api)
                }
                #endif
                .navigationDestination(item: $selectedPlaylist) { stub in
                    PlaylistView(playlistId: stub.id, playlistTitle: stub.title, api: api)
                }
                .navigationDestination(item: $channelDestination) { dest in
                    ChannelView(channelId: dest.channelId)
                }
                #if os(tvOS)
                .focusSection()
                #endif
        }
        #if os(iOS)
        // Player cover is centralised in MainTabView; deep-link handled there too.
        .toolbar(.hidden, for: .navigationBar)
        .fullScreenCover(item: $shortsPresentation) { target in
            ShortsPlayerView(videos: target.videos, startIndex: target.startIndex, api: api)
        }
        #endif
        .sheet(isPresented: $showSignIn) { SignInView() }
        .onReceive(NotificationCenter.default.publisher(for: .openChannel)) { note in
            guard let channelId = note.userInfo?["channelId"] as? String, !channelId.isEmpty else { return }
            channelDestination = ChannelDestination(channelId: channelId)
        }
        .onChange(of: visibleSections) { _, newSections in
            if !newSections.contains(selectedSection), let first = newSections.first {
                selectedSection = first
            }
        }
        .task(id: auth.accessToken) {
            await homeVM.updateAuthToken(auth.accessToken)
            await sectionVM.updateAuthToken(auth.accessToken)
        }
        .task(id: selectedSection) {
            if selectedSection.type == .playlists {
                queueVideosCount = await CurrentQueueStore.shared.videos.count
            } else if selectedSection.type != .home {
                // Safety net: if sectionVM somehow fell out of sync with selectedSection
                // (e.g., the chip action raced with an in-flight cancellation, or an
                // @Observable tracking gap left the view empty), force a reload.
                if sectionVM.currentSection != selectedSection {
                    sectionVM.select(section: selectedSection)
                }
            }
        }
    }

    // MARK: - Chip bar

    private var chipBar: some View {
        #if os(tvOS)
        HStack(spacing: 8) {
            ForEach(visibleSections) { section in
                chipButton(section: section)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .focusSection()
        .defaultFocus($focusedSection, selectedSection)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.chipBar")
        #else
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(visibleSections) { section in
                    chipButton(section: section)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .accessibilityIdentifier("home.chipBar")
        #endif
    }

    private func chipButton(section: BrowseSection) -> some View {
        let isSelected = selectedSection == section
        let action = {
            let isNewSection = selectedSection != section
            if isNewSection { selectedSection = section }
            guard section.type != .home else { return }
            if isNewSection {
                sectionVM.select(section: section)
            } else if sectionVM.videoGroups.isEmpty && !sectionVM.isLoading {
                // Same chip re-tapped on an empty section — retry the load.
                // This handles failed fetches or cases where an observation gap
                // left the view showing an empty state despite data being available.
                sectionVM.reload(section: section)
            }
        }
        #if os(tvOS)
        let isFocused = focusedSection == section
        return Button(action: action) {
            Text(section.title)
                .font(.headline)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(
                    (isSelected || isFocused) ? Color.primary : Color.secondary.opacity(0.15),
                    in: Capsule()
                )
                .foregroundStyle(
                    (isSelected || isFocused)
                        ? Color(white: colorScheme == .dark ? 0 : 1)
                        : Color.primary
                )
                .focusEffectDisabled()
        }
        .buttonStyle(.borderless)
        .scaleEffect(isFocused ? 1.12 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: focusedSection)
        .animation(.easeInOut(duration: 0.15), value: selectedSection)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityLabel(section.title)
        .accessibilityIdentifier("chip.\(section.title)")
        .focused($focusedSection, equals: section)
        #else
        return Button(action: action) {
            Text(section.title)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(
                    isSelected ? Color.primary : Color.secondary.opacity(0.15),
                    in: Capsule()
                )
                .foregroundStyle(
                    isSelected
                        ? Color(white: colorScheme == .dark ? 0 : 1)
                        : Color.primary
                )
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.15), value: selectedSection)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        #endif
    }

    // MARK: - Content area

    @ViewBuilder
    private var contentArea: some View {
        if selectedSection.type == .home {
            if auth.isSignedIn {
                homeShelves
            } else {
                homeSignedOutPrompt
            }
        } else if selectedSection.type == .channels {
            channelListFeed
                .accessibilityIdentifier("home.sectionContainer")
        } else {
            sectionFeed
                .accessibilityIdentifier("home.sectionContainer")
        }
    }

    @ViewBuilder
    private var channelListFeed: some View {
        if sectionVM.isLoading && sectionVM.subscribedChannels.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if sectionVM.subscribedChannels.isEmpty && !sectionVM.isLoading {
            feedEmptyState
        } else {
            ChannelListView(channels: sectionVM.subscribedChannels) { channel in
                channelDestination = ChannelDestination(channelId: channel.id)
            }
        }
    }

    private var homeSignedOutPrompt: some View {
        VStack(spacing: 16) {
            Image(systemName: AppSymbol.personCircleQuestion)
                .font(.system(size: 60))
                .foregroundStyle(.secondary)
            Text("Sign in to see your feed")
                .font(.headline)
                .foregroundStyle(.secondary)
            Button("Sign In") { showSignIn = true }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Home shelves  (unified interleaved feed)

    private var homeShelves: some View {
        Group {
            if homeVM.isLoadingAny && homeVM.mergedVideos.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let hideShorts = store.settings.hideShorts
                let regularVideos = homeVM.homeRegularVideos
                let shortsVideos = hideShorts ? [] : homeVM.homeShortsVideos
                // ShortsRowSection is placed OUTSIDE the ScrollView so it stays
                // pinned at the top while the video grid scrolls beneath it.
                VStack(spacing: 0) {
                    if !shortsVideos.isEmpty {
                        ShortsRowSection(
                            videos: shortsVideos,
                            onSelect: { selectVideo($0, from: shortsVideos) },
                            accessibilityID: "home.shortsRow",
                            loadMore: { homeVM.loadNextShortsPage() }
                        )
                        #if os(tvOS)
                        .focusSection()
                        #endif
                        Divider()
                    }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            VideoGridSection(
                                videos: regularVideos,
                                onSelect: { selectVideo($0, from: regularVideos) },
                                loadMore: { homeVM.loadMoreMerged() }
                            )
                            let isLoadingMore = homeVM.sections.contains { $0.isLoadingMore }
                            if isLoadingMore {
                                ProgressView().frame(maxWidth: .infinity).padding()
                            }
                        }
                    }
                    .refreshable { homeVM.load() }
                    #if os(tvOS)
                    .focusSection()
                    #endif
                }
            }
        }
    }

    // MARK: - Section feed  (non-Home chips)

    @ViewBuilder
    private var sectionFeed: some View {
        if sectionVM.isLoading && sectionVM.videoGroups.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if sectionVM.videoGroups.isEmpty && !sectionVM.isLoading {
            feedEmptyState
        } else {
            feedContent
        }
    }

    private var feedContent: some View {
        let hideShorts = store.settings.hideShorts
        let isShorts = selectedSection.type == .shorts
        let applyHideShorts = hideShorts && selectedSection.type != .history

        // Pinned shorts row: shown above the scrollable content for all chips
        // except the Shorts chip itself (which shows a full vertical list instead).
        // For Recommended, use the separately-fetched recommendedShortsVideos so
        // there is no double-counting with the grid below.
        // For all other chips, extract any shorts that appear in the video groups.
        let pinnedShorts: [Video]
        if isShorts || applyHideShorts {
            pinnedShorts = []
        } else if selectedSection.type == .recommended {
            pinnedShorts = sectionVM.recommendedShortsVideos
        } else {
            pinnedShorts = sectionVM.videoGroups.flatMap(\.videos).filter(\.isShort)
        }

        let rowGroups: [VideoGroup] = sectionVM.videoGroups.filter { $0.layout == .row }.map { g in
            guard applyHideShorts else { return g }
            var copy = g
            copy.videos = g.videos.filter { !$0.isShort }
            return copy
        }
        // For non-Shorts chips, exclude shorts from the grid — they appear in the
        // pinned row above. For the Shorts chip itself, keep all videos.
        // VStack (not LazyVStack) is required here. LazyVGrid inside LazyVStack
        // collapses to zero height — grid items become invisible and non-tappable
        // because LazyVStack never provides a measured height to LazyVGrid.
        // Row groups are few (typically ≤15 carousels) so eager rendering is fine.
        let gridVideos = sectionVM.videoGroups.filter { $0.layout != .row }
            .flatMap(\.videos)
            .filter { !applyHideShorts || !$0.isShort }
            .filter { isShorts || !$0.isShort }

        // The raw last video of the last group is the canonical pagination trigger for
        // loadMoreIfNeeded — it checks membership in videoGroups.last, so passing a
        // filtered (non-short) video won't match if the last group is all-shorts.
        // Both the shorts row and the grid use this as their loadMore trigger so
        // either reaching the end of the shorts row OR scrolling to the bottom of
        // the main content independently triggers the next page load.
        let paginationTrigger: Video? = sectionVM.videoGroups.last?.videos.last

        return VStack(spacing: 0) {
            // Pinned ShortsRowSection — outside the ScrollView so it stays fixed
            // at the top while the video content below scrolls.
            if !pinnedShorts.isEmpty {
                ShortsRowSection(
                    videos: pinnedShorts,
                    onSelect: { selectVideo($0, from: pinnedShorts) },
                    accessibilityID: selectedSection.type == .recommended
                        ? "recommended.shortsRow"
                        : "browse.shortsRow",
                    loadMore: {
                        // Trigger from the shorts row: fires when the last short card
                        // becomes visible. Uses paginationTrigger (last raw video) so
                        // the loadMoreIfNeeded membership check always succeeds.
                        if let last = paginationTrigger {
                            sectionVM.loadMoreIfNeeded(lastVideo: last)
                        }
                    }
                )
                #if os(tvOS)
                .focusSection()
                #endif
                Divider()
            }
            if isShorts {
                // Shorts chip: vertical portrait card list driven by ShortsRowSection's
                // internal ScrollView. frame(maxHeight: .infinity) ensures the internal
                // ScrollView gets the full remaining height rather than sizing to content.
                let shortsVideos = sectionVM.videoGroups.flatMap(\.videos)
                ShortsRowSection(
                    videos: shortsVideos,
                    onSelect: { selectVideo($0, from: shortsVideos) },
                    accessibilityID: "shorts.section",
                    loadMore: {
                        if let last = paginationTrigger {
                            sectionVM.loadMoreIfNeeded(lastVideo: last)
                        }
                    },
                    scrollAxis: .vertical
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                #if os(tvOS)
                .focusSection()
                #endif
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if selectedSection.type == .playlists, queueVideosCount > 0 {
                            currentQueueRow
                        }
                        ForEach(rowGroups) { group in
                            if let title = group.title, !title.isEmpty {
                                Text(title)
                                    .font(.headline)
                                    .padding(.horizontal)
                                    .padding(.top, 16)
                                    .padding(.bottom, 4)
                            }
                            VideoRowSection(videos: group.videos, onSelect: { selectVideo($0, from: group.videos) })
                        }
                        if !gridVideos.isEmpty {
                            VideoGridSection(
                                videos: gridVideos,
                                onSelect: { selectVideo($0, from: gridVideos) },
                                loadMore: {
                                    // Trigger from the main grid: fires when the last
                                    // visible grid card appears. Uses paginationTrigger
                                    // (raw last video) so the check succeeds even when
                                    // the last group is all-shorts (gridVideos.last
                                    // would be from an earlier group in that case).
                                    if let last = paginationTrigger {
                                        sectionVM.loadMoreIfNeeded(lastVideo: last)
                                    }
                                }
                            )
                        }
                        if sectionVM.isLoading {
                            ProgressView().frame(maxWidth: .infinity).padding()
                        }
                    }
                }
                .accessibilityIdentifier("home.sectionFeed")
                .refreshable { sectionVM.loadContent(refresh: true) }
                #if os(tvOS)
                .focusSection()
                #endif
            }
        }
        .onChange(of: sectionVM.videoGroups.flatMap(\.videos).count) { _, _ in
            // After each page load, check whether the newly appended page contained
            // videos of the type each visible section needs. If not, auto-trigger
            // another page so both the pinned shorts row and the grid can fill up.
            //
            // This handles the common case where the API returns a page that is
            // entirely shorts (grid gets nothing new) or entirely regular videos
            // (pinned row gets nothing new).
            //
            // loadMoreIfNeeded's own guards (nextPageToken, isLoadingMore) prevent
            // runaway loops — pagination stops when pages are exhausted or one is
            // already in flight.
            let isShortsSectionActive = selectedSection.type == .shorts
            let applyHide = store.settings.hideShorts && selectedSection.type != .history
            guard !isShortsSectionActive,
                  !applyHide,
                  let trigger = sectionVM.videoGroups.last?.videos.last
            else { return }

            let lastPageVideos = sectionVM.videoGroups.last?.videos ?? []
            let lastPageHasShorts    = lastPageVideos.contains { $0.isShort }
            let lastPageHasNonShorts = lastPageVideos.contains { !$0.isShort }

            // Last page was all-non-shorts → pinned row got no new cards → re-trigger.
            // Last page was all-shorts → grid got no new cards → re-trigger.
            // If the page had both types, both sections grew — no re-trigger needed.
            if !lastPageHasShorts || !lastPageHasNonShorts {
                sectionVM.loadMoreIfNeeded(lastVideo: trigger)
            }
        }
    }

    @ViewBuilder private var currentQueueRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "list.number")
                .font(.title2)
                .frame(width: 44, height: 44)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Current Queue")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
                Text("\(queueVideosCount) video\(queueVideosCount == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture {
            selectedPlaylist = Video(
                id: CurrentQueueStore.playlistID,
                title: "Current Queue",
                channelTitle: ""
            )
        }
        .accessibilityIdentifier("home.currentQueueRow")
        Divider().padding(.horizontal)
    }

    private var feedEmptyState: some View {
        VStack(spacing: 16) {
            if sectionVM.isAuthRequired && !auth.isSignedIn {
                Image(systemName: AppSymbol.personCircleWarning)
                    .font(.system(size: 60))
                    .foregroundStyle(.secondary)
                Text("Sign in to see this section")
                    .font(.title3)
                Text("Your Google account is required.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Sign In") { showSignIn = true }
                    .buttonStyle(.borderedProminent)
            } else if !auth.isSignedIn && (selectedSection.type == .subscriptions || selectedSection.type == .channels) {
                Image(systemName: "person.badge.plus")
                    .font(.system(size: 60))
                    .foregroundStyle(.secondary)
                Text("Follow channels to see their latest videos here")
                    .font(.title3)
                    .multilineTextAlignment(.center)
                Text("Search for a channel and tap Follow.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("Search") {
                    NotificationCenter.default.post(name: .navigateToSearch, object: nil)
                }
                .buttonStyle(.borderedProminent)
            } else {
                Image(systemName: AppSymbol.tvPlay)
                    .font(.system(size: 60))
                    .foregroundStyle(.secondary)
                Text("Nothing here yet")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Button("Refresh") { sectionVM.loadContent(refresh: true) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Video selection

    private func selectVideo(_ video: Video, from groupVideos: [Video]) {
        if video.playlistId == video.id {
            selectedPlaylist = video
        } else if video.isShort {
            #if os(iOS)
            let shorts = groupVideos.filter { $0.isShort }
            let idx = shorts.firstIndex(where: { $0.id == video.id }) ?? 0
            shortsPresentation = ShortsPresentation(videos: shorts, startIndex: idx)
            #else
            selectedVideo = video
            #endif
        } else {
            #if os(iOS)
            playerState.play(video: video)
            #else
            selectedVideo = video
            #endif
        }
    }
}
