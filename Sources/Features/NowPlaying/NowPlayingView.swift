import SwiftUI

/// Full-screen player (Idea #4 v0): big art, title/artist, scrubber, transport, shuffle/repeat,
/// and a queue button that presents the queue sheet (Idea #5). Waveform scrubber and click-through
/// to artist/album are deliberately deferred (Idea #4 "later").
struct NowPlayingView: View {
    @Environment(PlaybackController.self) private var player
    @Environment(\.dismiss) private var dismiss
    @State private var showQueue = false
    @State private var scrubValue: Double = 0
    @State private var isScrubbing = false

    var body: some View {
        VStack(spacing: 24) {
            grabber
            if let tune = player.current {
                Artwork(tune: tune, size: 300)
                    .shadow(color: .black.opacity(0.25), radius: 24, y: 12)
                    .padding(.top, 8)

                VStack(spacing: 6) {
                    Text(tune.displayTitle).font(.title2.bold()).multilineTextAlignment(.center).lineLimit(2)
                    HStack(spacing: 6) {
                        SourceBadge(source: tune.source)
                        Text(tune.displayArtist).font(.title3).foregroundStyle(CratesColor.textSecondary)
                    }
                    if let genre = tune.genre, let bpm = tune.bpm {
                        Text("\(genre) · \(bpm) BPM · \(tune.key ?? "")")
                            .font(.footnote).foregroundStyle(CratesColor.textSecondary)
                    }
                    if let error = player.playbackError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(CratesColor.red)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(.horizontal)

                scrubber
                transport
                Spacer()
                bottomBar
            } else {
                ContentUnavailableView("Nothing playing", systemImage: "music.note")
            }
        }
        .padding(.horizontal, CratesMetrics.gutter)
        .presentationDragIndicator(.hidden)
        .sheet(isPresented: $showQueue) { QueueView() }
    }

    private var grabber: some View {
        Capsule().fill(CratesColor.textSecondary.opacity(0.4))
            .frame(width: 40, height: 5).padding(.top, 8)
    }

    private var scrubber: some View {
        VStack(spacing: 4) {
            Slider(value: Binding(
                get: { isScrubbing ? scrubValue : player.currentTime },
                set: { scrubValue = $0 }
            ), in: 0...max(player.duration, 1)) { editing in
                isScrubbing = editing
                if !editing { player.seek(to: scrubValue) }
            }
            .tint(CratesColor.playback)
            HStack {
                Text(timeLabel(isScrubbing ? scrubValue : player.currentTime))
                Spacer()
                Text("-" + timeLabel(max(0, player.duration - (isScrubbing ? scrubValue : player.currentTime))))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(CratesColor.textSecondary)
        }
    }

    private var transport: some View {
        HStack(spacing: 44) {
            Button { player.previous() } label: { Image(systemName: "backward.fill").font(.title) }
            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 68))
                    .foregroundStyle(CratesColor.playback)
                    .contentTransition(.symbolEffect(.replace))
            }
            Button { player.next() } label: { Image(systemName: "forward.fill").font(.title) }
        }
        .foregroundStyle(.primary)
        .tint(CratesColor.accent)
    }

    private var bottomBar: some View {
        HStack {
            Button { player.isShuffled.toggle() } label: {
                Image(systemName: "shuffle")
                    .foregroundStyle(player.isShuffled ? CratesColor.accent : CratesColor.textSecondary)
            }
            Spacer()
            Button { showQueue = true } label: {
                Image(systemName: "list.bullet").foregroundStyle(CratesColor.accent)
            }
            Spacer()
            Button { cycleRepeat() } label: {
                Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat")
                    .foregroundStyle(player.repeatMode == .off ? CratesColor.textSecondary : CratesColor.accent)
            }
        }
        .font(.title3)
        .padding(.horizontal, 32)
        .padding(.bottom, 24)
    }

    private func cycleRepeat() {
        player.repeatMode = switch player.repeatMode {
        case .off: .all; case .all: .one; case .one: .off
        }
    }

    private func timeLabel(_ t: Double) -> String {
        guard t.isFinite, t >= 0 else { return "0:00" }
        let s = Int(t.rounded()); return String(format: "%d:%02d", s / 60, s % 60)
    }
}
