import SwiftUI

/// Home tab (Idea #8): configurable hotlinks in the thumb zone. Content is bottom-anchored — the
/// hotlink grid sits low, near the tab bar, so the most-used destinations are reachable one-handed.
/// A live-status strip shows connection/cache state without ever blocking the view.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(LibraryStore.self) private var library

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Spacer(minLength: 0)
                    header
                    hotlinks
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, CratesMetrics.gutter)
                .padding(.bottom, 8)
            }
            .defaultScrollAnchor(.bottom) // bottom-first ergonomics (Idea #8)
            .navigationTitle("Crates")
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
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.isDemo ? "Demo Library" : "Your Library")
                    .font(.title3.bold())
                Text(statusLine)
                    .font(.caption)
                    .foregroundStyle(CratesColor.textSecondary)
            }
            Spacer()
            StatusDot(state: library.rootState)
        }
    }

    private var statusLine: String {
        if model.isDemo { return "Not connected · showing sample data" }
        switch library.rootState {
        case .idle: return "Ready"
        case .revalidating: return "Updating…"
        case .live: return "Up to date"
        case .failed: return "Showing cached · pull to retry"
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

struct HotlinkTile: View {
    let crate: Crate
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: crate.symbol)
                .font(.title2)
                .foregroundStyle(CratesColor.accent)
                .frame(width: 44, height: 44)
                .background(CratesColor.accent.opacity(0.14), in: .rect(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text(crate.name).font(.subheadline.weight(.semibold)).lineLimit(2).multilineTextAlignment(.leading)
                if let n = crate.tuneCount { Text("\(n) tunes").font(.caption2).foregroundStyle(CratesColor.textSecondary) }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Content layer, not chrome: HIG reserves Liquid Glass for floating controls, so these
        // tiles are plain surface cards (glass stays on the tab bar / accessory / badges).
        .background(CratesColor.surface, in: .rect(cornerRadius: CratesMetrics.corner))
        .overlay(
            RoundedRectangle(cornerRadius: CratesMetrics.corner, style: .continuous)
                .strokeBorder(CratesColor.surfaceBorder, lineWidth: 0.5)
        )
    }
}

struct StatusDot: View {
    let state: LoadState
    var body: some View {
        Circle().fill(color).frame(width: 9, height: 9)
            .overlay(Circle().stroke(.white.opacity(0.2), lineWidth: 0.5))
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
