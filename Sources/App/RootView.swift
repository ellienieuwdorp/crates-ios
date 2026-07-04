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
        // The accessory must be attached conditionally: an empty @ViewBuilder result still
        // renders a blank glass capsule above the tab bar.
        Group {
            if player.hasContent {
                tabs.tabViewBottomAccessory {
                    MiniPlayerView { showNowPlaying = true }
                }
            } else {
                tabs
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .sheet(isPresented: $showNowPlaying) {
            NowPlayingView()
        }
    }

    private var tabs: some View {
        TabView(selection: $selection) {
            Tab("Home", systemImage: "house.fill", value: AppTab.home) {
                HomeView()
            }
            Tab("Browse", systemImage: "square.stack.3d.up.fill", value: AppTab.browse) {
                BrowseView()
            }
            Tab(value: AppTab.search, role: .search) {
                SearchView()
            }
        }
    }
}

enum AppTab: Hashable { case home, browse, search }
