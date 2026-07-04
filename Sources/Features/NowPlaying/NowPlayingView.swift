import SwiftUI

/// Full-screen player (Idea #4 v1): big art, title/artist, scrubber, a single transport row
/// (shuffle · back · play · forward · repeat), and an embedded Up Next queue behind a grab
/// handle — drag or tap the handle to open the full queue sheet with reorder/edit. Waveform
/// scrubber and click-through to artist/album are deliberately deferred (Idea #4 "later").
struct NowPlayingView: View {
    @Environment(PlaybackController.self) private var player
    @Environment(\.dismiss) private var dismiss
    @State private var showQueue = false
    @State private var scrubValue: Double = 0
    @State private var isScrubbing = false

    var body: some View {
        VStack(spacing: 20) {
            grabber
            if let tune = player.current {
                Artwork(tune: tune, size: 260)
                    .shadow(color: .black.opacity(0.25), radius: 24, y: 12)

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
                queuePanel
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
            .tint(CratesColor.accent)
            HStack {
                Text(timeLabel(isScrubbing ? scrubValue : player.currentTime))
                Spacer()
                Text("-" + timeLabel(max(0, player.duration - (isScrubbing ? scrubValue : player.currentTime))))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(CratesColor.textSecondary)
        }
    }

    /// One row: mode toggles at the edges, transport in the middle — frees the bottom of the
    /// sheet for the queue.
    private var transport: some View {
        HStack {
            Button { player.isShuffled.toggle() } label: {
                Image(systemName: "shuffle").font(.title3)
                    .foregroundStyle(player.isShuffled ? CratesColor.accent : CratesColor.textSecondary)
            }
            Spacer()
            Button { player.previous() } label: { Image(systemName: "backward.fill").font(.title) }
            Spacer()
            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(CratesColor.accent)
                    .contentTransition(.symbolEffect(.replace))
            }
            Spacer()
            Button { player.next() } label: { Image(systemName: "forward.fill").font(.title) }
            Spacer()
            Button { cycleRepeat() } label: {
                Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat").font(.title3)
                    .foregroundStyle(player.repeatMode == .off ? CratesColor.textSecondary : CratesColor.accent)
            }
        }
        .foregroundStyle(.primary)
        .tint(CratesColor.accent)
        .padding(.horizontal, 8)
    }

    // MARK: - Embedded queue

    /// The freed bottom space: a handlebar + scrollable Up Next list. Tap a row to jump; grab
    /// (drag up) or tap the handle to open the full queue sheet with reorder/remove.
    private var queuePanel: some View {
        VStack(spacing: 0) {
            queueHandle
            if upNext.isEmpty {
                Text("Nothing up next — swipe right on any track to queue it.")
                    .font(.footnote).foregroundStyle(CratesColor.textSecondary)
                    .frame(maxHeight: .infinity, alignment: .center)
                    .padding(.horizontal)
            } else {
                List {
                    ForEach(upNext) { entry in
                        QueueRow(tune: entry.tune, isCurrent: false)
                            .contentShape(.rect)
                            .onTapGesture {
                                if let i = player.entries.firstIndex(where: { $0.id == entry.id }) {
                                    player.jump(to: i)
                                }
                            }
                            .listRowBackground(Color.clear)
                            .listRowInsets(.init(top: 6, leading: 4, bottom: 6, trailing: 4))
                    }
                    .onDelete { offsets in
                        player.removeFromQueue(at: mappedOffsets(offsets))
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var queueHandle: some View {
        VStack(spacing: 6) {
            Capsule().fill(CratesColor.textSecondary.opacity(0.35))
                .frame(width: 36, height: 4)
            HStack {
                Text("Up Next").font(.headline)
                if !upNext.isEmpty {
                    Text("\(upNext.count)").font(.subheadline.monospacedDigit())
                        .foregroundStyle(CratesColor.textSecondary)
                }
                Spacer()
                Image(systemName: "chevron.up")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(CratesColor.textSecondary)
            }
        }
        .padding(.vertical, 8)
        .contentShape(.rect)
        .onTapGesture { showQueue = true }
        .gesture(
            DragGesture(minimumDistance: 12).onEnded { value in
                if value.translation.height < -20 { showQueue = true }
            }
        )
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Open full queue")
    }

    private var upNextStart: Int { (player.currentIndex ?? -1) + 1 }
    private var upNext: [QueueEntry] { Array(player.entries.dropFirst(upNextStart)) }
    private func mappedOffsets(_ offsets: IndexSet) -> IndexSet { IndexSet(offsets.map { $0 + upNextStart }) }

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
