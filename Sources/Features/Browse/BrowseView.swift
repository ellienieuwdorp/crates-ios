import SwiftUI

/// Browse tab: the crate tree — the canonical desktop structure, in desktop order. The root
/// list stays five stable entries; depth is handled by the crate FINDER (.searchable over the
/// whole flattened tree with breadcrumb paths), because a 2.2k-crate tree's problem is descent,
/// not breadth (dogfood round 3, W7).
struct BrowseView: View {
    @Environment(AppModel.self) private var model
    @Environment(LibraryStore.self) private var library

    @State private var query = ""

    private var trimmed: String { query.trimmingCharacters(in: .whitespaces) }
    private var finderResults: [LibraryStore.CrateIndexEntry] {
        trimmed.isEmpty ? [] : library.searchCrates(trimmed)
    }

    var body: some View {
        NavigationStack {
            List {
                if trimmed.isEmpty {
                    // Entity facets first (the desktop's Library-mode tabs, phone-shaped):
                    // an A–Z artist list beats an 800-crate artist-folder tree on a phone.
                    Section {
                        NavigationLink { ArtistsListView() } label: {
                            FacetEntryRow(title: "Artists", symbol: "music.mic")
                        }
                        NavigationLink { GenresListView() } label: {
                            FacetEntryRow(title: "Genres", symbol: "tag")
                        }
                        NavigationLink { DownloadedListView() } label: {
                            FacetEntryRow(title: "Downloaded", symbol: "arrow.down.circle")
                        }
                    }
                    // Curated tree: no hidden crates, no verifiably dead roots (see design doc).
                    Section("Crates") {
                        ForEach(library.browseRoots) { crate in
                            NavigationLink { CrateDetailView(crate: crate) } label: {
                                CrateRow(crate: crate)
                            }
                            .pinContextMenu(crate: crate, pins: model.pins)
                        }
                    }
                } else {
                    ForEach(finderResults) { entry in
                        NavigationLink { CrateDetailView(crate: entry.crate) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                CrateRow(crate: entry.crate)
                                if !entry.path.isEmpty {
                                    Text(entry.path)
                                        .font(.caption)
                                        .foregroundStyle(CratesColor.textSecondary)
                                        .lineLimit(1)
                                        .padding(.leading, 42) // aligns under the crate name
                                }
                            }
                        }
                        .pinContextMenu(crate: entry.crate, pins: model.pins)
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Browse")
            .searchable(text: $query, prompt: "Find a crate")
            .refreshable {
                if model.isPaired { await model.runDeltaSync(force: true) }
                else { await library.refreshRoot()?.value }
            }
            .onAppear { library.refreshRoot() }
            .overlay {
                if trimmed.isEmpty && library.browseRoots.isEmpty {
                    emptyState.allowsHitTesting(false)
                } else if !trimmed.isEmpty && finderResults.isEmpty {
                    ContentUnavailableView.search(text: trimmed).allowsHitTesting(false)
                }
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView("No Crates", systemImage: "square.stack.3d.up",
                               description: Text("Pair with a Crates server to see your library."))
    }
}

extension View {
    /// Pin/unpin any crate row to the Home grid.
    func pinContextMenu(crate: Crate, pins: HomePins) -> some View {
        contextMenu {
            if pins.isPinned(crate.id) {
                Button(role: .destructive) { pins.unpin(crate.id) } label: {
                    Label("Unpin from Home", systemImage: "pin.slash")
                }
            } else {
                Button { pins.pin(crate.id) } label: {
                    Label("Pin to Home", systemImage: "pin")
                }
            }
        }
    }
}

struct FacetEntryRow: View {
    let title: String
    let symbol: String
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.title3).foregroundStyle(CratesColor.accent).frame(width: 30)
            Text(title).font(.body)
        }
    }
}

/// A–Z artists with tune counts, deduped (the desktop's own shelves show duplicates; §e of the
/// desktop-workflow report). Searchable because 1,700 artists is a list you navigate by typing.
struct ArtistsListView: View {
    @Environment(LibraryStore.self) private var library
    @State private var query = ""

    private var facets: [LibraryStore.Facet] {
        let all = library.artistFacets()
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        List(facets) { facet in
            NavigationLink {
                FacetTunesView(title: facet.name, tunes: library.tunes(byArtist: facet.name))
            } label: {
                HStack {
                    Text(facet.name).lineLimit(1)
                    Spacer()
                    Text("\(facet.tuneCount)")
                        .font(.caption).foregroundStyle(CratesColor.textSecondary)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Artists")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Find an artist")
    }
}

/// Genres by tune count — the corpus's real shape, not the crate tree's.
struct GenresListView: View {
    @Environment(LibraryStore.self) private var library

    var body: some View {
        List(library.genreFacets()) { facet in
            NavigationLink {
                FacetTunesView(title: facet.name, tunes: library.tunes(byGenre: facet.name))
            } label: {
                HStack {
                    Text(facet.name).lineLimit(1)
                    Spacer()
                    Text("\(facet.tuneCount)")
                        .font(.caption).foregroundStyle(CratesColor.textSecondary)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Genres")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The downloaded-only surface (TODO §4, the kill-the-Wi-Fi litmus): every tune that is
/// playable offline right now — DownloadManager's set (disk truth) joined against the library
/// corpus, newest download first. Rows are the standard TrackRow, so play/queue/remove all
/// work; with the server unreachable, tapping plays from the local file. Empty state is
/// honest: nothing downloaded means nothing survives offline, and the copy says how to fix it.
struct DownloadedListView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(PlaybackController.self) private var player
    @Environment(DownloadManager.self) private var downloads

    private var tunes: [Tune] {
        library.tunes(byIDs: Array(downloads.downloadedTuneIDs))
            .sorted { (downloads.manifest[$0.id]?.completedAt ?? .distantPast)
                    > (downloads.manifest[$1.id]?.completedAt ?? .distantPast) }
    }

    var body: some View {
        let tunes = self.tunes
        List {
            ForEach(Array(tunes.enumerated()), id: \.element.id) { index, tune in
                TrackRow(
                    tune: tune,
                    isCurrent: player.current?.id == tune.id,
                    isDownloaded: true
                ) {
                    player.play(tunes, startingAt: index, context: "Downloaded")
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Downloaded")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if tunes.isEmpty {
                ContentUnavailableView(
                    "No Downloads",
                    systemImage: "arrow.down.circle",
                    description: Text("Downloaded tunes play without a connection. Touch and hold any tune to download it."))
                .allowsHitTesting(false)
            }
        }
    }
}

/// A facet's tunes — same play/queue affordances as a crate list.
struct FacetTunesView: View {
    let title: String
    let tunes: [Tune]
    @Environment(PlaybackController.self) private var player
    @Environment(DownloadManager.self) private var downloads

    var body: some View {
        List {
            ForEach(Array(tunes.enumerated()), id: \.element.id) { index, tune in
                TrackRow(
                    tune: tune,
                    isCurrent: player.current?.id == tune.id,
                    isDownloaded: downloads.isDownloaded(tune.id)
                ) {
                    player.play(tunes, startingAt: index, context: title)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct CrateRow: View {
    let crate: Crate
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: crate.symbol)
                .font(.title3).foregroundStyle(CratesColor.accent).frame(width: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(crate.name).font(.body)
                if let n = crate.tuneCount { Text("\(n) tunes").font(.caption).foregroundStyle(CratesColor.textSecondary) }
            }
        }
    }
}

/// A crate's contents: its tunes (and, when present, subcrates). Tapping a tune plays the crate
/// from that point; swiping queues (TrackRow). A menu exposes the offline download policy plus
/// deep play/shuffle across the whole subtree.
struct CrateDetailView: View {
    let crate: Crate
    @Environment(AppModel.self) private var model
    @Environment(LibraryStore.self) private var library
    @Environment(PlaybackController.self) private var player
    @Environment(DownloadManager.self) private var downloads
    @State private var showPolicy = false

    private var tunes: [Tune] { library.tunes(in: crate.id) }
    private var subcrates: [Crate] { library.children(of: crate.id) }

    var body: some View {
        List {
            if !subcrates.isEmpty {
                Section("Crates") {
                    ForEach(subcrates) { sub in
                        NavigationLink { CrateDetailView(crate: sub) } label: { CrateRow(crate: sub) }
                            .pinContextMenu(crate: sub, pins: model.pins)
                    }
                }
            }
            if tunes.isEmpty && library.smartCrateUnsupported(crate) {
                // Honest, not mysteriously empty: this smart crate's query is beyond the local
                // evaluator (or not fetched yet) — it genuinely lives on the desktop.
                Section {
                    Label("This smart crate is computed on the desktop.", systemImage: "wand.and.stars")
                        .font(.subheadline)
                        .foregroundStyle(CratesColor.textSecondary)
                }
            }
            Section(tunes.isEmpty ? "" : "\(tunes.count) Tunes") {
                ForEach(Array(tunes.enumerated()), id: \.element.id) { index, tune in
                    TrackRow(
                        tune: tune,
                        isCurrent: player.current?.id == tune.id,
                        isDownloaded: downloads.isDownloaded(tune.id)
                    ) {
                        model.usage.recordPlay(crate.id)
                        player.play(tunes, startingAt: index, context: crate.name)
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(crate.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Freshness of THIS crate's cached tunes, per Philosophy #3 — never block, always hint.
            ToolbarItem(placement: .topBarTrailing) {
                StatusDot(state: library.state(for: crate.id))
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { playAll() } label: { Label("Play All", systemImage: "play.fill") }
                        .disabled(tunes.isEmpty)
                    Button { for t in tunes { player.addToEndOfQueue(t) } } label: { Label("Queue All", systemImage: "text.append") }
                        .disabled(tunes.isEmpty)
                    if crate.hasChildren {
                        Divider()
                        Button { playDeep(shuffled: false) } label: {
                            Label("Play All incl. Subcrates", systemImage: "square.stack.3d.down.right")
                        }
                        Button { playDeep(shuffled: true) } label: {
                            Label("Shuffle incl. Subcrates", systemImage: "shuffle")
                        }
                    }
                    Divider()
                    Button { showPolicy = true } label: { Label("Offline Download…", systemImage: "arrow.down.circle") }
                } label: { Image(systemName: "ellipsis.circle") }
                    .accessibilityIdentifier("crateMenu")
            }
        }
        .sheet(isPresented: $showPolicy) {
            DownloadPolicyView(crate: crate, tunes: tunes)
        }
        .onAppear {
            model.usage.recordOpen(crate.id)
            library.refreshTunes(in: crate.id)
            if crate.hasChildren { library.refreshChildren(of: crate.id) }
        }
        .refreshable { await library.refreshTunes(in: crate.id)?.value }
    }

    private func playAll() {
        model.usage.recordPlay(crate.id)
        player.play(tunes, startingAt: 0, context: crate.name)
    }

    /// Whole subtree, deduped (the same tune legitimately lives in multiple subcrates).
    private func playDeep(shuffled: Bool) {
        Task {
            let all = await library.deepTunes(of: crate.id)
            guard !all.isEmpty else { return }
            model.usage.recordPlay(crate.id)
            player.play(all, startingAt: 0, context: crate.name)
            if shuffled && !player.isShuffled { player.toggleShuffle() }
        }
    }
}
