import SwiftUI

/// The app shell: an iOS 26 Liquid Glass `TabView` with a bottom-accessory mini player floating
/// above the tab bar (Apple Music-style), and a `.search` role tab so search lives in the thumb
/// zone. Tapping the mini player presents the full Now Playing screen.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(PlaybackController.self) private var player
    @State private var showNowPlaying = false
    @State private var selection: AppTab = .home

    var body: some View {
        // The accessory is attached unconditionally: swapping between `tabs` and
        // `tabs.tabViewBottomAccessory{}` when playback starts changes the view's structural
        // identity, which rebuilds the whole TabView — every NavigationStack pops to root and
        // the teardown mid-tap crashes (seen on device, 2026-07-04). The mini player renders a
        // "Not Playing" state instead (Apple Music does the same), which also avoids the
        // blank-capsule artifact that conditional attachment was originally working around.
        // No tabBarMinimizeBehavior: the minimized bar's floating pill stops insetting the
        // scroll content, so list bottoms hide underneath it.
        tabs
            .tabViewBottomAccessory {
                MiniPlayerView { if player.hasContent { showNowPlaying = true } }
            }
            .sheet(isPresented: $showNowPlaying) {
                NowPlayingView()
            }
    }

    private var tabs: some View {
        TabView(selection: $selection) {
            Tab("Home", systemImage: "house.fill", value: AppTab.home) {
                HomeView().miniPlayerClearance()
            }
            Tab("Browse", systemImage: "square.stack.3d.up.fill", value: AppTab.browse) {
                BrowseView().miniPlayerClearance()
            }
            Tab(value: AppTab.search, role: .search) {
                SearchView(selectedTab: selection).miniPlayerClearance()
            }
        }
    }
}

enum AppTab: Hashable { case home, browse, search }

extension View {
    /// iOS 27 (beta, on Ellie's phone) stopped propagating the tabViewBottomAccessory height
    /// into the bottom safe area, so scroll content hides under the mini player pill — iOS 26
    /// insets correctly, which is why the simulator never showed the overlap. Explicit bottom
    /// clearance for every scrollable in the tab, gated to 27+ so 26 doesn't double-inset.
    /// Applied per-tab (not on the TabView) so presented sheets don't inherit the margin.
    @ViewBuilder func miniPlayerClearance() -> some View {
        if #available(iOS 27, *) {
            contentMargins(.bottom, 72, for: .scrollContent)
        } else {
            self
        }
    }
}
