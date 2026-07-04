import SwiftUI

/// A row in the player's in-place Up Next queue (see NowPlayingView). Rows are identified by
/// QueueEntry.id upstream, so the same tune queued twice behaves as two independent rows.
struct QueueRow: View {
    let tune: Tune

    var body: some View {
        HStack(spacing: 12) {
            Artwork(tune: tune, size: 48)
            VStack(alignment: .leading, spacing: 3) {
                Text(tune.displayTitle).font(.body).lineLimit(1)
                HStack(spacing: 5) {
                    SourceBadge(source: tune.source)
                    Text(tune.displayArtist).font(.subheadline)
                        .foregroundStyle(CratesColor.textSecondary).lineLimit(1)
                }
            }
            Spacer()
            Text(tune.lengthLabel)
                .font(.caption.monospacedDigit())
                .foregroundStyle(CratesColor.textSecondary)
        }
        .padding(.vertical, 2)
    }
}
