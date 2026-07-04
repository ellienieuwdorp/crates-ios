import SwiftUI

/// The play queue (Idea #5): tap to jump, swipe to remove, drag to reorder (via Edit — SwiftUI
/// Lists only allow row dragging in edit mode, and forcing edit mode permanently would break both
/// tap and swipe). Rows are identified by QueueEntry.id, so the same tune queued twice behaves as
/// two independent rows.
struct QueueView: View {
    @Environment(PlaybackController.self) private var player
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let entry = player.currentEntry {
                    Section("Now Playing") {
                        QueueRow(tune: entry.tune, isCurrent: true)
                    }
                }
                Section("Up Next") {
                    ForEach(upNext) { entry in
                        QueueRow(tune: entry.tune, isCurrent: false)
                            .contentShape(.rect)
                            .onTapGesture {
                                if let i = player.entries.firstIndex(where: { $0.id == entry.id }) {
                                    player.jump(to: i)
                                }
                            }
                    }
                    .onMove { source, dest in
                        player.moveInQueue(from: mappedOffsets(source), to: dest + upNextStart)
                    }
                    .onDelete { offsets in
                        player.removeFromQueue(at: mappedOffsets(offsets))
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Queue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { EditButton() }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .overlay {
                if upNext.isEmpty && player.currentEntry == nil {
                    ContentUnavailableView("Queue is empty", systemImage: "list.bullet",
                                           description: Text("Swipe right on any track to queue it."))
                }
            }
        }
        .presentationDetents([.fraction(0.6), .large])
        .presentationDragIndicator(.visible)
    }

    private var upNextStart: Int { (player.currentIndex ?? -1) + 1 }
    private var upNext: [QueueEntry] { Array(player.entries.dropFirst(upNextStart)) }
    /// Map offsets within the "Up Next" section back to absolute queue indices.
    private func mappedOffsets(_ offsets: IndexSet) -> IndexSet { IndexSet(offsets.map { $0 + upNextStart }) }
}

struct QueueRow: View {
    let tune: Tune
    let isCurrent: Bool
    var body: some View {
        HStack(spacing: 12) {
            Artwork(tune: tune, size: 40)
            VStack(alignment: .leading, spacing: 1) {
                Text(tune.displayTitle).font(.subheadline.weight(isCurrent ? .bold : .regular))
                    .foregroundStyle(isCurrent ? CratesColor.accent : .primary).lineLimit(1)
                Text(tune.displayArtist).font(.caption).foregroundStyle(CratesColor.textSecondary).lineLimit(1)
            }
            Spacer()
            if isCurrent { Image(systemName: "speaker.wave.2.fill").foregroundStyle(CratesColor.accent).font(.caption) }
        }
    }
}
