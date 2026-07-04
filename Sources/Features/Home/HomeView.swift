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
                        recentsRow
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
            .refreshable {
                if model.isPaired { await model.runDeltaSync(force: true) }
                else { await library.refreshRoot()?.value }
            }
            .onAppear {
                library.refreshRoot()
                model.pins.seedIfNeeded(with: library.rootCrates)
            }
            .onChange(of: library.rootCrates) { _, roots in
                model.pins.seedIfNeeded(with: roots) // first sync may land after onAppear
            }
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

    /// Auto recents: most-recently opened/played crates (local usage log), excluding pins —
    /// the chips are the adaptive zone, the grid below stays stable muscle memory.
    @ViewBuilder private var recentsRow: some View {
        let recents = model.usage.recentCrateIDs()
            .filter { !model.pins.isPinned($0) }
            .compactMap { library.crate(byID: $0) }
        if !recents.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(recents) { crate in
                        NavigationLink { CrateDetailView(crate: crate) } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "clock.arrow.circlepath").font(.caption2)
                                Text(crate.name).font(.subheadline.weight(.medium)).lineLimit(1)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(CratesColor.surface, in: .capsule)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .scrollClipDisabled()
        }
    }

    /// The pinned grid: user-owned, stable positions (pin/unpin via context menus; new pins
    /// append nearest the thumb). Seeded once with the top roots so it's never empty.
    private var hotlinks: some View {
        let pinned = model.pins.ids.compactMap { library.crate(byID: $0) }
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            ForEach(pinned) { crate in
                NavigationLink { CrateDetailView(crate: crate) } label: {
                    HotlinkTile(crate: crate)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button(role: .destructive) { model.pins.unpin(crate.id) } label: {
                        Label("Unpin from Home", systemImage: "pin.slash")
                    }
                }
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
