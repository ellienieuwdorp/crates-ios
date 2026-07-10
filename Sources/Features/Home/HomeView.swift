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
                        shelves
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
                seedPins()
            }
            .onChange(of: library.rootCrates) { _, _ in
                seedPins() // first sync may land after onAppear
            }
        }
    }

    /// Seeding must wait for smart-crate definitions: without them the genre crates all look
    /// empty and container fallbacks steal the seed slots permanently (seen live, 2026-07-10).
    /// AppModel triggers the authoritative seed pass right after each sync's hydration.
    private func seedPins() {
        guard !library.smartQueriesPending else { return }
        model.pins.seedIfNeeded(candidates: library.seedCandidates(),
                                oldDefault: library.rootCrates)
    }

    // MARK: - Adaptive shelves (each renders only when non-empty — honest by construction)

    /// The adaptive zone above the stable pin grid: what you played, what arrived, what you
    /// forgot. Bottom-anchored layout keeps pins at the thumb; shelves grow upward into the
    /// previously-empty top half and are reached by the natural scroll-up.
    @ViewBuilder private var shelves: some View {
        let played = library.tunes(byIDs: model.usage.recentTuneIDs())
        let added = library.recentlyAddedTunes()
        let forgotten = library.forgottenFavorites(
            excluding: model.usage.tuneIDsPlayed(withinDays: 30))
        TuneShelf(title: "Recently Played", tunes: played)
        TuneShelf(title: "Recently Added", tunes: added)
        TuneShelf(title: "Forgotten Favorites", tunes: forgotten)
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
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                         spacing: 16) {
            ForEach(pinned) { crate in
                NavigationLink { CrateDetailView(crate: crate) } label: {
                    CrateTile(crate: crate, coverIDs: library.previewCoverIDs(for: crate.id))
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

/// A horizontal tune carousel (Home's adaptive shelves). Renders NOTHING when empty — the
/// desktop ships three dead sections with joke copy; our honesty rule forbids the pattern.
/// Tapping a card plays the shelf from that tune (the shelf is the queue context); context
/// menu queues without interrupting.
struct TuneShelf: View {
    let title: String
    let tunes: [Tune]
    @Environment(PlaybackController.self) private var player

    var body: some View {
        if !tunes.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.headline)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(Array(tunes.enumerated()), id: \.element.id) { index, tune in
                            TuneCard(tune: tune, isCurrent: player.current?.id == tune.id) {
                                player.play(tunes, startingAt: index, context: title)
                            }
                            .contextMenu {
                                Button { player.playNext(tune) } label: {
                                    Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                                }
                                Button { player.addToEndOfQueue(tune) } label: {
                                    Label("Add to Queue", systemImage: "text.append")
                                }
                            }
                        }
                    }
                }
                .scrollClipDisabled()
            }
        }
    }
}

/// Cover-led tune card: the artwork is the tile (same content-first language as CrateTile),
/// title + artist as a quiet text stack. Current track gets the teal ring, never orange.
struct TuneCard: View {
    let tune: Tune
    let isCurrent: Bool
    let action: () -> Void
    private static let side: CGFloat = 132

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack {
                    Rectangle().fill(CratesColor.surface)
                    CoverImage(coverID: tune.coverID ?? 0)
                }
                .frame(width: Self.side, height: Self.side)
                .clipShape(.rect(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(isCurrent ? CratesColor.accent : .primary.opacity(0.08),
                                      lineWidth: isCurrent ? 2 : 0.5)
                )
                VStack(alignment: .leading, spacing: 1) {
                    Text(tune.displayTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(tune.displayArtist)
                        .font(.caption)
                        .foregroundStyle(CratesColor.textSecondary)
                        .lineLimit(1)
                }
                .frame(width: Self.side, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
    }
}

/// Content-led crate tile (dogfood round 4, I9): the crate's artwork IS the tile — a 2×2 mosaic
/// of its subtree's covers (Apple Music's playlist/folder convention), name + count as a plain
/// text stack below on the app background. No card container, no borders except a 0.5pt
/// hairline on the art (white-cover-on-white separation), no glass, no accent tint: content
/// carries the identity, chrome keeps the color.
struct CrateTile: View {
    let crate: Crate
    let coverIDs: [Int64]
    private static let radius: CGFloat = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CrateMosaic(coverIDs: coverIDs, kindSymbol: crate.symbol)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(.rect(cornerRadius: Self.radius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                        .strokeBorder(.primary.opacity(0.08), lineWidth: 0.5)
                )
            VStack(alignment: .leading, spacing: 1) {
                Text(crate.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let n = crate.tuneCount {
                    Text("\(n) tunes")
                        .font(.caption)
                        .foregroundStyle(CratesColor.textSecondary)
                }
            }
        }
    }
}

/// Fallback ladder: 4+ covers → 2×2 mosaic; 1–3 → single full-bleed cover (a partial mosaic
/// reads as a loading failure); 0 → kind symbol on a quiet fill (textSecondary, never accent).
struct CrateMosaic: View {
    let coverIDs: [Int64]
    let kindSymbol: String

    var body: some View {
        if coverIDs.count >= 4 {
            Grid(horizontalSpacing: 1, verticalSpacing: 1) {
                GridRow {
                    cell(coverIDs[0])
                    cell(coverIDs[1])
                }
                GridRow {
                    cell(coverIDs[2])
                    cell(coverIDs[3])
                }
            }
        } else if let first = coverIDs.first {
            cell(first)
        } else {
            ZStack {
                Rectangle().fill(CratesColor.surface)
                Image(systemName: kindSymbol)
                    .font(.system(size: 40, weight: .regular))
                    .foregroundStyle(CratesColor.textSecondary)
            }
        }
    }

    private func cell(_ coverID: Int64) -> some View {
        Color.clear.overlay(CoverImage(coverID: coverID)).clipped()
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
