import SwiftUI

/// Home tab (Idea #8): configurable hotlinks in the thumb zone. The whole screen is one viewport
/// tall with the hotlink grid pinned to the bottom, near the tab bar, so the most-used
/// destinations are reachable one-handed — no large-title collapse, no dead scroll. The content
/// frame tracks the safe area, so when the mini-player accessory appears the grid moves up with
/// it instead of being covered. A live-status line shows connection/cache state without ever
/// blocking the view.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(LibraryStore.self) private var library

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        header
                        hotlinks
                    }
                    .padding(.horizontal, CratesMetrics.gutter)
                    .padding(.bottom, 8)
                    .frame(minHeight: proxy.size.height, alignment: .bottom)
                    .frame(maxWidth: .infinity)
                }
                .defaultScrollAnchor(.bottom) // bottom-first ergonomics (Idea #8)
            }
            .navigationTitle("Crates")
            .toolbarTitleDisplayMode(.inline)
            .background(CratesColor.background)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { SettingsView() } label: { Image(systemName: "gearshape") }
                }
            }
            .refreshable { await library.refreshRoot()?.value }
            .onAppear { library.refreshRoot() }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(model.isDemo ? "Demo Library" : "Your Library")
                .font(.headline)
            Spacer()
            HStack(spacing: 6) {
                StatusDot(state: library.rootState)
                Text(statusLine)
                    .font(.caption)
                    .foregroundStyle(CratesColor.textSecondary)
            }
        }
    }

    private var statusLine: String {
        if model.isDemo { return "Sample data" }
        switch library.rootState {
        case .idle: return "Ready"
        case .revalidating: return "Updating…"
        case .live: return "Up to date"
        case .failed: return "Cached · pull to retry"
        }
    }

    /// Six configurable hotlinks. In the POC these are the top crates + fixed entries; a real
    /// build lets the user pin any crate/search/playlist here.
    private var hotlinks: some View {
        let pinned = Array(library.rootCrates.prefix(6))
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            ForEach(pinned) { crate in
                NavigationLink { CrateDetailView(crate: crate) } label: {
                    HotlinkTile(crate: crate)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// A quiet, flat surface tile — symbol and count on top, name at the bottom. No border stroke and
/// no icon chip; the large continuous radius echoes the Liquid Glass chrome without imitating it
/// (HIG reserves glass for floating controls, so this stays a content-layer surface).
struct HotlinkTile: View {
    let crate: Crate
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                Image(systemName: crate.symbol)
                    .font(.title3.weight(.medium))
                    .foregroundStyle(CratesColor.accent)
                Spacer()
                if let n = crate.tuneCount {
                    Text("\(n)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(CratesColor.textSecondary)
                }
            }
            Spacer(minLength: 8)
            Text(crate.name)
                .font(.callout.weight(.semibold))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
        .background(CratesColor.surface, in: .rect(cornerRadius: 22, style: .continuous))
    }
}

struct StatusDot: View {
    let state: LoadState
    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8)
    }
    private var color: Color {
        switch state {
        case .idle: CratesColor.textSecondary
        case .revalidating: CratesColor.gold
        case .live: CratesColor.green
        case .failed: CratesColor.red
        }
    }
}
