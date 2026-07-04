import SwiftUI

/// Search tab. Fully local (dogfood round 3, item 8): the bulk-backup import puts the whole
/// library on-device, so search is a synchronous ranked scan over `LibraryStore.allTunes` —
/// instant, offline-capable, immune to the server's deprecated Lucene endpoint. The `.search`
/// tab role keeps the field in the thumb zone; activating the tab raises the keyboard (item 7).
///
/// Structure rule: ONE always-present List, empty states as overlays. Swapping the List for a
/// ContentUnavailableView tore down the searchable field's scroll coupling — that's what killed
/// the keyboard on "no results" and deadened the X button (item 9).
struct SearchView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(PlaybackController.self) private var player
    @Environment(DownloadManager.self) private var downloads

    /// Tab selection from RootView — read-only trigger for keyboard focus.
    let selectedTab: AppTab

    @State private var query = ""
    @State private var recents = RecentSearches()
    @FocusState private var searchFocused: Bool

    private var trimmed: String { query.trimmingCharacters(in: .whitespaces) }
    private var results: [Tune] { trimmed.isEmpty ? [] : library.searchTunes(trimmed) }

    var body: some View {
        NavigationStack {
            List {
                if trimmed.isEmpty {
                    if !recents.queries.isEmpty {
                        Section {
                            ForEach(recents.queries, id: \.self) { q in
                                Button {
                                    query = q
                                    searchFocused = true
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: "clock.arrow.circlepath")
                                            .foregroundStyle(CratesColor.textSecondary)
                                        Text(q).foregroundStyle(.primary)
                                    }
                                }
                            }
                            .onDelete { recents.remove(at: $0) }
                        } header: {
                            HStack {
                                Text("Recent Searches")
                                Spacer()
                                Button("Clear") { recents.clear() }
                                    .font(.footnote)
                                    .tint(CratesColor.accent)
                            }
                        }
                    }
                } else {
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, tune in
                        TrackRow(tune: tune,
                                 isCurrent: player.current?.id == tune.id,
                                 isDownloaded: downloads.isDownloaded(tune.id)) {
                            recents.record(trimmed)
                            player.play(results, startingAt: index, context: "Search")
                        }
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Search")
            .searchable(text: $query, prompt: "Titles, artists, albums")
            .searchFocused($searchFocused)
            .onSubmit(of: .search) { recents.record(trimmed) }
            .overlay {
                // Overlays, never structural swaps — the List must stay alive so the field
                // keeps first-responder and the clear button stays functional.
                if trimmed.isEmpty && recents.queries.isEmpty {
                    ContentUnavailableView("Search your library", systemImage: "magnifyingglass",
                                           description: Text("Find tunes across every crate — works offline."))
                        .allowsHitTesting(false)
                } else if !trimmed.isEmpty && results.isEmpty {
                    ContentUnavailableView.search(text: trimmed)
                        .allowsHitTesting(false)
                }
            }
        }
        .onChange(of: selectedTab, initial: true) { _, tab in
            guard tab == .search else { return }
            // Raise the keyboard once the tab-bar → search-pill morph settles; setting focus
            // during the Liquid Glass transition is silently dropped.
            Task {
                try? await Task.sleep(for: .milliseconds(550))
                searchFocused = true
            }
        }
    }
}
