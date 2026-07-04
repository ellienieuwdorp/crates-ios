import SwiftUI

/// Full-screen player (Idea #4 v2). Two in-place states, no popups:
///
///   • collapsed — big art, title/artist, scrubber, one transport row
///     (shuffle · back · play · forward · repeat), and the Up Next handlebar resting at the
///     bottom. The queue stays tucked away.
///   • expanded — swipe up (or tap) the handlebar: the header morphs into a compact art+title
///     row, and the queue unfolds below the transport, split into the manual additions
///     ("Added to Queue") and the remaining auto context ("From <crate>").
///
/// Waveform scrubber and click-through to artist/album are deliberately deferred (Idea #4 "later").
struct NowPlayingView: View {
    @Environment(PlaybackController.self) private var player
    @State private var queueExpanded = false
    @State private var editMode: EditMode = .inactive
    @State private var scrubValue: Double = 0
    @State private var isScrubbing = false
    @Namespace private var artNamespace

    var body: some View {
        VStack(spacing: 16) {
            grabber
            if let tune = player.current {
                if queueExpanded {
                    compactHeader(tune)
                } else {
                    bigHeader(tune)
                }

                if let error = player.playbackError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(CratesColor.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                scrubber
                transport

                if !queueExpanded { Spacer(minLength: 0) }
                queueHandle
                if queueExpanded { queueList }
            } else {
                ContentUnavailableView("Nothing playing", systemImage: "music.note")
            }
        }
        .padding(.horizontal, CratesMetrics.gutter)
        .presentationDragIndicator(.hidden)
    }

    private var grabber: some View {
        Capsule().fill(CratesColor.textSecondary.opacity(0.4))
            .frame(width: 40, height: 5).padding(.top, 8)
    }

    // MARK: - Header (morphs between states)

    private func bigHeader(_ tune: Tune) -> some View {
        VStack(spacing: 20) {
            Artwork(tune: tune, size: 260)
                .matchedGeometryEffect(id: "art", in: artNamespace)
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
            }
            .padding(.horizontal)
        }
    }

    private func compactHeader(_ tune: Tune) -> some View {
        HStack(spacing: 12) {
            Artwork(tune: tune, size: 56)
                .matchedGeometryEffect(id: "art", in: artNamespace)
            VStack(alignment: .leading, spacing: 2) {
                Text(tune.displayTitle).font(.headline).lineLimit(1)
                HStack(spacing: 6) {
                    SourceBadge(source: tune.source)
                    Text(tune.displayArtist).font(.subheadline)
                        .foregroundStyle(CratesColor.textSecondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Scrubber & transport

    private var scrubber: some View {
        VStack(spacing: 4) {
            Slider(value: Binding(
                get: { isScrubbing ? scrubValue : player.currentTime },
                set: { scrubValue = $0 }
            ), in: 0...max(player.duration, 1)) { editing in
                if editing { scrubValue = player.currentTime }
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
                    .font(.system(size: queueExpanded ? 54 : 64))
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

    // MARK: - Up Next (in-place, handle-driven)

    /// The handlebar: swipe up to unfold the queue, swipe down (or tap) to toggle. Everything
    /// happens in this screen — no sheets, no disclosure chevrons.
    private var queueHandle: some View {
        VStack(spacing: 6) {
            Capsule().fill(CratesColor.textSecondary.opacity(0.35))
                .frame(width: 44, height: 5)
            HStack(spacing: 6) {
                Text("Up Next").font(.headline)
                if !upNextEntries.isEmpty {
                    Text("\(upNextEntries.count)")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(CratesColor.textSecondary)
                }
                Spacer()
                if queueExpanded && !upNextEntries.isEmpty {
                    Button(editMode == .active ? "Done" : "Edit") {
                        withAnimation { editMode = editMode == .active ? .inactive : .active }
                    }
                    .font(.subheadline)
                    .tint(CratesColor.accent)
                }
            }
        }
        .padding(.vertical, 10)
        .contentShape(.rect)
        .onTapGesture { toggleQueue() }
        .gesture(
            DragGesture(minimumDistance: 10)
                .onEnded { value in
                    if value.translation.height < -25 { setQueue(expanded: true) }
                    else if value.translation.height > 25 { setQueue(expanded: false) }
                }
        )
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(queueExpanded ? "Collapse queue" : "Expand queue")
        .accessibilityIdentifier("queueHandle")
    }

    private var queueList: some View {
        List {
            if !manualBlock.isEmpty {
                Section("Added to Queue") {
                    queueRows(manualBlock, baseIndex: upNextStart)
                }
            }
            if !contextBlock.isEmpty {
                Section(manualBlock.isEmpty && player.contextName == nil ? "" : contextHeader) {
                    queueRows(contextBlock, baseIndex: upNextStart + manualBlock.count)
                }
            }
            if upNextEntries.isEmpty {
                Text("Nothing up next — swipe right on any track to queue it.")
                    .font(.footnote).foregroundStyle(CratesColor.textSecondary)
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.editMode, $editMode)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func queueRows(_ block: [QueueEntry], baseIndex: Int) -> some View {
        ForEach(block) { entry in
            QueueRow(tune: entry.tune)
                .contentShape(.rect)
                .onTapGesture {
                    if let i = player.entries.firstIndex(where: { $0.id == entry.id }) {
                        player.jump(to: i)
                    }
                }
                .listRowInsets(.init(top: 8, leading: 4, bottom: 8, trailing: 4))
        }
        .onDelete { offsets in
            player.removeFromQueue(at: IndexSet(offsets.map { $0 + baseIndex }))
        }
        .onMove { source, destination in
            player.moveInQueue(from: IndexSet(source.map { $0 + baseIndex }),
                               to: destination + baseIndex)
        }
    }

    private var contextHeader: String {
        player.contextName.map { "From \($0)" } ?? "Up Next"
    }

    private func toggleQueue() { setQueue(expanded: !queueExpanded) }

    private func setQueue(expanded: Bool) {
        withAnimation(.snappy(duration: 0.35)) {
            queueExpanded = expanded
            if !expanded { editMode = .inactive }
        }
    }

    // MARK: - Queue slices

    private var upNextStart: Int { (player.currentIndex ?? -1) + 1 }
    private var upNextEntries: [QueueEntry] { Array(player.entries.dropFirst(upNextStart)) }
    /// Manual additions (play-next + queued) directly after the current track — the controller
    /// keeps them ahead of the remaining context (see PlaybackController's ordering invariant).
    private var manualBlock: [QueueEntry] { Array(upNextEntries.prefix(while: { $0.origin != .context })) }
    private var contextBlock: [QueueEntry] { Array(upNextEntries.dropFirst(manualBlock.count)) }

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
