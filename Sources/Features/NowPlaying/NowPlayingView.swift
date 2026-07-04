import SwiftUI

/// Full-screen player (Idea #4 v3 — see docs/design/now-playing-redesign.md). Two in-place
/// states on a two-detent sheet, no popups:
///
///   • collapsed — the sheet HUGS the content (measured detent): art, title, scrubber, one
///     transport row, and the Up Next glass pill. iOS 26 floats partial sheets inset with
///     Liquid Glass corners automatically.
///   • expanded — tap the pill or drag the sheet up: the header morphs into a compact
///     art+title row and the queue unfolds, split into "Added to Queue" (manual) and
///     "From <context>" (auto). The system sheet drag IS the expand/collapse gesture.
///
/// Layout rules: one 24pt gutter for everything (the "transport axis"), 8pt-grid spacing,
/// transport controls in equal-width slots so the play button is structurally centered, and
/// exactly one glass element (the handle pill) per HIG layering.
struct NowPlayingView: View {
    @Environment(PlaybackController.self) private var player
    @State private var queueExpanded = false
    @State private var editMode: EditMode = .inactive
    @State private var scrubValue: Double = 0
    @State private var isScrubbing = false
    /// Measured height of the hugging collapsed stack — drives the collapsed detent. Seeded
    /// with a realistic value so the first frame doesn't flash a sliver-height sheet.
    @State private var collapsedHeight: CGFloat = 560
    @Namespace private var artNamespace

    private let inset: CGFloat = 24

    private var collapsedDetent: PresentationDetent { .height(collapsedHeight) }
    /// Derived, never stored: PresentationDetent identity is value-based, so the selection must
    /// always be recomputed from state or a re-measure would orphan it (runtime warning + snap).
    private var detentSelection: Binding<PresentationDetent> {
        Binding(
            get: { queueExpanded ? .large : collapsedDetent },
            set: { newValue in
                // Fires once when a user drag settles — animate our content morph in sync.
                withAnimation(.snappy(duration: 0.35)) {
                    queueExpanded = (newValue == .large)
                    if !queueExpanded { editMode = .inactive } // drag-collapse must exit edit like tap-collapse
                }
            }
        )
    }

    var body: some View {
        Group {
            if let tune = player.current {
                if queueExpanded { expandedLayout(tune) } else { collapsedLayout(tune) }
            } else {
                ContentUnavailableView("Nothing playing", systemImage: "music.note")
            }
        }
        .presentationDetents([collapsedDetent, .large], selection: detentSelection)
        .presentationDragIndicator(.visible)
    }

    // MARK: - Collapsed: content-hugging stack

    private func collapsedLayout(_ tune: Tune) -> some View {
        VStack(spacing: 0) {
            Artwork(tune: tune, size: 264)
                .matchedGeometryEffect(id: "art", in: artNamespace)
                .shadow(color: .black.opacity(0.22), radius: 20, y: 10)
                .padding(.top, 28) // clears the system drag indicator

            titleBlock(tune)
                .padding(.top, 20)

            scrubber
                .padding(.top, 20)

            transport
                .padding(.top, 12)

            queueHandle
                .padding(.top, 16)
                .padding(.bottom, 4)
        }
        .padding(.horizontal, inset)
        .frame(maxWidth: .infinity)
        .fixedSize(horizontal: false, vertical: true) // hug intrinsic height for measurement
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            let measured = height.rounded(.up)
            guard abs(measured - collapsedHeight) >= 1 else { return } // ignore float jitter
            // Animate so content growth (title wrap, error line) resizes the sheet smoothly
            // instead of snapping a frame later.
            withAnimation(.snappy(duration: 0.3)) { collapsedHeight = measured }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func titleBlock(_ tune: Tune) -> some View {
        VStack(spacing: 4) {
            Text(tune.displayTitle).font(.title2.bold()).multilineTextAlignment(.center).lineLimit(2)
            HStack(spacing: 6) {
                SourceBadge(source: tune.source)
                Text(tune.displayArtist).font(.title3).foregroundStyle(CratesColor.textSecondary)
            }
            metaLine(tune)
        }
    }

    /// Third line of the title block: the playback error takes the genre line's slot, so an
    /// error appearing never shifts the rest of the layout.
    @ViewBuilder private func metaLine(_ tune: Tune) -> some View {
        if let error = player.playbackError {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote).foregroundStyle(CratesColor.red)
                .lineLimit(2).multilineTextAlignment(.center)
        } else if !metaText(tune).isEmpty {
            Text(metaText(tune))
                .font(.footnote).foregroundStyle(CratesColor.textSecondary)
        }
    }

    /// "Techno · 132 BPM · A♭m" with missing parts dropped — never a dangling separator.
    private func metaText(_ tune: Tune) -> String {
        [tune.genre, tune.bpm.map { "\($0) BPM" }, tune.key]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    // MARK: - Expanded: compact header + queue

    private func expandedLayout(_ tune: Tune) -> some View {
        VStack(spacing: 0) {
            compactHeader(tune)
                .padding(.top, 24)
                .padding(.horizontal, inset)

            scrubber
                .padding(.top, 16)
                .padding(.horizontal, inset)

            transport
                .padding(.top, 8)
                .padding(.horizontal, inset)

            queueHandle
                .padding(.top, 12)
                .padding(.horizontal, inset)

            queueList
        }
    }

    private func compactHeader(_ tune: Tune) -> some View {
        HStack(spacing: 12) {
            Artwork(tune: tune, size: 64)
                .matchedGeometryEffect(id: "art", in: artNamespace)
            VStack(alignment: .leading, spacing: 2) {
                Text(tune.displayTitle).font(.headline).lineLimit(1)
                HStack(spacing: 6) {
                    SourceBadge(source: tune.source)
                    Text(tune.displayArtist).font(.subheadline)
                        .foregroundStyle(CratesColor.textSecondary).lineLimit(1)
                }
                if let error = player.playbackError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(CratesColor.red)
                        .lineLimit(2) // the error is the one line that must stay readable
                } else if !metaText(tune).isEmpty {
                    Text(metaText(tune))
                        .font(.caption).foregroundStyle(CratesColor.textSecondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Scrubber & transport (shared, never move during the morph)

    /// Thumbless Apple-Music-style progress bar: a capsule that thickens while dragging.
    /// The stock Slider's oversized thumb overhung the track start and read template-y.
    private var scrubber: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                let duration = max(player.duration, 1)
                let shown = isScrubbing ? scrubValue : player.currentTime
                let fraction = min(1, max(0, shown / duration))
                ZStack(alignment: .leading) {
                    Capsule().fill(CratesColor.textSecondary.opacity(0.22))
                    Capsule().fill(CratesColor.accent)
                        .frame(width: max(geo.size.width * fraction, fraction > 0 ? 6 : 0))
                }
                .frame(height: isScrubbing ? 12 : 6)
                .frame(maxHeight: .infinity, alignment: .center)
                .contentShape(.rect)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            isScrubbing = true
                            let fraction = min(1, max(0, value.location.x / max(geo.size.width, 1)))
                            scrubValue = fraction * duration
                        }
                        .onEnded { _ in
                            player.seek(to: scrubValue)
                            isScrubbing = false
                        }
                )
            }
            .frame(height: 24) // full-height hit area around the thin bar
            .animation(.snappy(duration: 0.2), value: isScrubbing)

            HStack {
                Text(timeLabel(isScrubbing ? scrubValue : player.currentTime))
                Spacer()
                Text("-" + timeLabel(max(0, player.duration - (isScrubbing ? scrubValue : player.currentTime))))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(CratesColor.textSecondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playback position")
        .accessibilityValue(timeLabel(player.currentTime))
        .accessibilityAdjustableAction { direction in
            let delta: Double = direction == .increment ? 15 : -15
            player.seek(to: min(max(0, player.currentTime + delta), player.duration))
        }
    }

    /// Five equal-width slots: the play button is structurally on the sheet's center axis
    /// (Spacer-based centering only holds when flank glyph widths happen to match). One icon
    /// treatment throughout — primary when off, accent when on — so shuffle/repeat don't read
    /// as disabled next to the filled prev/next glyphs. Sizes identical in both detents so the
    /// morph doesn't re-scale the controls.
    private var transport: some View {
        HStack(spacing: 0) {
            Button { player.toggleShuffle() } label: {
                Image(systemName: "shuffle").font(.title3.weight(.semibold))
                    .foregroundStyle(player.isShuffled ? CratesColor.accent : .primary)
            }
            .frame(maxWidth: .infinity)
            Button { player.previous() } label: { Image(systemName: "backward.fill").font(.title) }
                .frame(maxWidth: .infinity)
            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 62))
                    .foregroundStyle(CratesColor.accent)
                    .contentTransition(.symbolEffect(.replace))
            }
            .frame(maxWidth: .infinity)
            Button { player.next() } label: { Image(systemName: "forward.fill").font(.title) }
                .frame(maxWidth: .infinity)
            Button { cycleRepeat() } label: {
                Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat").font(.title3.weight(.semibold))
                    .foregroundStyle(player.repeatMode == .off ? .primary : CratesColor.accent)
            }
            .frame(maxWidth: .infinity)
        }
        .foregroundStyle(.primary)
        .tint(CratesColor.accent)
    }

    // MARK: - Up Next handle (the one glass element on this screen)

    /// A single centered pill on the transport's center axis — nothing else shares its row, so
    /// a near-miss can't hit a different control (Edit lives in the queue's section header).
    /// Tap toggles; the system sheet drag between detents is the swipe gesture (a custom
    /// DragGesture would fight it).
    private var queueHandle: some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.compact.up")
                .font(.body.weight(.semibold))
                .rotationEffect(.degrees(queueExpanded ? 180 : 0))
            // No count: "Queue · 2000" after playing a big crate is noise, not information.
            Text("Queue").font(.subheadline.weight(.semibold))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .glassEffect(.regular.interactive(), in: .capsule)
        .frame(maxWidth: .infinity, minHeight: 44)
        .contentShape(.rect)
        .onTapGesture { setQueue(expanded: !queueExpanded) }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(queueExpanded ? "Collapse queue" : "Expand queue")
        .accessibilityIdentifier("queueHandle")
        .accessibilityAdjustableAction { direction in
            setQueue(expanded: direction == .increment)
        }
    }

    private var queueList: some View {
        List {
            if !manualBlock.isEmpty {
                Section {
                    queueRows(manualBlock, baseIndex: upNextStart, isLastSection: contextBlock.isEmpty)
                } header: {
                    sectionHeader("Added to Queue", showsEdit: true)
                }
                .listSectionMargins(.top, 0)
            }
            if !contextBlock.isEmpty {
                Section {
                    queueRows(contextBlock, baseIndex: upNextStart + manualBlock.count, isLastSection: true)
                } header: {
                    sectionHeader(contextHeader, showsEdit: manualBlock.isEmpty)
                }
                .listSectionMargins(.top, manualBlock.isEmpty ? 0 : 8)
            }
            if upNextEntries.isEmpty {
                Text("Nothing up next — swipe right on any track to queue it.")
                    .font(.footnote).foregroundStyle(CratesColor.textSecondary)
                    .listRowBackground(Color.clear)
                    .listRowInsets(.init(top: 12, leading: inset, bottom: 12, trailing: inset))
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 0, for: .scrollContent)
        .listSectionSpacing(8)
        .environment(\.defaultMinListHeaderHeight, 1)
        .scrollEdgeEffectStyle(.soft, for: .bottom)
        .environment(\.editMode, $editMode)
    }

    /// Section header row: title leading, Edit/Done trailing (classic iOS grammar — the Edit
    /// control lives with the list it edits, not inside the drag pill's tap area).
    private func sectionHeader(_ title: String, showsEdit: Bool = false) -> some View {
        HStack {
            Text(title)
                .font(.footnote.smallCaps().weight(.semibold))
                .foregroundStyle(CratesColor.textSecondary)
            Spacer()
            if showsEdit {
                Button(editMode == .active ? "Done" : "Edit") {
                    withAnimation { editMode = editMode == .active ? .inactive : .active }
                }
                .font(.footnote.weight(.semibold))
                .tint(CratesColor.accent)
            }
        }
        .textCase(nil)
        .listRowInsets(.init(top: 0, leading: inset, bottom: 4, trailing: inset))
    }

    private func queueRows(_ block: [QueueEntry], baseIndex: Int, isLastSection: Bool) -> some View {
        ForEach(block) { entry in
            QueueRow(tune: entry.tune)
                .contentShape(.rect)
                .onTapGesture {
                    if let i = player.entries.firstIndex(where: { $0.id == entry.id }) {
                        player.jump(to: i)
                    }
                }
                .listRowInsets(.init(top: 8, leading: inset, bottom: 8, trailing: inset))
                .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
                .listRowSeparator(
                    isLastSection && entry.id == block.last?.id ? .hidden : .automatic,
                    edges: .bottom) // no dangling separator under the final row
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
