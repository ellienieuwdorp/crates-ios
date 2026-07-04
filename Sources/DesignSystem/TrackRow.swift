import SwiftUI

/// A track row with the POC's signature queue gestures (Idea #5/#6):
///   • swipe right (leading edge)  → add to end of queue
///   • swipe left  (trailing edge) → play next
/// Full-swipe triggers the action; a haptic + a brief bouncing SF Symbol confirm what happened.
/// Also carries the per-row source badge (Idea #7) and a downloaded indicator.
struct TrackRow: View {
    let tune: Tune
    var isCurrent: Bool = false
    var isDownloaded: Bool = false
    var onTap: () -> Void = {}

    @Environment(PlaybackController.self) private var player
    @State private var lastAction: QueueAction? = nil
    @State private var feedbackTrigger = 0

    enum QueueAction: Equatable { case queued, playNext }

    /// Unstreamable AND not downloaded: nothing on this phone can play it — say so up front.
    private var isUnplayable: Bool { tune.knownUnstreamable && !isDownloaded }

    var body: some View {
        HStack(spacing: CratesMetrics.rowSpacing) {
            Artwork(tune: tune)
                .overlay(alignment: .bottomTrailing) {
                    if isCurrent { playingPip }
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(tune.displayTitle)
                    .font(.body.weight(isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? CratesColor.accent : .primary)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    SourceBadge(source: tune.source)
                    if isUnplayable {
                        Text("\(tune.source.label) only — no audio file")
                            .lineLimit(1)
                    } else {
                        Text(tune.displayArtist)
                            .lineLimit(1)
                        if let bpm = tune.bpm, bpm != "—" {
                            Text("· \(bpm) BPM")
                        }
                    }
                }
                .font(.subheadline)
                .foregroundStyle(CratesColor.textSecondary)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 3) {
                Text(tune.lengthLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(CratesColor.textSecondary)
                if isDownloaded {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(CratesColor.green)
                }
            }
        }
        .opacity(isUnplayable ? 0.45 : 1) // honest: this row can't produce sound on this phone
        .contentShape(.rect)
        .onTapGesture(perform: onTap)
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                player.addToEndOfQueue(tune)
                confirm(.queued)
            } label: {
                Label("Queue", systemImage: "text.append")
            }
            .tint(CratesColor.accent)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button {
                player.playNext(tune)
                confirm(.playNext)
            } label: {
                Label("Play Next", systemImage: "text.insert")
            }
            .tint(CratesColor.accentDeep)
        }
        .sensoryFeedback(.success, trigger: feedbackTrigger)
        .overlay(alignment: .trailing) {
            if let action = lastAction {
                confirmationBadge(action)
                    .transition(.scale.combined(with: .opacity))
            }
        }
    }

    private func confirm(_ action: QueueAction) {
        feedbackTrigger += 1
        withAnimation(.bouncy) { lastAction = action }
        Task {
            try? await Task.sleep(for: .seconds(1.1))
            withAnimation(.easeOut) { lastAction = nil }
        }
    }

    private func confirmationBadge(_ action: QueueAction) -> some View {
        HStack(spacing: 5) {
            Image(systemName: action == .queued ? "text.append" : "text.insert")
                .symbolEffect(.bounce, value: feedbackTrigger)
            Text(action == .queued ? "Queued" : "Up next")
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        // Solid capsule, not tinted glass: this is a content-layer confirmation, and a near-opaque
        // tint on glass defeats the material anyway (HIG: tint glass sparingly, chrome only).
        .background(action == .queued ? CratesColor.accent : CratesColor.accentDeep, in: .capsule)
        .foregroundStyle(.white)
    }

    private var playingPip: some View {
        Image(systemName: "waveform")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .padding(4)
            .background(CratesColor.accent, in: .circle)
            .offset(x: 3, y: 3)
    }
}
