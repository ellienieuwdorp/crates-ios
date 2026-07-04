import SwiftUI

/// Search tab. Uses the `.search` tab role so the field lives at the bottom in the thumb zone
/// (Idea #8). Results are tunes you can play or swipe-to-queue directly.
struct SearchView: View {
    @Environment(AppModel.self) private var model
    @Environment(PlaybackController.self) private var player
    @Environment(DownloadManager.self) private var downloads

    @State private var query = ""
    @State private var results: [Tune] = []
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Group {
                if query.isEmpty {
                    ContentUnavailableView("Search your library", systemImage: "magnifyingglass",
                                           description: Text("Find tunes across every crate."))
                } else if results.isEmpty && !isSearching {
                    ContentUnavailableView.search(text: query)
                } else {
                    List {
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, tune in
                            TrackRow(tune: tune,
                                     isCurrent: player.current?.id == tune.id,
                                     isDownloaded: downloads.isDownloaded(tune.id)) {
                                player.play(results, startingAt: index, context: "Search")
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Search")
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always))
            .onChange(of: query) { _, newValue in scheduleSearch(newValue) }
        }
    }

    /// Debounced search: local demo data filters instantly; a connected build hits
    /// /search/tunes/basic. Cancels the prior in-flight search on each keystroke.
    private func scheduleSearch(_ text: String) {
        searchTask?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { results = []; return }

        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled else { return }
            if model.isDemo {
                results = SampleData.tunesByCrate.values.flatMap { $0 }
                    .filter { $0.title.localizedCaseInsensitiveContains(trimmed)
                           || $0.artist.localizedCaseInsensitiveContains(trimmed) }
            } else {
                isSearching = true
                defer { isSearching = false }
                let found = try? await LibraryAPI(client: model.client).searchTunes(trimmed)
                if !Task.isCancelled { results = found ?? [] }
            }
        }
    }
}
