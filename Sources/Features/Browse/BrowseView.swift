import SwiftUI

/// Browse tab: the crate tree. Top-level crates list; tapping a crate opens its detail (subcrates
/// + tunes). Everything renders from cache first and revalidates behind (stale-while-revalidate).
struct BrowseView: View {
    @Environment(LibraryStore.self) private var library

    var body: some View {
        NavigationStack {
            List {
                ForEach(library.rootCrates) { crate in
                    NavigationLink { CrateDetailView(crate: crate) } label: {
                        CrateRow(crate: crate)
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Browse")
            .refreshable { await library.refreshRoot()?.value }
            .onAppear { library.refreshRoot() }
            .overlay { if library.rootCrates.isEmpty { emptyState } }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView("No Crates", systemImage: "square.stack.3d.up",
                               description: Text("Pair with a Crates server to see your library."))
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
/// from that point; swiping queues (TrackRow). A menu exposes the offline download policy.
struct CrateDetailView: View {
    let crate: Crate
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
                    }
                }
            }
            Section(tunes.isEmpty ? "" : "\(tunes.count) Tunes") {
                ForEach(Array(tunes.enumerated()), id: \.element.id) { index, tune in
                    TrackRow(
                        tune: tune,
                        isCurrent: player.current?.id == tune.id,
                        isDownloaded: downloads.isDownloaded(tune.id)
                    ) {
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
                    Button { player.play(tunes, startingAt: 0, context: crate.name) } label: { Label("Play All", systemImage: "play.fill") }
                        .disabled(tunes.isEmpty)
                    Button { for t in tunes { player.addToEndOfQueue(t) } } label: { Label("Queue All", systemImage: "text.append") }
                        .disabled(tunes.isEmpty)
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
            library.refreshTunes(in: crate.id)
            if crate.hasChildren { library.refreshChildren(of: crate.id) }
        }
        .refreshable { await library.refreshTunes(in: crate.id)?.value }
    }
}
